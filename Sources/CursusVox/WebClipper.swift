import AppKit
import WebKit

// Fn+W: the page in front becomes a Markdown note in the Clips vault. The page-to-
// Markdown work uses the Obsidian Web Clipper pipeline, bundled as cursus-clip.js.
// See THIRD-PARTY-NOTICES.md for upstream sources and dependency licences; it is
// run in a hidden web view with the browser engine's DOMParser. The page HTML comes
// from the browser itself, so pages you're logged into clip too; when a browser won't
// share its HTML, the URL is fetched instead.
@MainActor final class WebClipper: NSObject, WKNavigationDelegate {
    struct Note { let name: String; let markdown: String; let title: String }
    enum Failure: Error { case noBundle, noPage, script(String) }

    private var view: WKWebView?
    private var ready: CheckedContinuation<Bool, Never>?
    private weak var loading: WKWebView?   // the view `ready` is waiting on; callbacks from any other view are ignored
    private let script: URL?
    // `script` overrides the bundled cursus-clip.js (tests).
    init(script: URL? = nil) { self.script = script }

    // Loads the bundle once into a blank page with no network access of its own.
    private func webView(operation id: Int) async throws -> WKWebView {
        if let view { return view }
        guard let url = script ?? Bundle.main.url(forResource: "cursus-clip", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { throw Failure.noBundle }
        let rules = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "cursusvox-converter-offline-v1",
            encodedContentRuleList: #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#)
        try Task.checkCancellation()
        guard id == operation, pending != nil else { throw CancellationError() }
        guard let rules else { throw Failure.script("network isolation unavailable") }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(rules)
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd,
                                                                       forMainFrameOnly: true))
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        view.navigationDelegate = self
        let loaded = await withCheckedContinuation { continuation in
            ready = continuation; loading = view
            view.loadHTMLString("""
                <!doctype html><html><head><meta http-equiv="Content-Security-Policy"
                content="default-src 'none'; script-src 'none'; connect-src 'none'; img-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'"></head><body></body></html>
                """, baseURL: nil)
        }
        guard id == operation, pending != nil else { throw CancellationError() }
        guard loaded else { throw Failure.script("web view failed to load") }
        self.view = view
        return view
    }
    // This must stay main-actor isolated to match the SDK requirement: its decisionHandler is
    // declared WK_SWIFT_UI_ACTOR, so a `nonisolated` method is not a witness and WebKit would
    // never call it, leaving the guard below unenforced.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Conversion never navigates to the supplied source URL, files, frames or data pages.
        decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
    // The blank page loaded, failed, or its process died: the waiting clip always hears which.
    private func settle(_ ok: Bool, from webView: WKWebView? = nil) {
        if let webView, webView !== loading { return }
        ready?.resume(returning: ok); ready = nil; loading = nil
    }
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { settle(true, from: webView) }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { settle(false, from: webView) }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { settle(false, from: webView) }
    }
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            settle(false, from: webView)
            if webView === view {
                view = nil
                finish(operation, .failure(Failure.script("web view process terminated")))
            }   // a retired view dying changes nothing
        }
    }
    // Drops the web view (after a timeout) so the next clip starts from a fresh one; the old
    // view stops reporting to this clipper.
    func reset() { view?.navigationDelegate = nil; view = nil; settle(false) }

    private var pending: CheckedContinuation<Note, Error>?
    private var operation = 0
    // One clip at a time. The deadline resumes the caller itself, so a web view that never
    // answers (hung page script, dead process) can't leave Fn+W stuck; the view is then rebuilt.
    func clip(html: String, url: String, timeout: TimeInterval = 20) async throws -> Note {
        try Task.checkCancellation()
        guard pending == nil else { throw Failure.script("another conversion is in progress") }
        operation += 1
        let id = operation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                let deadline = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled, let self, id == operation, pending != nil else { return }
                    finish(id, .failure(Failure.script("timed out"))); reset()
                }
                Task { [weak self] in
                    guard let self else { return }
                    do { finish(id, .success(try await run(html: html, url: url, operation: id))) }
                    catch { finish(id, .failure(error)) }
                    deadline.cancel()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, id == operation, pending != nil else { return }
                finish(id, .failure(CancellationError())); reset()
            }
        }
    }
    // Only the clip that is still waiting gets an answer: a late result from a timed-out clip is dropped.
    private func finish(_ id: Int, _ result: Result<Note, Error>) {
        guard id == operation else { return }
        pending?.resume(with: result); pending = nil
    }

    private func run(html: String, url: String, operation id: Int) async throws -> Note {
        let view = try await webView(operation: id)
        let result = try await view.callAsyncJavaScript("return await CursusClip(html, url)",
                                                         arguments: ["html": html, "url": url], contentWorld: .page)
        guard let json = result as? String, let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let note = object["note"], let name = object["noteName"] else { throw Failure.script("no result") }
        return Note(name: name, markdown: note, title: object["title"] ?? name)
    }
}

// The page in the front browser: its URL, and its HTML when the browser allows it, read
// in one AppleScript call from the same tab so the two always match.
enum FrontPage {
    struct Page { let url: String; let html: String; let browser: String }
    enum Problem: Error { case automationDenied, notAWebPage, noWindow, timedOut, browserNotResponding, noPageAccess, tooLarge }
    // Chromium-family browsers share one AppleScript dictionary.
    static let chromium = ["ai.perplexity.comet", "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser",
                           "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
                           "com.operasoftware.Opera", "company.thebrowser.dia", "com.openai.atlas"]
    static let safari = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    static func isBrowser(_ bundle: String?) -> Bool {
        guard let bundle else { return false }
        return chromium.contains(bundle) || safari.contains(bundle) || bundle == "org.mozilla.firefox"
    }
    static let split = "\n<<CURSUSVOX-SPLIT>>\n"

    // The script for one browser. Bundle ids come only from the fixed lists above.
    static func script(for bundle: String) -> String? {
        let html = "document.documentElement.outerHTML"
        if chromium.contains(bundle) {
            return """
            tell application id "\(bundle)"
              if (count of windows) is 0 then error "no window" number 4001
              set t to active tab of front window
              set u to URL of t
              set h to ""
              try
                set h to execute t javascript "\(html)"
              end try
              return u & "\(split.replacingOccurrences(of: "\n", with: "\\n"))" & h
            end tell
            """
        }
        if safari.contains(bundle) {
            return """
            tell application id "\(bundle)"
              if (count of documents) is 0 then error "no window" number 4001
              set d to front document
              set u to URL of d
              set h to ""
              try
                set h to do JavaScript "\(html)" in d
              end try
              return u & "\(split.replacingOccurrences(of: "\n", with: "\\n"))" & h
            end tell
            """
        }
        return nil
    }

    // Runs osascript as a child process with a deadline, off the main thread, so a hung
    // browser or an unanswered permission prompt can't freeze CursusVox.
    static func read(bundle: String, timeout: TimeInterval = 8) async -> Result<Page, Problem> {
        guard let source = script(for: bundle) else { return .failure(.notAWebPage) }
        // Pipe reads and waitUntilExit block their thread. Running them inside a Task occupied a
        // cooperative-pool thread for up to the whole deadline, so the work runs on its own queue.
        return await withCheckedContinuation { continuation in
            DispatchQueue(label: "cursus.frontpage.read", qos: .userInitiated).async {
                continuation.resume(returning: run(source: source, bundle: bundle, timeout: timeout))
            }
        }
    }
    private final class StderrBox: @unchecked Sendable { var text = "" }
    private static func run(source: String, bundle: String, timeout: TimeInterval) -> Result<Page, Problem> {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out; process.standardError = err
            do { try process.run() } catch { return .failure(.timedOut) }
            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let errHandle = err.fileHandleForReading
            let stderr = StderrBox()
            let errDone = DispatchSemaphore(value: 0)
            // A browser that fills stderr while we read stdout would deadlock the child, so stderr is
            // drained on its own thread rather than after the stdout loop.
            DispatchQueue(label: "cursus.frontpage.stderr").async {
                var stderrData = Data()
                while case let chunk = errHandle.availableData, !chunk.isEmpty {
                    if stderrData.count < 64 * 1024 { stderrData.append(chunk) }
                }
                stderr.text = String(data: stderrData, encoding: .utf8) ?? ""
                errDone.signal()
            }
            // At most 16 MB of page: a bigger page is cut off and the browser call stopped.
            var data = Data()
            var tooLarge = false
            let reader = out.fileHandleForReading
            while case let chunk = reader.availableData, !chunk.isEmpty {
                data.append(chunk)
                if data.count > 16 * 1024 * 1024 { tooLarge = true; process.terminate(); break }
            }
            errDone.wait()
            let errors = stderr.text
            process.waitUntilExit(); killer.cancel()
            if tooLarge { return .failure(.tooLarge) }
            if process.terminationReason == .uncaughtSignal { return .failure(.timedOut) }
            guard process.terminationStatus == 0 else {
                if errors.contains("-1743") || errors.contains("Not authorized") { return .failure(.automationDenied) }
                if errors.contains("4001") { return .failure(.noWindow) }
                // Apple-event delivery failures: the browser is busy or not answering.
                if ["-600", "-609", "-1712", "-1708", "-10004"].contains(where: errors.contains) {
                    return .failure(.browserNotResponding)
                }
                return .failure(.notAWebPage)
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            // Split at the first marker only: a page may contain the marker text itself.
            let marker = text.range(of: "<<CURSUSVOX-SPLIT>>")
            let url = String(marker.map { text[..<$0.lowerBound] } ?? text[...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return .failure(.notAWebPage) }
            let html = marker.map { String(text[$0.upperBound...]) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Without the browser's own HTML there is nothing to clip: CursusVox never downloads the page itself
            // (no cookies, and no way to stop a name resolving to a private address between check and connect).
            guard !html.isEmpty else { return .failure(.noPageAccess) }
            return .success(Page(url: url, html: html, browser: bundle))
    }

}



// ~/Mercurius Clips: Markdown notes an Obsidian vault can open. The clip card saves a note
// into a folder inside it ("Clips" unless you pick another) and it is kept for good. Unsaved
// drafts live in the main clipboard (ClipboardStore), never here; the only loose notes at the
// top are from the old fn+W, which saved every clip at once: the recent ones are listed in the
// main clipboard (`looseNotes`, looked for at every launch), and the files still go after 48 hours.
// Every file operation goes through a folder held open by descriptor (SafeFolder), so a folder
// swapped for a link mid-way can't send a note, a read or a removal outside the vault.
enum ClipsVault {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Mercurius Clips", isDirectory: true)
    static let defaultFolder = "Clips"
    static let lifetime: TimeInterval = 48 * 3600

    // Why a save didn't happen, in words the card can show.
    enum SaveError: Error, Equatable {
        case outsideVault, notAFolder(String), noSpace, noPermission, readOnly, tooManyNames, notVerified, busy, failed(Int32)
        var reason: String {
            switch self {
            case .outsideVault: return "That folder leads outside Mercurius Clips"
            case let .notAFolder(name): return "\u{201C}\(name)\u{201D} is a file, not a folder"
            case .noSpace: return "The disk is full"
            case .noPermission: return "Mercurius isn't allowed to write in that folder"
            case .readOnly: return "That folder is read-only"
            case .tooManyNames: return "Too many notes with this name; rename it"
            case .notVerified: return "The note didn't read back the same; try again"
            case .busy: return "This clip is already being saved"
            case let .failed(code): return "Couldn't write the note (\(String(cString: strerror(code))))"
            }
        }
        init(errno code: Int32) {
            switch code {
            case ENOSPC, EDQUOT: self = .noSpace
            case EACCES, EPERM: self = .noPermission
            case EROFS: self = .readOnly
            case ELOOP: self = .outsideVault
            default: self = .failed(code)
            }
        }
        init(_ problem: SafeFolder.Problem) {
            switch problem {
            case .link, .rejected: self = .outsideVault
            case let .notAFolder(name): self = .notAFolder(name)
            case .notVerified: self = .notVerified
            case .exists: self = .failed(EEXIST)
            case let .system(code): self.init(errno: code)
            }
        }
    }

    // Clips can hold logged-in pages: the vault is private to this user (0700, notes 0600). The
    // vault folder itself may be where you chose to keep it (a link there is followed); nothing
    // inside it ever is.
    static func open(_ root: URL = folder, create: Bool) throws -> SafeFolder {
        try SafeFolder.open(root, followLink: true, create: create, mode: create ? 0o700 : nil, requireMode: false)
    }
    static func prepare(in root: URL = folder) throws { _ = try open(root, create: true) }

    // A file name from a page title: no path separators, colons, control characters or leading
    // dots, and short enough (in bytes) to leave room for a counter.
    static func safeName(_ title: String, limit: Int = 150) -> String {
        var name = String(title.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            return "/\\:".contains(c) || scalar.properties.generalCategory == .control ? " " : c
        })
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while name.utf8.count > limit { name.removeLast() }
        // No hidden or relative-looking names: drop leading dots and spaces together.
        while let first = name.first, first == "." || first == " " { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Clip" : name
    }
    // A folder path inside the vault: each part a safe name, ".." and empty parts dropped,
    // at most four deep. Never empty, so a saved note never lands loose at the top.
    static func safeFolder(_ path: String) -> String {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .map { safeName($0, limit: 80) }
        return parts.isEmpty ? defaultFolder : parts.prefix(4).joined(separator: "/")
    }
    static func folderParts(_ path: String) -> [String] { safeFolder(path).split(separator: "/").map(String.init) }
    static func names(for title: String) -> [String] {
        let base = safeName(title)
        return (1...999).map { $0 == 1 ? "\(base).md" : "\(base) \($0).md" }
    }

    // Where Save would put this note now, without touching the disk: for showing at once.
    static func guess(title: String, folder path: String, in root: URL = folder) -> URL {
        folderParts(path).reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }.appendingPathComponent("\(safeName(title)).md")
    }
    // Where Save will put this note: the first free name (" 2", " 3"…) in the folder. This looks
    // at the disk (up to 999 names), so the card calls it off the main actor.
    static func planned(title: String, folder path: String, in root: URL = folder) -> URL {
        let parts = folderParts(path)
        let directory = parts.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
        let names = names(for: title)
        guard let vault = try? open(root, create: false), let folder = try? vault.folder(parts, create: false) else {
            return directory.appendingPathComponent(names[0])
        }
        return directory.appendingPathComponent(names.first { folder.entry($0) == nil } ?? names[0])
    }
    // The note's path from the vault, for showing ("Clips/Ship it.md").
    static func relative(_ file: URL, in root: URL = folder) -> String {
        parts(of: file, in: root)?.joined(separator: "/") ?? file.lastPathComponent
    }
    // The folder a saved note is in, relative to the vault ("Clips", "Work/Reading").
    static func folder(of file: URL, in root: URL = folder) -> String {
        let parts = relative(file, in: root).split(separator: "/").dropLast()
        return parts.isEmpty ? defaultFolder : parts.joined(separator: "/")
    }

    // Writes a note as a new file and reads it back. Never overwrites: a taken name gets " 2",
    // " 3"… and the file is created exclusively, so a note made meanwhile is never replaced. The
    // folder is held open from the checks to the write, so swapping a folder for a link in
    // between can't send the note elsewhere. Returns the path the written file really has (if
    // its folder was moved meanwhile, where it is now); a note that ended up outside the vault
    // is removed and refused. `beforeCreate` lets a test swap folders at the worst moment.
    @discardableResult
    static func save(_ markdown: String, title: String, folder path: String, in root: URL = folder,
                     beforeCreate: (() -> Void)? = nil) throws -> URL {
        do {
            let vault: SafeFolder
            do { vault = try open(root, create: true) } catch { throw SaveError.noPermission }
            let directory = try vault.folder(folderParts(path), create: true)
            beforeCreate?()
            let data = Data(markdown.utf8)
            for name in names(for: title) {
                do {
                    return try directory.create(name, data: data) { file in
                        // Inside the vault as it is now, by the system's own paths for both.
                        guard let base = vault.path?.path else { return false }
                        return file.path.hasPrefix(base + "/")
                    }
                } catch SafeFolder.Problem.exists { continue }
            }
            throw SaveError.tooManyNames
        } catch let problem as SafeFolder.Problem { throw SaveError(problem) }
    }

    // A saved note's text, read as carefully as it was written: the file must be inside the
    // vault, reached without following a link at any level, and a plain file (never a FIFO or a
    // device) no bigger than `limit`. nil when it isn't, or is gone.
    static let noteLimit = 8 * 1024 * 1024
    static func readNote(_ file: URL, in root: URL = folder, limit: Int = noteLimit) -> String? {
        guard let (folder, name) = noteFolder(file, in: root) else { return nil }
        return folder.read(name, limit: limit).flatMap { String(data: $0, encoding: .utf8) }
    }
    // Whether a saved note passes the same checks right now: inside the vault, reached without
    // following a link at any level, and a plain file. Open note asks this just before opening.
    static func isNote(_ file: URL, in root: URL = folder) -> Bool {
        guard let (folder, name) = noteFolder(file, in: root) else { return false }
        return folder.entry(name)?.kind == .file
    }
    // The draft a saved note holds: its frontmatter title, or `title` when it has none.
    static func draft(fromNote text: String, title: String) -> ClipDraft {
        let title = Frontmatter.parse(text).fields.first { $0.key == "title" }?.values.first ?? title
        return ClipDraft(note: WebClipper.Note(name: title, markdown: text, title: title))
    }
    // Whether the note is still a plain file inside the vault (read as readNote reads one) holding
    // this draft, as written or as it reads back. The card asks before reusing a note it saved.
    static func holds(_ file: URL, _ draft: ClipDraft, in root: URL = folder) -> Bool {
        guard let text = readNote(file, in: root) else { return false }
        return text == draft.markdown || self.draft(fromNote: text, title: draft.title) == draft
    }
    // The folder holding a note inside the vault, opened by descriptor part by part, and its name.
    private static func noteFolder(_ file: URL, in root: URL) -> (SafeFolder, String)? {
        guard let parts = parts(of: file, in: root), let name = parts.last,
              let folder = try? open(root, create: false).folder(Array(parts.dropLast()), create: false) else { return nil }
        return (folder, name)
    }
    // Whether a saved note is still there. `unknown` when the vault can't be looked at (a volume
    // not mounted) or something odd is in the way, so an entry is never dropped on a guess.
    enum Presence { case present, missing, unknown }
    static func presence(of file: URL, in root: URL = folder) -> Presence {
        guard let vault = try? open(root, create: false) else { return .unknown }
        guard let parts = parts(of: file, in: root), let name = parts.last else { return .missing }
        let folder: SafeFolder
        do { folder = try vault.folder(Array(parts.dropLast()), create: false) }
        catch SafeFolder.Problem.system(ENOENT) { return .missing }
        catch { return .unknown }
        if let entry = folder.entry(name) { return entry.kind == .file ? .present : .unknown }
        return folder.missing(name) ? .missing : .unknown
    }
    // The file's path below the vault, part by part; nil when it isn't inside it. The vault is
    // matched as written, with its links resolved, and by its real path (a save reports that).
    static func parts(of file: URL, in root: URL = folder) -> [String]? {
        let path = file.standardizedFileURL.path
        var bases = [root.standardizedFileURL.path, root.resolvingSymlinksInPath().standardizedFileURL.path]
        if let real = SafeFolder.realPath(root) { bases.append(real) }
        for base in bases where path.hasPrefix(base + "/") {
            let parts = path.dropFirst(base.count + 1).split(separator: "/").map(String.init)
            return parts.isEmpty || parts.contains(where: { $0 == "." || $0 == ".." }) ? nil : parts
        }
        return nil
    }

    // The vault's folders, for the card's Folder suggestions: the default first, then the rest.
    // Looks at the disk, so the card calls it off the main actor.
    static func folders(in root: URL = folder) -> [String] {
        let found = ((try? open(root, create: false).entries()) ?? [])
            .filter { $0.kind == .folder && !$0.name.hasPrefix(".") && $0.name != defaultFolder }
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return [defaultFolder] + found
    }

    // The notes kept in the vault's folders (never the loose ones at the top), newest first, for
    // listing in the main clipboard. Looked for at every launch: a folder that can't be opened now
    // (or a vault not mounted) is just skipped, and its notes are found on a later launch. Folders
    // are walked by descriptor, at most four deep, never through a link; hidden ones (.obsidian)
    // are skipped. Nothing is read, and at most 20,000 entries are looked at.
    struct SavedNote: Equatable, Sendable { let url: URL; let title: String; let date: Date; let bytes: Int }
    static func savedNotes(in root: URL = folder, limit: Int = 500) -> [SavedNote] {
        guard let vault = try? open(root, create: false) else { return [] }
        var notes: [SavedNote] = []
        var budget = 20_000
        func walk(_ folder: SafeFolder, at url: URL, depth: Int) {
            for entry in folder.entries() where !entry.name.hasPrefix(".") {
                budget -= 1
                guard budget > 0 else { return }
                if entry.kind == .folder, depth < 4, let inner = try? folder.folder(entry.name, create: false) {
                    walk(inner, at: url.appendingPathComponent(entry.name, isDirectory: true), depth: depth + 1)
                } else if entry.kind == .file, depth > 0, entry.name.hasSuffix(".md") {
                    notes.append(SavedNote(url: url.appendingPathComponent(entry.name), title: String(entry.name.dropLast(3)),
                                           date: entry.modified, bytes: entry.size))
                }
            }
        }
        walk(vault, at: root, depth: 0)
        return Array(notes.sorted { $0.date > $1.date }.prefix(limit))
    }

    // The loose notes the old fn+W left at the top of the vault that are still within their 48
    // hours, with their text, newest first, so the main clipboard lists them as unsaved clips (they
    // keep Review, Save to Clips and Pin now the old Clips page is gone). Looked for at every
    // launch; `skip` names the files the clipboard already holds well, so they aren't read again.
    // A file that can't be read now is left out and found on a later launch. At most `limit`
    // files and `budget` bytes are read in one go.
    struct LooseNote: Equatable, Sendable { let name: String; let title: String; let markdown: String; let date: Date }
    static func looseNotes(now: Date = Date(), in root: URL = folder, limit: Int = 200, budget: Int = 32 * 1024 * 1024,
                           skip: Set<String> = []) -> [LooseNote] {
        guard let vault = try? open(root, create: false) else { return [] }
        let recent = vault.entries()
            .filter { $0.kind == .file && $0.name.hasSuffix(".md") && !$0.name.hasPrefix(".") && !skip.contains($0.name)
                      && now.timeIntervalSince($0.modified) < lifetime && $0.size <= noteLimit }
            .sorted { $0.modified > $1.modified }.prefix(limit)
        var left = budget
        var notes: [LooseNote] = []
        for entry in recent where entry.size <= left {
            guard let data = vault.read(entry.name, limit: min(noteLimit, left)) else { continue }
            left -= data.count   // charged as read, so undecodable files still count against the budget
            guard let text = String(data: data, encoding: .utf8) else { continue }
            notes.append(LooseNote(name: entry.name, title: String(entry.name.dropLast(3)), markdown: text, date: entry.modified))
        }
        return notes
    }
    // The key a note is known by in the main clipboard: its path from the vault ("Clips/Ship it.md",
    // or just the name for a loose one), or its full path when it isn't inside the vault.
    static func key(_ file: URL, in root: URL = folder) -> String {
        parts(of: file, in: root)?.joined(separator: "/") ?? file.standardizedFileURL.path
    }

    // Deletes loose notes at the top of the vault older than the lifetime (drafts from before the
    // card). Never touches a folder or anything in one, so saved notes are never purged.
    static func purge(now: Date = Date(), in root: URL = folder) {
        guard let vault = try? open(root, create: false) else { return }
        for entry in vault.entries() where entry.kind == .file && entry.name.hasSuffix(".md")
            && now.timeIntervalSince(entry.modified) >= lifetime {
            vault.remove(entry.name)
        }
    }
}
