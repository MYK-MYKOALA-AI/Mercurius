import AppKit
import CryptoKit
import os
import AVFoundation
import ApplicationServices
import CursusPlatform
import CursusCore
import Carbon
import Speech
import ServiceManagement

@MainActor final class Application: NSObject, NSApplicationDelegate {
    private let policy = Policy(clock: MonotonicClock())
    private let destination = NativeContext()
    private let speech = LocalSpeech()
    private let aiCleanup = AICleanup()
    private let prices = ModelPriceFeed()
    private let correctionWatch = CorrectionWatch()
    private let usageStore = UsageStore()
    private var credentialWindow: CredentialSetupWindow?
    private var healthWindow: FeatureWindow?
    private var healthChecks = HealthChecks()
    private var healthCredentialFingerprint: String?
    private var latestHealthFailure: HealthFailure?
    private var healthMicTask: Task<Void,Never>?
    private var healthMicID = UUID()
    private var healthMicCheck: UInt64?
    private var healthAudio: NativeAudio?

    private let vocabularyInbox = LocalSettings(key: "vocabularyInboxV1", initial: VocabularyInbox()) // gitleaks:allow -- UserDefaults storage name, not a credential.
    private let languageWindow = LanguageWindow()
    private let appPresets = LocalSettings(key: "appPresetsV1", initial: [AppPreset]())
    // Shared with WritingToolsWindow: dictation reads the same book that window edits.
    private let snippets = LocalSettings(key: "writingSnippetsV1", initial: SnippetBook())
    private var presetWindow: FeatureWindow?
    private var inboxWindow: FeatureWindow?
    private var usageWindow: FeatureWindow?
    private var recoveryWindow: FeatureWindow?
    private var recoveryWindowToken = UUID()
    private var writingTools: WritingToolsWindow?
    private var writingToolsOpening = false
    private var transcriptDetailWindow: FeatureWindow?
    private var transcriptDetailToken = UUID()
    private var transcriptDetailID: UUID?
    private var transcriptDetailStatus: NSTextField?

    private var retryTask: Task<Void, Never>?
    private var outboxPurgedAt: TimeInterval = 0
    private let keys = GlobalKeys()
    private let permissionPrompts = PermissionPrompts()
    private var clipTask: Task<Void, Never>?
    private var clipPermit: EffectPermit?
    // A clip that hangs must not swallow every later shortcut: after `clipDeadline` the next
    // press abandons the stalled run and starts a fresh one (2026-11-01).
    private static let clipDeadline: TimeInterval = 20
    private var clipStartedAt = Date.distantPast
    private var clipRun: UUID?
    // Retry on the clip card re-runs whichever shortcut made the draft (Fn+W or Fn+T).
    private var lastClipAction: (() -> Void)?
    // The main clipboard (clips, fn+T window clips, dictations) and the clip review card, made on first use.
    private let clipboard = ClipboardStore(defaults: .standard)
    private var cardStorage: ClipCard?
    private let defaults = UserDefaults.standard
    private var item: NSStatusItem!
    private var timer: Timer?
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var pill: RecordingPill!
    private var home: HomePanel!
    private var onboarding: Onboarding!
    private var pillActive = false
    private var history: [HistoryEntry] = []
    private var historyOutcomes: [UInt64: [Outcome]] = [:]
    private var reCleanTokens: [UUID: UUID] = [:]
    // Name-like words from each dictation, kept a day after its text is erased.
    private var retryID = 0

    // True when a clip may start now. A run still working blocks a second one; a run older than
    // the deadline is cancelled first, so a stalled capture never leaves the shortcuts silent.
    private func prepareClipRun() -> Bool {
        if let task = clipTask {
            guard Date().timeIntervalSince(clipStartedAt) > Self.clipDeadline else {
                Self.clipLog.info("clip press ignored: a clip is still running")
                return false
            }
            Self.clipLog.info("clip restart: abandoned a stalled run")
            task.cancel()
            // The abandoned run must not clear the state its replacement is about to set.
            clipRun = nil
            clipTask = nil
            clipPermit?.revoke(); clipPermit = nil
        }
        clipStartedAt = Date()
        return true
    }
    private func captureStillCurrent(_ origin: ScreenText.Origin, token: Int? = nil) async -> Bool {
        guard await CaptureExecution.allows(origin.observation.permit, current: { await ScreenText.isCurrent(origin) }) else {
            let message = "Capture cancelled because the originating window changed or became protected. Return to it and try again."
            if let token { clipCard.fail(message, token: token) } else { clipStatus(.failed(message)) }
            return false
        }
        return true
    }
    private func finishCapture(_ note: WebClipper.Note, origin: ScreenText.Origin, token: Int,
                               source: String, notice: String?, autoCopy: Bool = false) async {
        guard await captureStillCurrent(origin, token: token) else { return }
        let draft = await clipDraft(note)
        guard await captureStillCurrent(origin, token: token) else { return }
        finishClip(draft, failure: nil, token: token, source: source, notice: notice, autoCopy: autoCopy)
    }
    // The Docs export for the front window's address, when it shows a Docs, Sheets or Slides file.
    private func docsExport(address: String, bundle: String) async -> (file: DocsExport.File, export: GoogleDocs.Export, address: String)? {
        guard let export = GoogleDocs.export(for: address), let file = await DocsExport.fetch(export, browser: bundle) else { return nil }
        return (file, export, address)
    }
    // Where both extraction paths turn into the card's draft. The YouTube transcript hook is
    // ClipDraft.appendTranscript (see its comment).
    private func clipDraft(_ note: WebClipper.Note) async -> ClipDraft {
        var draft = ClipDraft(note: note)
        // YouTube clips carry the video's transcript (or a line saying why it isn't there).
        if let source = draft.value("source"), let id = YouTubeTranscript.videoID(source) {
            let lines = await YouTubeTranscript.fetch(id: id) ?? []
            draft.appendTranscript(lines.isEmpty ? "Transcript unavailable (no captions, or YouTube refused the request)."
                                                 : YouTubeTranscript.render(lines))
        }
        return draft
    }
    // A finished extraction: the draft joins the clipboard as unsaved (even if the card was closed
    // meanwhile) and is offered to the card if it still shows this clip. Fn+T may also put the
    // Markdown on the pasteboard when "Also copy captured text" is on.
    private func finishClip(_ draft: ClipDraft?, failure: String?, token: Int, source: String? = nil,
                            notice: String? = nil, autoCopy: Bool = false) {
        guard let draft else {
            Self.clipLog.info("clip failed: \(failure ?? "", privacy: .public)")
            clipCard.fail(failure ?? "Clipping failed", token: token)
            return
        }
        Self.clipLog.info("clip ready, \(draft.words) words")
        let id = clipboard.add(clip: draft, source: source)
        var cardNotice = notice
        if autoCopy, defaults.bool(forKey: "copyAfterCapture") {
            if let problem = verifiedCopy(draft.markdown) {
                let copyNote = "Not copied: \(problem)"
                cardNotice = cardNotice.map { "\($0) \(copyNote)" } ?? copyNote
            }
        }
        clipCard.offer(draft, token: token, storeID: id, notice: cardNotice)
    }
    // The one capture: whatever is in the front window becomes a Markdown note in the review card.
    // A Google Doc uses its own export, other windows their accessible text, and a window with no
    // readable text (an image, a scanned page) is read as an image on this Mac.
    private func captureScreen() {
        guard prepareClipRun() else { return }
        writingTools?.stopRecording()
        if policy.isActive { policy.cancel(reason: "Clip window started"); pump() }
        guard let front = FrontApp.current() else {
            Self.clipLog.info("window clip refused: no front app could be read")
            return
        }
        lastClipAction = { [weak self] in self?.captureScreen() }
        let name = front.localizedName ?? "this app"
        let bundleID = front.bundleIdentifier
        Self.clipLog.info("window clip start, front app \(bundleID ?? "none", privacy: .public)")
        clipOwnsPill = true
        pill.hide()
        let card = clipCard
        let token = card.begin("Reading \(name)…", site: name)
        presentCard()
        let run = UUID(); clipRun = run
        clipTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if clipRun == run { clipPermit?.revoke(); clipPermit = nil; clipTask = nil; clipRun = nil; clipOwnsPill = false }
            }
            let origin: ScreenText.Origin
            switch await ScreenText.start(pid: front.processIdentifier) {
            case let .success(value): origin = value
            case let .failure(problem):
                Self.clipLog.info("clip refused: \(String(describing: problem), privacy: .public)")
                finishClip(nil, failure: problem.message, token: token); return
            }
            clipPermit = origin.observation.permit
            guard await captureStillCurrent(origin, token: token) else { return }
            let browser = bundleID.flatMap { FrontPage.isBrowser($0) ? $0 : nil }
            // Docs, Sheets and Slides: the file itself, through Docs' export in this browser.
            let address = browser == nil ? nil : origin.address
            if let browser, let address, GoogleDocs.export(for: address) != nil,
               let docs = await docsExport(address: address, bundle: browser) {
                Self.clipLog.info("window clip via docs export, \(docs.file.text.utf8.count) bytes")
                let note = ScreenText.note(title: GoogleDocs.title(fromFile: docs.file.name), url: docs.address,
                                           body: GoogleDocs.body(docs.file.text, isTable: docs.export.isTable), site: name)
                await finishCapture(note, origin: origin, token: token, source: name,
                                    notice: docs.file.left.map(GoogleDocs.leftBehind), autoCopy: true)
                return
            }
            let capture = await ScreenText.result(origin: origin)
            guard await captureStillCurrent(origin, token: token) else { return }
            let seen: ScreenText.Capture?
            if case let .success(value) = capture { seen = value } else { seen = nil }
            if let browser, GoogleDocs.export(for: address) == nil, let url = seen?.url,
               GoogleDocs.export(for: url) != nil, let docs = await docsExport(address: url, bundle: browser) {
                Self.clipLog.info("window clip via docs export, \(docs.file.text.utf8.count) bytes")
                let note = ScreenText.note(title: GoogleDocs.title(fromFile: docs.file.name), url: docs.address,
                                           body: GoogleDocs.body(docs.file.text, isTable: docs.export.isTable), site: name)
                await finishCapture(note, origin: origin, token: token, source: name,
                                    notice: docs.file.left.map(GoogleDocs.leftBehind), autoCopy: true)
                return
            }
            guard let seen, seen.textProblem == nil else {
                // Keep YouTube transcript parity with Fn+W even when accessible page text is empty.
                if let address, YouTubeTranscript.videoID(address) != nil {
                    let note = ScreenText.note(title: ScreenText.pageTitle(origin.title, app: name, url: address), url: address, body: "", site: name)
                    await finishCapture(note, origin: origin, token: token, source: name,
                                        notice: "Accessible page text was unavailable; the note contains the video's transcript only.", autoCopy: true)
                    return
                }
                let problem: ScreenText.Problem
                if case let .failure(value) = capture { problem = value } else { problem = seen?.textProblem ?? .empty }
                if problem == .empty || problem == .readFailed,
                   await readAsImage(origin, token: token, name: name, bundleID: bundleID, accessibleWords: nil) { return }
                finishClip(nil, failure: problem.message, token: token); return
            }
            // A window with only a few accessible words (an image viewer's toolbar) may hold far more as pixels.
            if browser == nil, seen.words < 20, CGPreflightScreenCaptureAccess(),
               await readAsImage(origin, token: token, name: name, bundleID: bundleID, accessibleWords: seen.words) { return }
            Self.clipLog.info("window clip from \(bundleID ?? "-", privacy: .public): \(seen.words) words")
            let note = seen.note(url: seen.url, site: name, bundleID: bundleID)
            let notice = GoogleDocs.notice(url: seen.url, words: seen.words)
            await finishCapture(note, origin: origin, token: token, source: name, notice: notice, autoCopy: true)
        }
    }
    // True when it finished the clip (with a note or a failure); false leaves the caller's own result.
    // accessibleWords nil: there was no text at all, so a missing permission is worth explaining.
    private func readAsImage(_ origin: ScreenText.Origin, token: Int, name: String, bundleID: String?, accessibleWords: Int?) async -> Bool {
        guard await captureStillCurrent(origin, token: token) else { return true }
        switch await ScreenOCR.text(window: origin.window, pid: origin.pid, title: origin.title) {
        case let .failure(problem):
            Self.clipLog.info("image read failed: \(String(describing: problem), privacy: .public)")
            guard accessibleWords == nil, problem == .permission else { return false }
            finishClip(nil, failure: problem.message, token: token); return true
        case let .success(text):
            let words = text.split(whereSeparator: \.isWhitespace).count
            if let accessibleWords, !ScreenOCR.prefers(ocrWords: words, over: accessibleWords) { return false }
            Self.clipLog.info("window clip from its image: \(words) words")
            let note = ScreenText.note(title: ScreenText.pageTitle(origin.title, app: name, url: origin.address), url: ScreenText.clipSource(url: origin.address, bundleID: bundleID), body: text, site: name)
            await finishCapture(note, origin: origin, token: token, source: name,
                                notice: "Read from the window as an image: only the visible part is included.", autoCopy: true)
            return true
        }
    }
    // What the pill said after a legacy plain-text capture (tests still cover the wording).
    static func captureStatus(words: Int, from name: String, copied: Bool, copyProblem: String?, kept: String, whole: String,
                              thin: Bool, leftBehind: String?, partial: Bool = false) -> PillContent {
        let truncated = !copied && kept.utf8.count < whole.utf8.count
        // Warnings lead, most pressing first, so the pill's three lines always show them.
        var warnings: [String] = []
        if let leftBehind { warnings.append(leftBehind) }
        if let copyProblem { warnings.append("Not copied: \(copyProblem)") }
        if truncated { warnings.append("Clipboard kept only the first 2 MB") }
        if partial { warnings.append("Partial capture: some content could not be read; check the source window") }
        if thin { warnings.append(GoogleDocs.hint) }
        let headline = copied ? "Copied \(words.formatted()) words from \(name)"
            : "Kept \((truncated ? kept.split(whereSeparator: \.isWhitespace).count : words).formatted()) words from \(name) in Clipboard"
        guard !warnings.isEmpty else { return .done(headline) }
        let message = (warnings + [headline]).map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }.joined(separator: ". ")
        return .failed(message)
    }
    private var clipCard: ClipCard {
        if let cardStorage { return cardStorage }
        let card = ClipCard()
        card.effects = ClipCardModel.Effects(
            // The card and the Clipboard row share one save gate per entry: no duplicate notes.
            save: { [clipboard] draft, folder, id in
                await clipboard.savingNote(id) { await Self.saveNote(draft, folder: folder) }
            },
            // verifiedCopy's nil means copied; only a gone app is a failure.
            copy: ClipCardModel.Effects.copying(self) { app, text in app.verifiedCopy(text) },
            open: { file in await Self.openNote(file) { await Self.openInObsidian($0) } },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) })
        card.model.onSaved = { [weak self] file, draft, id in self?.noteSaved(file, draft: draft, id: id) }
        card.changed = { [weak self] draft, id in self?.clipEdited(draft, id: id) }
        card.retry = { [weak self] in self?.lastClipAction?() ?? self?.captureScreen() }
        card.closed = { [weak self] in self?.windowClosed() }
        cardStorage = card
        return card
    }
    static let obsidianBundle = "md.obsidian"
    // Writes the note off the main thread; the vault checks the folder and never overwrites.
    nonisolated static func saveNote(_ draft: ClipDraft, folder: String) async -> Result<URL, ClipsVault.SaveError> {
        let markdown = draft.markdown, title = draft.title
        return await Task.detached(priority: .userInitiated) { () -> Result<URL, ClipsVault.SaveError> in
            do { return .success(try ClipsVault.save(markdown, title: title, folder: folder)) }
            catch let error as ClipsVault.SaveError { return .failure(error) }
            catch { return .failure(.failed(EIO)) }
        }.value
    }
    // Open note (a Clipboard row) and Open in Obsidian (the card) open a saved note only after
    // checking it again just before, as readNote reads one: inside the vault, a plain file,
    // reached through no link. nil once `open` opened it; otherwise why not.
    static func openNote(_ file: URL, in vault: URL = ClipsVault.folder, with open: (URL) async -> String?) async -> String? {
        guard await Task.detached(priority: .userInitiated, operation: { ClipsVault.isNote(file, in: vault) }).value else {
            return "That note was moved, replaced or isn't in Mercurius Clips, so it wasn't opened"
        }
        return await open(file)
    }
    // Opens the saved note with the Obsidian app itself (no obsidian:// hand-off); nil once it opened.
    static func openInObsidian(_ file: URL) async -> String? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: obsidianBundle) else {
            return "Obsidian isn't installed"
        }
        do { _ = try await NSWorkspace.shared.open([file], withApplicationAt: app, configuration: .init()); return nil }
        catch { return "Obsidian couldn't open the note" }
    }
    // nil once the system clipboard reads back exactly this text; otherwise why it doesn't.
    private func verifiedCopy(_ text: String) -> String? {
        guard !IsSecureEventInputEnabled() else { return "a password field is active" }
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setString(text, forType: .string), board.string(forType: .string) == text else {
            return "the clipboard didn't keep it"
        }
        return nil
    }
    private func noteSaved(_ file: URL, draft: ClipDraft, id: UUID?) {
        Self.clipLog.info("clip saved")
        let entry: UUID
        if let id, clipboard.item(id) != nil { entry = id } else { entry = clipboard.add(clip: draft, source: nil) }
        clipboard.markSaved(entry, file: file, draft: draft)
        if cardStorage?.model.storeID == nil { cardStorage?.model.storeID = entry }
    }
    // An edit on the card reaches the clipboard (a clip whose entry was deleted meanwhile comes back).
    private func clipEdited(_ draft: ClipDraft, id: UUID?) {
        if let id, clipboard.item(id) != nil { clipboard.update(id, draft: draft) }
        else {
            let entry = clipboard.add(clip: draft, source: nil)
            if cardStorage?.model.draft == draft { cardStorage?.model.storeID = entry }
        }
    }
    // Opens the card on screen, with the Obsidian action only when Obsidian is installed.
    private func presentCard() {
        clipCard.model.obsidianInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.obsidianBundle) != nil
        clipCard.present()
    }
    private func clipboardChanged() { home.loadClipboard() }
    // What a Clipboard row's buttons do. The message says what happened (only once it did), or
    // nil. Reading an item's file happens off the main actor, so Open, Copy and Save report when
    // they finish; one action runs at a time per item, so a double press can't save twice.
    private func clipboardAction(_ action: HomePanel.ClipboardAction, _ item: ClipboardStore.Item) -> (ok: Bool, message: String)? {
        guard !clipboard.busy.contains(item.id) else { return (false, "Still working on that one") }
        switch action {
        case .open:
            guard item.kind == .clip else { return nil }
            Task { [weak self] in
                guard let self, let found = await clipboard.exclusive(item.id, { [clipboard] in
                    (draft: await clipboard.draft(item.id), edited: await clipboard.editedSinceSave(item.id))
                }) else { return }
                guard let draft = found.draft else {
                    home.clipboardMessage("That note was moved, deleted or can't be read, so it can't be opened", ok: false); return
                }
                home.hide()
                clipCard.load(draft, savedAt: found.edited ? nil : item.saved,
                              folder: item.saved.map { ClipsVault.folder(of: $0) } ?? ClipsVault.defaultFolder, storeID: item.id)
                presentCard()
            }
            return nil
        case .copy:
            Task { [weak self] in
                guard let self, let text = await clipboard.exclusive(item.id, { [clipboard] in await clipboard.text(item.id) }) else { return }
                guard let text else {
                    home.clipboardMessage(item.kind == .dictation ? "Its text is gone (dictations are erased after 10 minutes)"
                                                                  : "Its text couldn't be read (the note may have been moved)", ok: false)
                    return
                }
                let problem = verifiedCopy(text)
                home.clipboardMessage(problem.map { "Not copied: " + $0 } ?? "Copied", ok: problem == nil)
            }
            return nil
        case .pin:
            clipboard.setPinned(item.id, !item.pinned)
            return (true, item.pinned ? "Unpinned" : "Pinned: kept until you unpin it")
        case .save:
            Task { [weak self] in
                guard let self else { return }
                switch await clipboard.saveToClips(item.id, write: { draft, folder in await Self.saveNote(draft, folder: folder) }) {
                case .busy: home.clipboardMessage("Still working on that one", ok: false)
                case .nothing: home.clipboardMessage("Nothing left to save", ok: false)
                case let .saved(file): home.clipboardMessage("Saved to " + ClipsVault.relative(file), ok: true)
                case let .failed(error): home.clipboardMessage("Not saved: " + error.reason, ok: false)
                }
            }
            return (true, "Saving…")
        case .openFile:
            guard let file = item.saved else { return (false, "The note couldn't be opened") }
            Task { [weak self, vault = clipboard.vault] in
                let problem = await Self.openNote(file, in: vault) { NSWorkspace.shared.open($0) ? nil : "The note couldn't be opened" }
                if let problem { self?.home.clipboardMessage(problem, ok: false) }
            }
            return nil
        case .reveal:
            guard let file = item.saved else { return nil }
            NSWorkspace.shared.activateFileViewerSelecting([file])
            return nil
        case .delete:
            clipboard.delete(item.id)
            return (true, item.saved == nil ? "Deleted" : "Removed from Clipboard; the note stays in Clips")
        }
    }
    static func clipProblem(_ problem: FrontPage.Problem, browser: String) -> String {
        switch problem {
        case .noWindow: return "Open a web page in \(browser) first"
        case .timedOut, .browserNotResponding: return "\(browser) didn't answer; try again"
        case .notAWebPage: return "This tab isn't a web page Mercurius can clip"
        case .tooLarge: return "This page is too large to clip (over 16 MB)"
        case .automationDenied, .noPageAccess:
            return "Couldn't read this \(browser) page. Check Mercurius is on in System Settings › Privacy & Security › Accessibility."
        }
    }
    // Clip progress and results own the pill: posted after the cancelled dictation (fn+W cancels the
    // one fn started) has cleared it, so they aren't hidden by that dictation's own clean-up.
    private func clipStatus(_ content: PillContent) {
        switch content {
        // The reason can name a document ("Resume.md" is still in Downloads): kept out of the public log.
        case let .failed(reason): Self.clipLog.info("clip failed: \(reason, privacy: .private)")
        case .done: Self.clipLog.info("capture done")
        default: break
        }
        guard !policy.isActive else { return }
        pill.show(content, now: ProcessInfo.processInfo.systemUptime)
    }
    // While a clip runs it owns the pill: the dictation it cancelled doesn't hide its progress.
    private var clipOwnsPill = false
    // Text-free trace of each clip (front app id and outcome), for `log show --predicate 'category == "clip"'`.
    static let clipLog = Logger(subsystem: "au.com.mykoala.mercurius", category: "clip")
    private var namesSeen: [(at: Date, words: [String])] = []
    private var logTracker = RecordingLogTracker()
    private var ledger = RecordingLedger()
    private var wordCounter = RecordingWordCounter()
    private var deliveringGeneration: UInt64?
    private var lastFocusTookNoText = false
    private var historyGeneration: UInt64?
    private var pasteAfterCopy = false
    private var requestedPasteDestination: Destination?
    private let menuRequest = MenuRequestSlot()
    private var previousApp: NSRunningApplication?
    private var checkedAt: TimeInterval = 0
    private var pumping = false
    private var quitting = false
    private var discoveryAt: TimeInterval = 0
    private let focusCache = FocusCache()
    private var focusObservedAt: TimeInterval = 0
    private var pumpScheduled = false
    private var observationTask: Task<Void, Never>?
    private var observationRevision: UInt64 = 0
    private var lastDestination: Destination?
    private var deliveryTask: Task<Void, Never>?
    private var deliveryPermit: EffectPermit?
    private var deliveryAuthority: DeliveryAuthority?
    // The seed list plus the user's own words, kept in defaults (never transcripts).
    var savedDictionary: (terms: [String], replacements: [String: String]) {
        (defaults.stringArray(forKey: "dictionaryTerms") ?? [],
         defaults.dictionary(forKey: "dictionaryReplacements") as? [String: String] ?? [:])
    }
    func saveDictionary(_ dictionary: (terms: [String], replacements: [String: String])) {
        // A word the user takes out, however it got in, is never added back automatically.
        let kept = Set(dictionary.terms.map { $0.lowercased() })
        let removed = savedDictionary.terms.map { $0.lowercased() }.filter { !kept.contains($0) }
        if !removed.isEmpty {
            let before = Set(defaults.stringArray(forKey: "removedNames") ?? [])
            defaults.set(Array(before.union(removed)).sorted(), forKey: "removedNames")
        }
        let old = savedDictionary
        let revision = defaults.integer(forKey: "dictionaryRevision") + 1
        var versions = defaults.dictionary(forKey: "dictionaryEntryVersions") as? [String:Int] ?? [:]
        let oldWords = Dictionary(old.terms.map { ($0.lowercased(),$0) },uniquingKeysWith: { a,_ in a })
        let newWords = Dictionary(dictionary.terms.map { ($0.lowercased(),$0) },uniquingKeysWith: { a,_ in a })
        for key in Set(oldWords.keys).union(newWords.keys) where oldWords[key] != newWords[key] { versions["term:"+key] = revision }
        for key in Set(old.replacements.keys).union(dictionary.replacements.keys) where old.replacements[key] != dictionary.replacements[key] { versions["rule:"+key.lowercased()] = revision }
        defaults.set(revision,forKey: "dictionaryRevision"); defaults.set(versions,forKey: "dictionaryEntryVersions")
        let hints = (defaults.stringArray(forKey: "recognitionOnlyTerms") ?? []).filter { kept.contains($0.lowercased()) }
        defaults.set(hints, forKey: "recognitionOnlyTerms")
        defaults.set(dictionary.terms, forKey: "dictionaryTerms")
        defaults.set(dictionary.replacements, forKey: "dictionaryReplacements")
    }
    var vocabulary: Vocabulary {
        let terms = Vocabulary.seed + (defaults.stringArray(forKey: "dictionaryTerms") ?? [])
        let hints = defaults.stringArray(forKey: "recognitionOnlyTerms") ?? []
        var merged = Vocabulary.seedReplacements
        if let user = defaults.dictionary(forKey: "dictionaryReplacements") as? [String: String] {
            for (k, v) in user { merged[k] = v }
        }
        return Vocabulary.effective(terms: terms,
                          replacements: merged,
                          takeBacks: defaults.bool(forKey: "dropTakeBacks") ? takeBackPhrases : [], recognitionOnly: hints)
    }
    var takeBackPhrases: [String] { defaults.stringArray(forKey: "takeBackPhrases") ?? TakeBack.defaults }
    // A :batch id can't answer a dictation, and earlier builds seeded chat apps as Strict (cleanup off).
    private func migrateCleanupSettings() {
        for key in ["cleanupModel", "customCleanupModel"] {
            guard let saved = defaults.string(forKey: key), AICleanup.isBatch(saved) else { continue }
            if let kept = AICleanup.withoutBatch(saved) { defaults.set(kept, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        let presets = appPresets.value.map { preset -> AppPreset in
            var preset = preset
            preset.cleanupModel = preset.cleanupModel.flatMap(AICleanup.withoutBatch)
            return preset
        }
        if presets != appPresets.value { appPresets.value = presets; appPresets.save() }
        // Once only: after that, a list equal to the old seed is the user's own choice.
        if !defaults.bool(forKey: "strictListMigrated") {
            if let saved = defaults.stringArray(forKey: "strictBundleIDs"), let migrated = AICleanup.migratedStrictList(saved) {
                defaults.set(migrated, forKey: "strictBundleIDs")
            }
            defaults.set(true, forKey: "strictListMigrated")
        }
    }
    private var strictBundleIDs: [String] {
        // An explicitly saved empty list must not restore the seed.
        if defaults.object(forKey: "strictBundleIDs") != nil { return defaults.stringArray(forKey: "strictBundleIDs") ?? [] }
        return AICleanup.terminals.sorted()
    }
    private func cleanupContext() -> CleanupContext {
        let front = NSWorkspace.shared.frontmostApplication
        let app = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? previousApp : front
        let resolved = AppPreset.resolve(bundleID: app?.bundleIdentifier, presets: appPresets.value, global: globalRecordingConfiguration,
                                         strictApps: Set(strictBundleIDs), literalApps: AICleanup.literalApps)
        return CleanupContext(app: app?.localizedName, bundleID: app?.bundleIdentifier, style: resolved.configuration.smart ? .smart : .strict)
    }
    private var pendingDeliveries: [CommitToken] = []
    private var shortcutFailure: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()
        // Sam 2026-10-12: the clipboard carries every paste; the user's own
        // clipboard is restored afterwards unless "keep" is chosen.
        policy.setCopyEnabled(true)
        if let raw = defaults.string(forKey: "binding"), Policy.validateBinding(raw), let value = Binding(rawValue: raw) {
            policy.setBinding(value)
        }
        keys.controlOptionChords = policy.binding == .controlOption
        // Grok is the default engine and the choice persists.
        speech.elevenLabsDirect = defaults.bool(forKey: "elevenLabsDirect")
        speech.scribeModel = ScribeSpeech.model(defaults.string(forKey: "scribeModel"))
        speech.cloudCleanupOnDevice = defaults.bool(forKey: "onDeviceCleanup")
        speech.select(SpeechBackend(rawValue: defaults.string(forKey: "speechBackend") ?? "") ?? .cloud)
        speech.oneStep = !speech.elevenLabsDirect && defaults.bool(forKey: "oneStepSpeech")
        speech.keyterms = { [weak self] in self?.vocabulary.terms ?? Vocabulary.seed }
        speech.replacements = { [weak self] in
            guard let self else { return Vocabulary.seedReplacements }
            return Dictionary(uniqueKeysWithValues: self.vocabulary.replacements.map { ($0.from, $0.to) })
        }
        defaults.register(defaults: ["openAtLogin": true, "panelClosesOnOutsideClick": true, "aiCleanup": true, "learnCorrections": true, "autoAddNames": true, "dropTakeBacks": true, "screenTextEnabled": true, "livePreview": true, "copyAfterCapture": true])
        speech.recordedFacts = { [weak self] facts in
            guard let self else { return }
            if facts.speechCredits { refreshElevenLabsCredits() }
            _ = recordCost(speech: facts.speechCost, cleanup: facts.cleanup?.cost, count: false)
            addModelSpend(Self.spends(facts))
            ledger.recognized(facts)
            wordCounter.recognized(facts)
        }
        speech.cleanup = { [weak self] raw, budget, fellBack, context in
            guard let self else { return CleanupOutcome(text: raw, model: nil, millis: 0, note: nil) }
            let vocabulary = context.vocabulary ?? vocabulary
            let rules = TranscriptCleanup.rules(raw, vocabulary: vocabulary)
            // Dictation-side snippet expansion: a recording whose whole cleaned text is exactly one
            // saved cue delivers that snippet and needs no AI pass at all, so it costs nothing. Skipped
            // for technical text, which policy preserves verbatim, and for a cue that is also a
            // dictionary term. Retry runs through this same closure, so it expands alike.
            if let expanded = snippets.value.dictationExpansion(forSpoken: raw, cleaned: rules,
                                                                dictionary: savedDictionary.terms) {
                return CleanupOutcome(text: expanded, model: nil, millis: 0, note: "snippet expanded")
            }
            // Classify what was spoken, not the replaced text: a dictionary entry must never turn
            // code into prose that the AI pass would then receive.
            let configuration = context.preset?.configuration ?? context.savedConfiguration
            let enabled = configuration?.cleanupEnabled ?? defaults.bool(forKey: "aiCleanup")
            let skip = AICleanup.skipReason(raw: raw, rules: rules, enabled: enabled, fellBack: fellBack, context: context, vocabulary: vocabulary)
            guard skip == nil else { return CleanupOutcome(text: rules, model: nil, millis: 0, note: skip) }
            guard budget > 0.3 else { return CleanupOutcome(text: rules, model: nil, millis: 0, note: "no time left") }
            let keyStarted = ProcessInfo.processInfo.systemUptime
            guard let key = await speech.cleanupKey(saved: context.savedConfiguration) else {
                return CleanupOutcome(text: rules, model: nil, millis: 0, note: "cleanup key unavailable")
            }
            let remainingBudget = budget - (ProcessInfo.processInfo.systemUptime - keyStarted)
            guard remainingBudget > 0.3 else { return CleanupOutcome(text: rules, model: nil, millis: 0, note: "no time left") }
            // The model sees the rule-cleaned text, so dictionary fixes aren't undone.
            let cleaner = AICleanup(); cleaner.usage = aiCleanup.usage; cleaner.usageAdmission = aiCleanup.usageAdmission
            if let configuration {
                let id = configuration.cleanupModel
                let ordered = AICleanup.order(choosing: id, from: home.cleanupModels)
                let chosenOnly = ordered.filter { $0.id == id }
                cleaner.order = context.preset?.cleanupOverride == true && !chosenOnly.isEmpty ? chosenOnly : ordered
            } else { cleaner.order = aiCleanup.order }
            return await cleaner.clean(rules, rules: rules, context: context, vocabulary: vocabulary, key: key,
                                       budget: remainingBudget, smart: configuration?.smart ?? (context.style == .smart))
        }
        pill = RecordingPill(); pill.applyAppearance(); pill.clicked = { [weak self] in self?.pillClicked() }
        // Koa's clips decode once in the background; the pill shows Koa as soon as they're ready.
        Task.detached(priority: .utility) { await KoaFrames.shared.load() }
        speech.previewEnabled = defaults.bool(forKey: "livePreview")
        speech.preview.keyterms = { [weak self] in self?.vocabulary.terms ?? [] }
        speech.preview.changed = { [weak self] in
            guard let self else { return }
            pill.preview(settled: speech.preview.settled, volatile: speech.preview.volatile, unavailable: speech.preview.unavailable)
        }
        home = HomePanel(); onboarding = Onboarding()
        buildStatusItem(); wireHome(); wireOnboarding()
        let restore = !defaults.bool(forKey: "keepOnClipboard")
        // `self` is captured weakly here too: the outer Task implicitly captured it strongly, so the
        // `[weak self]` on the stored closure below could not actually shorten the app's lifetime.
        Task { [weak self] in
            guard let self else { return }
            await destination.setRestoreEnabled(restore)
            await destination.setChanged { [weak self] in
                MainActor.assumeIsolated { self?.scheduleObservation() }
            }
        }
        speech.updated = { [weak self] in
            guard let self else { return }
            for (generation, entry) in ledger.delivered(inFlight: inFlight) { writeLog(generation, entry, failure: entry.failure) }
            refresh(); onboarding.refresh()
        }
        speech.event = { [weak self] event in
            guard let self, !quitting else { return }
            if case let .recognitionFailed(id, _) = event, policy.activeGeneration == id {
                latestHealthFailure = .recognitionFailed
                let token = healthChecks.begin(.transcription)
                healthChecks.complete(.transcription, token: token, status: .needsAttention, detail: "The last admitted transcription failed. Review setup or retry from Activity.")
            }
            policy.send(event); checkDeliveryAuthority(); pump()
        }
        // Fn+W clips the page in front; Fn+T clips any front window as Markdown (physical keys 13 and 17).
        // Dispatched asynchronously off the CGEventTap callback so AppKit/Clipboard work never blocks the tap.
        keys.chord = { [weak self] code in
            guard let self, !quitting else { return false }
            // T captures; W does the same, so the old shortcut never types a stray letter into a dictation.
            if code == 13 || code == 17, defaults.bool(forKey: "screenTextEnabled") {
                DispatchQueue.main.async { [weak self] in self?.captureScreen() }
                return true
            }
            if code == 14 {
                DispatchQueue.main.async { [weak self] in self?.openWritingTools() }
                return true
            }
            return false
        }
        keys.receive = { [weak self] event in
            guard let self, !quitting else { return false }
            let context = focusCache.read(at: ProcessInfo.processInfo.systemUptime,
                                          secureInput: IsSecureEventInputEnabled())
            if case .escape = event { invalidateDelivery() }
            let consumed = policy.key(event, context: context)
            checkDeliveryAuthority()
            schedulePump()
            return consumed
        }
        keys.unavailable = { [weak self] in
            guard let self else { return }
            invalidateDelivery()
            shortcutFailure = "Keyboard listener stopped; restarting"
            policy.setListener(Listener()); schedulePump()
        }
        keys.recovered = { [weak self] in
            guard let self, !quitting else { return }
            shortcutFailure = nil
            policy.setListener(Listener(shortcutsEnabled: true, suppressingTapActive: keys.active, competingBindingsAcknowledged: true))
            schedulePump()
        }
        installNotifications()
        timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        speech.discover(); ensureShortcuts(); pump()
        let firstRun = !defaults.bool(forKey: "onboarded")
        if firstRun || !SystemChecks.requiredGranted { showOnboarding() }
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--show-panel=") }) {
            DispatchQueue.main.async { [weak self] in self?.presentRequestedPanel() }
        }
    }
    private func presentRequestedPanel() {
        let requested = CommandLine.arguments.first(where: { $0.hasPrefix("--show-panel=") }) ?? ""
        let name = String(requested.dropFirst("--show-panel=".count))
        let page: HomePanel.Page = name == "clipboard" ? .clipboard : name == "settings" ? .settings : .home
        openPanel(page)
        guard let capture = CommandLine.arguments.first(where: { $0.hasPrefix("--capture-panel=") }) else { return }
        let path = String(capture.dropFirst("--capture-panel=".count))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            do {
                guard let self else { return }
                try home.capturePresented(to: URL(fileURLWithPath: path))
                print("PANEL_CAPTURE_PASS")
            } catch { print("PANEL_CAPTURE_FAILED \(error.localizedDescription)") }
            fflush(stdout)
        }
    }

    private func buildMainMenu() {
        // An accessory app still needs these for Cmd-Q, Cmd-W and editing in its windows.
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Mercurius", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        for (title, submenu) in [("Mercurius", appMenu), ("Edit", edit), ("Window", window)] {
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: ""); entry.submenu = submenu
            main.addItem(entry)
        }
        window.addItem(.separator())
        window.addItem(withTitle: "Writing tools",action: #selector(openWritingTools),keyEquivalent: "")
        window.addItem(withTitle: "Usage & budget",action: #selector(openUsageWindow),keyEquivalent: "")
        window.addItem(withTitle: "Vocabulary inbox",action: #selector(openInboxWindow),keyEquivalent: "")
        window.addItem(withTitle: "App presets",action: #selector(openPresetsWindow),keyEquivalent: "")
        window.addItem(withTitle: "Health & diagnostics",action: #selector(openHealthWindow),keyEquivalent: "")
        NSApp.mainMenu = main
    }
    private func buildStatusItem() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Mercurius")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.setAccessibilityLabel("Mercurius dictation")
        item.button?.target = self; item.button?.action = #selector(statusClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    // Any click on the icon opens the panel on Home (or closes it); everything
    // else, including Quit, is one click inside it.
    @objc private func statusClicked() {
        if home.isShown { home.hide() } else { openPanel(.home) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presentRequestedPanel()
        return false
    }
    private func openPanel(_ page: HomePanel.Page) {
        guard let button = item.button else { return }
        rememberFrontApp(); refreshHome(); home.show(from: button, page: page)
    }
    private func wireHome() {
        home.engine.selectItem(at: speech.backend == .apple ? (speech.cloudCleanupOnDevice ? 3 : 2) : speech.elevenLabsDirect ? 4 : speech.oneStep ? 1 : 0)
        home.engine.target = self; home.engine.action = #selector(changeBackend)
        home.shortcut.selectItem(at: policy.binding == .fn ? 0 : 1)
        home.showDictationKey(fn: policy.binding == .fn)
        home.shortcut.target = self; home.shortcut.action = #selector(changeBinding)
        home.keepOnClipboard.state = defaults.bool(forKey: "keepOnClipboard") ? .on : .off
        home.keepOnClipboard.target = self; home.keepOnClipboard.action = #selector(changeKeep)
        home.aiCleanup.state = defaults.bool(forKey: "aiCleanup") ? .on : .off
        home.aiCleanup.target = self; home.aiCleanup.action = #selector(changeCleanup)
        home.copy = { [weak self] text in _ = self?.copyHistory(text) }
        home.copyEntry = { [weak self] entry in self?.copyHistoryEntry(entry) }
        home.showEntry = { [weak self] entry in self?.showHistoryEntry(entry) }
        home.openSetup = { [weak self] in self?.showOnboarding() }
        home.closed = { [weak self] in self?.windowClosed() }
        correctionWatch.learned = { [weak self] fix in self?.learn(fix) }
        home.learnCorrections.state = defaults.bool(forKey: "learnCorrections") ? .on : .off
        home.learnCorrections.target = self; home.learnCorrections.action = #selector(changeLearn)
        home.autoAddNames.state = defaults.bool(forKey: "autoAddNames") ? .on : .off
        home.autoAddNames.target = self; home.autoAddNames.action = #selector(changeAutoAdd)
        migrateCleanupSettings()
        // Two capture switches became one: it stays on if either was on.
        if defaults.object(forKey: "webClipEnabled") != nil {
            if defaults.bool(forKey: "webClipEnabled") { defaults.set(true, forKey: "screenTextEnabled") }
            defaults.removeObject(forKey: "webClipEnabled")
        }
        if defaults.bool(forKey: "elevenLabsDirect") { refreshElevenLabsCredits() }
        let savedCustomModel = defaults.string(forKey: "customCleanupModel")
        home.customModelField.stringValue = savedCustomModel ?? ""
        home.cleanupModels = AICleanup.pickerModels(from: prices.models)
        aiCleanup.order = AICleanup.order(choosing: defaults.string(forKey: "cleanupModel"), from: home.cleanupModels)
        aiCleanup.smart = defaults.string(forKey: "cleanupStyle") != "strict"
        home.cleanupStyle.selectItem(at: aiCleanup.smart ? 0 : 1)
        home.cleanupStyle.target = self; home.cleanupStyle.action = #selector(changeCleanupStyle)
        home.strictApps = { [weak self] in self?.strictBundleIDs ?? [] }
        home.saveStrictApps = { [weak self] ids in
            self?.defaults.set(ids, forKey: "strictBundleIDs"); self?.refreshHome()
        }
        home.populateCleanupModels(custom: savedCustomModel, selected: aiCleanup.order[0].id)
        home.cleanupModel.target = self; home.cleanupModel.action = #selector(changeCleanupModel)
        // The picked transcription model, persisted; the picker gains every
        // transcription model in the live catalogue when it arrives.
        speech.transcriptionModel = defaults.string(forKey: "speechModel") ?? CloudSpeech.model
        home.speechModelIDs = CloudSpeech.pickerSpeechModels(from: prices.models)
        speech.liveSpeechModels = Self.liveSpeechModels(prices.models)
        if home.speechModel.numberOfItems == 0 { home.rebuildSpeechPicker() }
        if let index = home.speechModel.itemArray.firstIndex(where: {
            $0.representedObject as? String == speech.transcriptionModel }) { home.speechModel.selectItem(at: index) }
        home.speechModel.target = self; home.speechModel.action = #selector(changeSpeechModel)
        if home.scribeModel.numberOfItems == 0 { home.rebuildScribePicker() }
        if let index = home.scribeModel.itemArray.firstIndex(where: {
            $0.representedObject as? String == speech.scribeModel }) { home.scribeModel.selectItem(at: index) }
        home.scribeModel.target = self; home.scribeModel.action = #selector(changeScribeModel)
        home.saveCustomCleanupModel = { [weak self] id in
            guard let self else { return }
            defaults.set(id, forKey: "customCleanupModel")
            defaults.set(id, forKey: "cleanupModel")
            aiCleanup.order = AICleanup.order(choosing: id, custom: id)
            home.refreshPrices()
        }
        home.rerunCleanup = { [weak self] entry in self?.rerunEntryCleanup(entry) }
        home.copyAfterCapture.state = defaults.bool(forKey: "copyAfterCapture") ? .on : .off
        home.copyAfterCapture.target = self; home.copyAfterCapture.action = #selector(changeCopyAfterCapture)
        home.opensAtLogin.state = defaults.bool(forKey: "openAtLogin") ? .on : .off
        home.opensAtLogin.target = self; home.opensAtLogin.action = #selector(changeOpenAtLogin)
        applyOpenAtLogin()
        home.closesOnOutsideClick.state = defaults.bool(forKey: "panelClosesOnOutsideClick") ? .on : .off
        home.closesOnOutsideClick.target = self; home.closesOnOutsideClick.action = #selector(changeCloseOnOutsideClick)
        home.screenText.state = defaults.bool(forKey: "screenTextEnabled") ? .on : .off
        home.screenText.target = self; home.screenText.action = #selector(changeScreenText)
        home.price = { [weak self] in self?.prices.price($0) }
        usageStore.migrateToday(defaults: defaults)
        speech.usage = { [weak self] event in self?.usageStore.record(event) }
        aiCleanup.usage = { [weak self] event in self?.usageStore.record(event) }
        speech.usageAdmission = { [weak self] event in self?.usageStore.admit(event) ?? false }
        aiCleanup.usageAdmission = { [weak self] event in self?.usageStore.admit(event) ?? false }
        home.approvalFirstNotice = !defaults.bool(forKey: "seenVocabularyInboxNotice")
        home.showVocabularyInbox = { [weak self] in self?.showVocabularyInbox() }
        home.showAppPresets = { [weak self] in self?.showAppPresets() }
        home.showHealth = { [weak self] in self?.showHealth() }
        home.showWritingTools = { [weak self] in self?.openWritingTools() }
        home.showUsage = { [weak self] in self?.showUsage() }
        usageStore.changed = { [weak self] in self?.checkBudget(); self?.updateUsageHistoryCosts() }
        home.todaysCosts = { [weak self] in self?.usageFooter() ?? (nil, nil) }
        home.pricesUpdated = { [weak self] in self?.prices.fetchedAt }
        home.openedSettings = { [weak self] in self?.prices.refresh() }
        prices.updated = { [weak self] in
            guard let self else { return }
            home.updateCatalogue(cleanup: AICleanup.pickerModels(from: prices.models),
                                 speech: CloudSpeech.pickerSpeechModels(from: prices.models))
            speech.liveSpeechModels = Self.liveSpeechModels(prices.models)
            // A saved model that only exists in the live catalogue now resolves.
            aiCleanup.order = AICleanup.order(choosing: defaults.string(forKey: "cleanupModel"), from: home.cleanupModels)
            if let index = home.cleanupModel.itemArray.firstIndex(where: {
                $0.representedObject as? String == aiCleanup.order[0].id }) { home.cleanupModel.selectItem(at: index) }
            if let index = home.speechModel.itemArray.firstIndex(where: {
                $0.representedObject as? String == speech.transcriptionModel }) { home.speechModel.selectItem(at: index) }
            home.refreshPrices(); home.refreshCosts()
        }
        prices.refresh()
        home.clipboardItems = { [weak self] in self?.clipboard.items ?? [] }
        home.clipboardProblem = { [weak self] in self?.clipboard.problem }
        home.clipboardAction = { [weak self] action, item in self?.clipboardAction(action, item) }
        // Every change to the main clipboard reaches the Clipboard page at once, shown or not, so
        // a dictation erased at 10 minutes leaves the page's rows, labels and buttons too.
        clipboard.changed = { [weak self] in self?.clipboardChanged() }
        // The vault's saved notes are listed in it as saved clips, and the old Clips page's loose
        // clips (still within their 48 hours) as unsaved ones, so they keep Review, Save to Clips
        // and Pin now that page is gone. Looked for at every launch and safe to repeat: there is
        // no "done" flag to set too early (the ones earlier builds kept are removed).
        for key in ["clipboardImportedVault", "clipboardImportedLooseClips"] { defaults.removeObject(forKey: key) }
        Task { [clipboard] in await clipboard.importFromVault() }
        home.livePreview.state = defaults.bool(forKey: "livePreview") ? .on : .off
        let style = PillStyle.current
        home.pillTheme.selectItem(at: PillStyle.Theme.allCases.firstIndex(of: style.theme) ?? 0)
        home.pillMotion.selectItem(at: PillStyle.Motion.allCases.firstIndex(of: style.motion) ?? 0)
        home.pillTheme.target = self; home.pillTheme.action = #selector(changePillStyle)
        home.pillMotion.target = self; home.pillMotion.action = #selector(changePillStyle)
        home.livePreview.target = self; home.livePreview.action = #selector(changeLivePreview)
        home.quit = { [weak self] in self?.quit() }
        home.manageCredentials = { [weak self] in
            guard let self else { return }
            if credentialWindow == nil { credentialWindow = CredentialSetupWindow() }
            credentialWindow?.show()
        }
        home.allowGrok = { [weak self] in self?.speech.authorizeCloudCredential() }
        home.chooseLanguages = { [weak self] in self?.showLanguages() }
        Task { [weak self] in await SpeechLanguageStore.prepareChosen(); self?.speech.discover() }
        home.dropTakeBacks.state = defaults.bool(forKey: "dropTakeBacks") ? .on : .off
        home.dropTakeBacks.target = self; home.dropTakeBacks.action = #selector(changeTakeBacks)
        home.takeBackPhrases = { [weak self] in self?.takeBackPhrases ?? TakeBack.defaults }
        home.saveTakeBacks = { [weak self] phrases in self?.defaults.set(phrases, forKey: "takeBackPhrases") }
        home.retry = { [weak self] item in self?.retryRecording(item) }
        home.retryCurrent = { [weak self] item in self?.retryRecording(item, useCurrent: true) }
        home.suggestions = { [weak self] in
            guard let self else { return [] }
            return RepeatedTerms.suggest(names: namesSeen.map(\.words), existing: vocabulary,
                                         isCommonWord: CorrectionWatch.isCommonWord)
        }
        home.recognitionOnlyTerms = { [weak self] in self?.defaults.stringArray(forKey: "recognitionOnlyTerms") ?? [] }
        home.savedDictionary = { [weak self] in self?.savedDictionary ?? (terms: [], replacements: [:]) }
        home.saveDictionary = { [weak self] dictionary in self?.saveDictionary(dictionary) }
    }
    private func showLanguages() {
        languageWindow.changed = { [weak self] in
            guard let self else { return }
            speech.discover(); onboarding.refresh(force: true)
        }
        languageWindow.show()
    }
    private func wireOnboarding() {
        onboarding.closed = { [weak self] in
            self?.defaults.set(true, forKey: "onboarded"); self?.windowClosed()
        }
        onboarding.rows = { [weak self] in self?.setupRows() ?? [] }
        permissionPrompts.changed = { [weak self] in
            guard let self, !quitting else { return }
            onboarding.refresh(force: true); speech.discover(); ensureShortcuts()
        }
    }
    private func setupRows() -> [Onboarding.Row] {
        typealias Row = Onboarding.Row
        var rows: [Row] = []
        let mic = SystemChecks.microphone
        rows.append(Row(title: "Microphone", detail: mic ? "Allowed" : "So Mercurius can hear you.",
            status: mic ? .done : .todo, button: mic ? nil : "Allow", action: { [weak self] in self?.requestPermission(.microphone) }))
        let ax = SystemChecks.accessibility
        rows.append(Row(title: "Accessibility", detail: ax ? "Allowed" : "So Mercurius can paste into the app you're using. Turn on Mercurius in the list.",
            status: ax ? .done : .todo, button: ax ? nil : "Allow", action: { [weak self] in self?.requestPermission(.accessibility) }))
        let input = SystemChecks.inputMonitoring
        rows.append(Row(title: "Input Monitoring", detail: input ? "Allowed" : "So Mercurius notices when you hold the shortcut. Turn on Mercurius in the list.",
            status: input ? .done : .todo, button: input ? nil : "Allow", action: { [weak self] in self?.requestPermission(.inputMonitoring) }))
        if policy.binding == .fn {
            let free = SystemChecks.globeKeyFree
            rows.append(Row(title: "Globe (🌐) key", detail: free ? "Set to Do Nothing"
                : "In Keyboard settings set “Press 🌐 key to” to Do Nothing, or macOS also reacts when you hold Fn.",
                status: free ? .done : .warning, button: free ? nil : "Open Keyboard", action: { SystemChecks.openKeyboard() }))
        }
        if policy.binding == .fn, SystemChecks.museTakesFn {
            rows.append(Row(title: "Muse also dictates on Fn",
                detail: "Change Muse's dictation key in its settings, or quit Muse, or both apps type what you say.",
                status: .warning, button: nil, action: nil))
        }
        if SystemChecks.wisprRunning {
            rows.append(Row(title: "Wispr Flow is running",
                detail: "Quit it or change its shortcut, or both apps will record when you hold the key.",
                status: .warning, button: nil, action: nil))
        }
        if speech.backend == .cloud || (speech.backend == .apple && speech.cloudCleanupOnDevice) {
            let ready = speech.cloudCredentialReady, grok = speech.backend == .cloud
            rows.append(Row(title: grok ? (speech.elevenLabsDirect ? "ElevenLabs Scribe" : "OpenRouter speech") : "AI cleanup key", detail: ready ? "Connected"
                : grok ? "Not connected yet. On-device speech is used until it is." : "Not connected yet. Text is pasted without AI cleanup until it is.",
                status: ready ? .done : .info, button: ready ? nil : "Allow Keychain access",
                action: { [weak self] in self?.speech.authorizeCloudCredential() }))
        }
        let languages = SpeechLanguageStore.choice
        rows.append(Row(title: "Speech language",
            detail: languages.chosen.isEmpty ? "Choose the languages you speak. Only those are installed."
                : languages.chosen.map(SpeechLanguageStore.name).joined(separator: ", "),
            status: languages.chosen.isEmpty ? .info : .done, button: languages.chosen.isEmpty ? "Choose" : "Change",
            action: { [weak self] in self?.showLanguages() }))
        let local = SystemChecks.speech
        rows.append(Row(title: "On-device speech", detail: local ? "Allowed for local dictation and live words"
                : "Lets dictation keep working offline.",
            status: local ? .done : .info, button: local ? nil : "Allow", action: { [weak self] in self?.requestPermission(.speech) }))
        if permissionPrompts.isRequesting {
            rows = rows.map { row in var row = row; row.enabled = false; return row }
        }
        if permissionPrompts.awaitingSettings {
            rows.append(Row(title: "Return from System Settings",
                detail: "Finish or dismiss the permission dialog, then choose Continue setup. Permission status is checked separately.",
                status: .info, button: "Continue setup", action: { [weak self] in
                    Task { await self?.permissionPrompts.receive(.resumed) }
                }))
        }
        return rows
    }
    private func requestPermission(_ permission: PermissionSetup.Permission) {
        Task { [weak self] in
            await self?.permissionPrompts.receive(.request(permission))
        }
    }
    // Starts the keyboard listener as soon as both grants exist; no reopening.
    private func ensureShortcuts() {
        guard !quitting, !keys.active else { return }
        guard SystemChecks.accessibility, SystemChecks.inputMonitoring else {
            shortcutFailure = "Finish setup to use the shortcut"
            return
        }
        if keys.enable() {
            shortcutFailure = nil
            policy.setListener(Listener(shortcutsEnabled: true, suppressingTapActive: true,
                                        competingBindingsAcknowledged: true))
        } else {
            shortcutFailure = "Shortcut not active yet; if this stays, quit and reopen Mercurius"
            policy.setListener(Listener())
        }
        refresh(); onboarding.refresh()
    }
    private func observe() {
        guard !quitting, observationTask == nil else { return }
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let revision = observationRevision
        focusObservedAt = requestedAt
        observationTask = Task { [weak self, destination] in
            let context = await destination.snapshot()
            guard let self else { return }
            observationTask = nil
            guard !quitting, !Task.isCancelled, observationRevision == revision else { return }
            if context.destination != lastDestination || context.secure { invalidateDelivery() }
            lastDestination = context.destination
            focusCache.update(context, at: requestedAt)
            policy.send(.observed(context)); checkDeliveryAuthority(); pump()
        }
    }
    private func scheduleObservation() {
        observationRevision &+= 1
        invalidateDelivery(); focusCache.invalidate(); lastDestination = nil
        policy.send(.observed(Context(destination: nil, secureEventInput: IsSecureEventInputEnabled())))
        pump()
        observe()
    }
    private func invalidateDelivery() { deliveryPermit?.revoke() }
    private func checkDeliveryAuthority() {
        guard let authority = deliveryAuthority else { return }
        if !authority.valid(controller: policy.generation, recovery: policy.recovery?.generation,
                            secure: IsSecureEventInputEnabled()) { invalidateDelivery() }
    }
    private func currentContext() -> Context {
        focusCache.read(at: ProcessInfo.processInfo.systemUptime, secureInput: IsSecureEventInputEnabled())
    }
    private func schedulePump() {
        guard !pumpScheduled, !quitting else { return }
        pumpScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pumpScheduled = false
            self.pump()
        }
    }
    private func poll() {
        guard !quitting else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - focusObservedAt >= 0.2 { observe() }
        else if IsSecureEventInputEnabled() {
            invalidateDelivery()
            policy.send(.observed(Context(destination: nil, secureEventInput: true)))
        }
        if IsSecureEventInputEnabled() {
            writingTools?.interrupt(reason: "Protected input cancelled writing tools")
            pill?.hide()
        }
        policy.send(.tick)
        checkDeliveryAuthority()
        if policy.isActive && speech.permissionsRevoked { policy.send(.interrupted("Permission revoked")) }
        // Drain cancellation before polling an adapter that belongs to that session.
        pump()
        speech.poll()
        if policy.listener.selected && !keys.active {
            shortcutFailure = "Keyboard listener stopped; restarting"
            policy.setListener(Listener())
        }
        if now - checkedAt >= 1 {
            checkedAt = now
            ensureShortcuts(); onboarding.refresh()
            if now - outboxPurgedAt >= 60 {
                outboxPurgedAt = now; AudioOutbox.shared.purge()
                Task.detached(priority: .utility) { ClipsVault.purge() }
                Task { [clipboard] in await clipboard.dropMissingNotes() }
            }
            // Dictation text leaves the clipboard on the same 10-minute rule as History; clips and captures after 48 h.
            clipboard.purge()
            if home.isShown { refreshHome() }
        }
        if !policy.isActive && now - discoveryAt >= 30 { discoveryAt = now; speech.discover() }
        pill.level(speech.level); pill.tick(now: now)
        if defaults.bool(forKey: "learnCorrections") { correctionWatch.tick(now: now) }
        pump()
    }
    private func pump() {
        guard !pumping, !quitting else { return }
        pumping = true
        var batch = policy.drainActions()
        while !batch.isEmpty {
            for action in batch {
                switch action {
                case let .startupRequested(id):
                    writingTools?.stopRecording()
                    stopHealthMicrophone()
                    ledger.register(id, oneStep: speech.oneStep)
                    if let previous = logTracker.started(id) {
                        // The next recording started before the last one settled.
                        finishLog(previous, failure: nil)
                    }
                    // The mic starts at once so the first word isn't clipped; a tap
                    // shorter than Policy.minimumHeld is discarded by the policy.
                    if policy.activeGeneration == id {
                        var context = cleanupContext()
                        let global = globalRecordingConfiguration
                        let resolved = AppPreset.resolve(bundleID: context.bundleID,presets: appPresets.value,global: global,strictApps: Set(strictBundleIDs),literalApps: AICleanup.literalApps)
                            .falling(backTo: global, speechAvailable: { home.speechModelIDs.contains($0) }, cleanupAvailable: { id in home.cleanupModels.contains { $0.id == id } })
                        var config = resolved.configuration
                        config.speechModel = Self.recordingSpeechModel(config, scribe: speech.scribeModel,
                            cloud: defaults.string(forKey: "speechModel") ?? CloudSpeech.model)
                        speech.elevenLabsDirect = config.engine == .elevenLabs
                        speech.oneStep = config.engine == .oneStep
                        speech.transcriptionModel = config.speechModel
                        speech.cloudCleanupOnDevice = config.engine == .local && config.cleanupEnabled
                        speech.select(config.engine == .local ? .apple : .cloud)
                        context.preset = resolved
                        context.vocabulary = vocabulary
                        context.style = config.smart ? .smart : .strict
                        speech.recoveryConfiguration = config
                        speech.startup(id, context: context,
                            cleanOneStep: context.cleansOneStep(enabled: config.cleanupEnabled))
                    }
                case let .sampleStartClipboard(id):
                    if policy.copyEnabled && policy.activeGeneration == id && !IsSecureEventInputEnabled() {
                        policy.send(.startClipboardSample(id, NSPasteboard.general.changeCount))
                    }
                case let .captureStarted(id):
                    if policy.activeGeneration == id { speech.capture(id) }
                case let .finalizeRequested(id, _): speech.finalize(id)
                case let .closeAdapters(id): speech.close(id)
                case let .outcome(generation, outcome):
                    historyOutcomes[generation, default: []].removeAll { $0 == outcome || (outcome == .pasteConfirmed && $0 == .pasteSentUnconfirmed) }
                    historyOutcomes[generation, default: []].append(outcome)
                    for index in history.indices where history[index].generation == generation {
                        history[index].outcomes = historyOutcomes[generation] ?? []
                        if transcriptDetailID == history[index].id { transcriptDetailStatus?.stringValue = history[index].deliveryStatus }
                    }
                    if outcome == .recognized {
                        let token = healthChecks.begin(.transcription)
                        healthChecks.complete(.transcription, token: token, status: .ready,
                            detail: "A recent admitted session produced text. This does not test the current selection or confirm delivery.")
                    }
                case let .commitReady(token): pendingDeliveries.append(token)
                default: break
                }
            }
            batch = policy.drainActions()
        }
        pumping = false
        let recoveryGeneration = policy.recovery?.generation
        pendingDeliveries.removeAll { $0.generation != recoveryGeneration }
        checkDeliveryAuthority()
        refresh()
        beginDelivery()
    }
    private func beginDelivery() {
        guard !quitting, deliveryTask == nil, !pendingDeliveries.isEmpty else { return }
        let token = pendingDeliveries.removeFirst()
        // The Paste-last request belongs to this delivery only; consume it now
        // so an early return can never turn a later Copy into a paste.
        let wantsPaste = pasteAfterCopy, expectedPasteDestination = requestedPasteDestination
        pasteAfterCopy = false; requestedPasteDestination = nil
        deliveryTask = Task { [weak self, destination] in
            guard let self else { return }
            deliveringGeneration = token.generation
            defer {
                deliveryPermit?.revoke(); deliveryPermit = nil; deliveryAuthority = nil
                deliveryTask = nil; deliveringGeneration = nil
                for (generation, entry) in ledger.delivered(inFlight: inFlight) { writeLog(generation, entry, failure: entry.failure) }
                pump()
            }
            policy.send(.observed(await destination.snapshot()))
            pump()
            var context = await destination.snapshot()
            guard !quitting, !Task.isCancelled,
                  let recovery = policy.recovery, recovery.generation == token.generation else { return }
            context.secureEventInput = context.secureEventInput || IsSecureEventInputEnabled()
            // Clipboard sampling follows worker queries and checks the CURRENT
            // setting on the main actor. Copy Off therefore never queues a read.
            if !context.secure, policy.copyEnabled, policy.needsClipboardCounter(for: token) {
                context.clipboardCounter = NSPasteboard.general.changeCount
            }
            let permit = EffectPermit(expiresAt: min(recovery.receivedAt + Policy.recoveryLifetime,
                ProcessInfo.processInfo.systemUptime + 1))
            deliveryPermit = permit
            deliveryAuthority = DeliveryAuthority(controllerGeneration: policy.generation,
                                                   recoveryGeneration: token.generation)
            lastFocusTookNoText = context.destination.map(NativeTargets.takesNoText) ?? false
            ledger.delivering(token.generation, context: context,
                              app: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                              facts: speech.lastFacts?.generation == token.generation ? speech.lastFacts : nil)
            let effect = await policy.commitAsync(token, context: context) { [weak self, destination, permit] effect in
                let result = await destination.perform(effect, permit: permit)
                await self?.recordDelivery(token.generation, result)
                return result
            }
            switch effect {
            case let .axInsert(_, target, _)? where policy.lastSubmittedOutcome == .insertedConfirmed:
                if defaults.bool(forKey: "learnCorrections"), let text = policy.recovery?.text {
                    let field = await destination.deliveredField(target)
                    correctionWatch.start(pasted: text, field: field, now: ProcessInfo.processInfo.systemUptime)
                }
                if !defaults.bool(forKey: "keepOnClipboard") {
                    do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                    guard !quitting else { return }
                    _ = await destination.restoreClipboard()
                }
            case let .pasteKey(_, target)? where policy.lastSubmittedOutcome == .pasteSentUnconfirmed:
                // Give the target app time to read the clipboard, then put the
                // user's own clipboard back unless they asked to keep the text.
                // Cancelled (quitting) leaves the transcript, never a half-read paste.
                // A blind paste (no field visible to AX) keeps the text, so it's never lost.
                if defaults.bool(forKey: "learnCorrections"), let text = policy.recovery?.text {
                    let field = await destination.deliveredField(target)
                    correctionWatch.start(pasted: text, field: field, now: ProcessInfo.processInfo.systemUptime)
                }
                // Give the target app time to read the clipboard, then read the field once: one more
                // copy of this delivery's text than before the paste is confirmed; anything
                // else stays honestly unconfirmed.
                // An app-level paste has no field to read and keeps the text on the clipboard: no wait.
                guard target.element != NativeTargets.appLevelElement else { break }
                let delivered = recovery.text
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                guard !quitting else { return }
                // Secure input can start while the readback runs, before its observation clears recovery.
                if await destination.pasteLanded(target, text: delivered), !quitting,
                   !IsSecureEventInputEnabled(), !currentContext().secure {
                    policy.confirmPaste(token.generation); schedulePump()
                    // The result pill already said "check editor"; it now says the paste landed.
                    if !pillActive, !clipOwnsPill, policy.lastOutcomes.last == .pasteConfirmed,
                       let result = resultDisplay() { pill.show(result, now: ProcessInfo.processInfo.systemUptime) }
                }
                if !defaults.bool(forKey: "keepOnClipboard"), NativeTargets.restoresClipboard(after: target) {
                    _ = await destination.restoreClipboard()
                }
            case .clipboardWrite? where wantsPaste && policy.lastSubmittedOutcome == .copied:
                _ = policy.request(.paste, context: currentContext(), expectedDestination: expectedPasteDestination)
            default: break
            }
        }
    }
    private var lastPillTrace = ""
    private var lastPillReportAt: TimeInterval = 0
    // Popup diagnosis: every change of state, focus class or real on-screen visibility. No transcript text.
    private func tracePill(now: TimeInterval) {
        let context = currentContext()
        // FrontApp walks the window list; while idle the cheap answer is enough for a trace.
        let front = (PillDisplay.active(policy.state) != nil ? FrontApp.current() : NSWorkspace.shared.frontmostApplication)?.bundleIdentifier ?? "none"
        let destination = context.destination.map {
            "class=\($0.classification) route=\($0.route) editable=\($0.editable) appLevel=\($0.element == NativeTargets.appLevelElement)"
        } ?? "destination=none"
        let state = "state=\(policy.state) front=\(front) contextSecure=\(context.secure) "
            + "secureInput=\(IsSecureEventInputEnabled()) \(destination)"
        let active = PillDisplay.active(policy.state) != nil
        // WindowServer listing is not free: at most four times a second, and only while a popup should show.
        let wantsReport = active && now - lastPillReportAt >= 0.25
        if wantsReport { lastPillReportAt = now }
        // Focus flickers constantly while idle, so idle lines only note a change of state or front app.
        let idleKey = "state=\(policy.state) front=\(front) secureInput=\(IsSecureEventInputEnabled())"
        let line = active ? state + (wantsReport ? " " + pill.visibilityReport().description : "") : idleKey
        guard active ? wantsReport && line != lastPillTrace : line != lastPillTrace else { return }
        lastPillTrace = line
        PillTrace.log.notice("\(line, privacy: .public)")
    }
    // A new session's popup sits beside the text cursor; until the AX worker answers (or when it
    // can't), it sits bottom-centre.
    private func anchorPillAtCaret() {
        pill.anchor = nil
        Task { [weak self, destination] in
            let caret = await destination.caretRect()
            guard let self, let caret, pillActive, let top = NSScreen.screens.first?.frame.maxY else { return }
            pill.anchor = RecordingPill.cocoaRect(fromAX: caret, primaryTop: top)
        }
    }
    private func resultDisplay() -> PillContent? {
        PillDisplay.result(policy.lastOutcomes,
                           onDevice: speech.backend == .cloud && speech.lastEngine == .apple,
                           noTextField: lastFocusTookNoText, grokOff: grokLocked,
                           transcript: policy.recovery?.text,
                           cleanup: speech.lastFacts?.generation == policy.recovery?.generation ? speech.lastFacts?.cleanup : nil,
                           recoveryGeneration: policy.recovery?.generation,
                           controllerGeneration: policy.generation)
    }
    private func refresh() {
        guard pill != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        defer { tracePill(now: now) }
        if let active = PillDisplay.active(policy.state) {
            pill.engine = speech.backend == .apple ? (speech.cloudCleanupOnDevice && defaults.bool(forKey: "aiCleanup") && !cleanupKeyLocked ? "On-device + cleanup" : "On-device")
                : grokLocked ? "On-device"
                : speech.oneStep ? "Gemini one-step" : Self.engineName(speech.elevenLabsDirect ? ScribeSpeech.id(speech.scribeModel) : speech.effectiveSpeechModel)
                    + (defaults.bool(forKey: "aiCleanup") ? " + cleanup" : "")
            // Nothing on screen while a password field has secure input.
            if currentContext().secure { pill.hide() } else {
                if !pillActive { anchorPillAtCaret() }
                pill.show(active, now: now)
            }
            pillActive = true
        } else if pillActive {
            pillActive = false
            if clipOwnsPill { return }
            if policy.state == .recoverableError { pill.show(.failed(policy.message), now: now) }
            else if let result = resultDisplay() { pill.show(result, now: now) } else { pill.hide() }
        }
        if PillDisplay.active(policy.state) == nil, let generation = logTracker.settled() {
            finishLog(generation, failure: policy.state == .recoverableError ? policy.message : nil)
        }
        let recording = policy.state == .recordingHeld || policy.state == .recordingToggle
        Self.updateStatusTint(item.button, recording: recording)
        if let r = policy.recovery, r.generation != historyGeneration {
            historyGeneration = r.generation
            let facts = speech.lastFacts?.generation == r.generation ? speech.lastFacts : nil
            let at = Date()
            history.append(HistoryEntry(text: r.text, at: at, raw: facts?.raw == r.text ? nil : facts?.raw,
                                        detail: facts.map { Self.badge($0, cloud: speech.oneStep ? "Gemini one-step" : ModelCosts.shortName(speech.transcriptionModel)) },
                                        usageRecordingID: facts?.usageRecordingID, costs: facts.flatMap { usageStore.costLine(recordingID: $0.usageRecordingID) } ?? facts.map(Self.costLine), corrections: facts?.dictionaryCorrections ?? [],
                                        generation: r.generation, outcomes: historyOutcomes[r.generation] ?? [], wordCountGeneration: r.generation,
                                        smart: speech.recoveryConfiguration?.smart))
            clipboard.add(dictation: r.text, at: at)
            namesSeen.append((Date(), RepeatedTerms.terms(in: r.text)))
            addNamesSaidOften()
        }
        // Text lives in memory for 10 minutes, the names from it for a day (both go when the app quits).
        history.removeAll { $0.at < Date().addingTimeInterval(-RepeatedTerms.textLifetime) }
        let keptIDs = Set(history.map(\.id))
        reCleanTokens = reCleanTokens.filter { keptIDs.contains($0.key) }
        let keptGenerations = Set(history.compactMap(\.generation)).union([policy.generation])
        historyOutcomes = historyOutcomes.filter { keptGenerations.contains($0.key) }
        namesSeen.removeAll { $0.at < Date().addingTimeInterval(-RepeatedTerms.namesLifetime) }
        speech.purgeExpiredFacts()
        wordCounter.purge(now: ProcessInfo.processInfo.systemUptime, recovering: policy.recovery?.generation,
            preserving: Set(history.compactMap(\.wordCountGeneration)))
        // Purge expired text from the window too, even while it is closed.
        writingTools?.refreshRetention()
        home.update(history: history, failed: AudioOutbox.shared.list())
        if home.isShown { refreshHome() }
        checkBudget()
    }
    static func updateStatusTint(_ button: NSButton?, recording: Bool) {
        // The setter invalidates AppKit's status-item snapshot even for an equal tint.
        let tint: NSColor? = recording ? .systemRed : nil
        guard let button, button.contentTintColor != tint else { return }
        button.contentTintColor = tint
    }

    // "Grok · 2.1 s · cleaned 0.4 s" for History; the charges go on their own line (costLine).
    // Transcription ids the catalogue lists; nil while it is empty so no backup is ruled out.
    nonisolated static func liveSpeechModels(_ models: [CatalogModel]) -> Set<String>? {
        let ids = Set(models.filter(\.transcription).map(\.id))
        return ids.isEmpty ? nil : ids
    }
    // With ElevenLabs as the global engine the global model is Scribe's, so a preset that picks
    // OpenRouter and inherits the model gets the saved OpenRouter model instead.
    nonisolated static func recordingSpeechModel(_ config: RecoveryConfiguration, scribe: String, cloud: String) -> String {
        switch config.engine {
        case .local: "apple-speech"
        case .oneStep: CloudSpeech.oneStepModel
        case .elevenLabs: ScribeSpeech.id(scribe)
        case .cloud: ScribeSpeech.isDirect(config.speechModel) ? cloud : config.speechModel
        }
    }
    nonisolated static func engineName(_ model: String) -> String {
        if model.hasPrefix("x-ai/grok-stt") { return "Grok" }
        if ScribeSpeech.isDirect(model) { return "ElevenLabs " + ScribeSpeech.displayName(model) }
        return model == CloudSpeech.oneStepModel ? "Gemini one-step" : ModelCosts.shortName(model)
    }
    nonisolated static func badge(_ facts: LocalSpeech.Facts, cloud: String = "Grok") -> String {
        let recordedModel = facts.speechModel.map(Self.engineName) ?? cloud
        var parts = [facts.engine == .cloud ? (facts.speechCredits && !ScribeSpeech.isDirect(facts.speechModel) ? "ElevenLabs Scribe" : recordedModel) : "On-device",
                     String(format: "%.1f s", Double(facts.speechMillis) / 1000)]
        if let fallback = facts.fallback { parts.append(fallback) }
        if let cleanup = facts.cleanup, cleanup.model != nil {
            parts.append(String(format: "cleaned %.1f s", Double(cleanup.millis) / 1000))
        } else if let status = PillDisplay.cleanupStatus(facts.cleanup) { parts.append(status) }
        return parts.joined(separator: " · ")
    }
    // "grok-stt-1.0 $0.0011 · gpt-oss-120b $0.00006": every model that ran and what it cost.
    nonisolated static func costLine(_ facts: LocalSpeech.Facts) -> String {
        let charges = spends(facts).filter { !facts.speechCredits || !ScribeSpeech.isDirect($0.model) }
        let dollars = ModelCosts.describe(charges)
        if facts.speechCredits { return "ElevenLabs credits" + (dollars.map { " · " + $0 } ?? "") }
        return dollars ?? "free, on this Mac"
    }
    // The models one dictation used and what each cost: the speech model, then every cleanup
    // model that answered, each with its own charge (a rejected answer still costs its model).
    nonisolated static func spends(_ facts: LocalSpeech.Facts) -> [ModelCosts.Spend] {
        var spends: [ModelCosts.Spend] = []
        if facts.engine == .cloud, let model = facts.speechModel { spends.append(.init(model: model, usd: facts.speechCost)) }
        if let cleanup = facts.cleanup {
            if !cleanup.charges.isEmpty { spends += cleanup.charges }
            else if let model = cleanup.model { spends.append(.init(model: model, usd: cleanup.cost)) }
            else if let cost = cleanup.cost, cost > 0 { spends.append(.init(model: "AI cleanup", usd: cost)) }
        }
        return spends
    }
    private func addModelSpend(_ spends: [ModelCosts.Spend]) {
        guard !spends.isEmpty else { return }
        let today = Self.dayKey(Date())
        let totals = ModelCosts.add(spends, to: defaults.dictionary(forKey: "costModels") as? [String: Double] ?? [:],
                                    day: defaults.string(forKey: "costModelsDay"), today: today)
        let unknown = ModelCosts.addUnknown(spends, to: defaults.stringArray(forKey: "costModelsUnknown") ?? [],
                                            day: defaults.string(forKey: "costModelsDay"), today: today)
        defaults.set(totals, forKey: "costModels"); defaults.set(unknown, forKey: "costModelsUnknown")
        defaults.set(today, forKey: "costModelsDay")
        home.refreshCosts()
    }
    // "grok-stt-1.0 $0.012 · gpt-oss-120b $0.0009", today only.
    private var todaysModelCosts: String? {
        guard defaults.string(forKey: "costModelsDay") == Self.dayKey(Date()) else { return nil }
        return ModelCosts.summary(defaults.dictionary(forKey: "costModels") as? [String: Double] ?? [:],
                                  unknown: defaults.stringArray(forKey: "costModelsUnknown") ?? [])
    }
    private func recordDelivery(_ generation: UInt64, _ result: EffectResult) {
        ledger.record(generation, result)
        if let words = wordCounter.delivered(generation, result: result) {
            _ = recordCost(speech: nil, cleanup: nil, count: true, spokenWords: words)
        }
    }
    private func inFlight(_ generation: UInt64) -> Bool {
        speech.isFinalizing(generation) || deliveringGeneration == generation || pendingDeliveries.contains { $0.generation == generation }
    }
    // A recording ended; its line is written once its own deliveries are done.
    private func finishLog(_ generation: UInt64, failure: String?) {
        guard let entry = ledger.finished(generation, inFlight: inFlight(generation), failure: failure) else { return }
        writeLog(generation, entry, failure: entry.failure)
    }
    // One text-free line per finished recording in ~/Library/Logs/Mercurius.
    private func writeLog(_ generation: UInt64, _ entry: RecordingLedger.Entry, failure: String?) {
        let facts = entry.facts ?? (speech.lastFacts?.generation == generation ? speech.lastFacts : nil)
        let engine = facts?.speechCredits == true ? "elevenlabs-direct" : DeliveryRecord.engineName(backend: facts?.engine ?? speech.backend, oneStep: entry.oneStep)
        let heard: DeliveryRecord.Heard = facts == nil ? .nothing
            : facts!.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .silence : .speech
        if !entry.attempted, let reason = DeliveryRecord.discardReason(results: entry.results, heard: heard, failure: failure) {
            // Nothing reached delivery: a short tap, Esc, silence, or a startup failure.
            DeliveryLog.shared.append(DeliveryRecord(time: Date(), engine: engine, speechMs: facts?.speechMillis,
                fallback: facts?.fallback, outcome: "discarded", reason: reason, costUSD: costUSD(facts)))
            // Cost was added when the provider work returned, before cancellation.
            return
        }
        let target = entry.target
        let outcome = DeliveryRecord.outcome(entry.results)
        var reason: String?
        if outcome != "pasted" {
            if let failure { reason = failure }
            else if entry.secure { reason = "secure input" }
            else if let target {
                reason = target.classification != Classification.normal ? "\(target.classification) app"
                    : !target.editable ? "no text field" : "paste not admitted"
            } else { reason = "no focused app" }
        }
        DeliveryLog.shared.append(DeliveryRecord(time: Date(), engine: engine,
            speechModel: facts?.engine == .cloud ? facts?.speechModel : facts.map { _ in "apple-speech" },
            speechMs: facts?.speechMillis, fallback: facts?.fallback, cleanupModel: facts?.cleanup?.model,
            cleanupMs: facts?.cleanup?.millis, cleanupNote: facts?.cleanup?.note, app: entry.app,
            classification: target.map { "\($0.classification)" }, editable: target?.editable,
            outcome: outcome, reason: reason, costUSD: costUSD(facts)))
    }
    // Charges provider work and counts delivery independently, once each.
    private func recordCost(speech: Double?, cleanup: Double?, count: Bool, spokenWords: Int = 0) -> Double? {
        let added = DeliveryRecord.addToDay(speech: speech, cleanup: cleanup, count: count,
            day: defaults.string(forKey: "costDay"), total: defaults.double(forKey: "costToday"),
            dictations: defaults.integer(forKey: "costCount"),
            words: defaults.integer(forKey: "spokenWordsToday"),
            allTimeWords: spokenWordsAllTime, spokenWords: spokenWords, now: Date())
        defaults.set(added.day, forKey: "costDay"); defaults.set(added.total, forKey: "costToday")
        defaults.set(added.dictations, forKey: "costCount")
        defaults.set(added.words, forKey: "spokenWordsToday")
        defaults.set(added.allTimeWords, forKey: "spokenWordsAllTime")
        return added.cost
    }
    // First launch after this counter ships: seed from today's already-counted words.
    private var spokenWordsAllTime: Int {
        if defaults.object(forKey: "spokenWordsAllTime") == nil {
            let seeded = defaults.integer(forKey: "spokenWordsToday")
            defaults.set(seeded, forKey: "spokenWordsAllTime")
            return seeded
        }
        return defaults.integer(forKey: "spokenWordsAllTime")
    }
    private var creditsCheckedAt: TimeInterval = -.infinity
    // At most once a minute, so a run of dictations doesn't add a request each time.
    private func refreshElevenLabsCredits() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - creditsCheckedAt >= 60 else { return }
        creditsCheckedAt = now
        Task { [weak self] in
            guard let key = await Task.detached(operation: { CloudCredentials.loadElevenLabs() }).value,
                  let credits = await ProviderBalance.elevenLabsCredits(key: key), let self else { return }
            usageStore.elevenLabsCredits = credits
            home.refreshCosts()
        }
    }
    private func usageFooter() -> (String?, String?) {
        let overview = usageStore.dailyOverview()
        let words = DeliveryRecord.wordsFooter(today: defaults.integer(forKey: "spokenWordsToday"),
                                               allTime: spokenWordsAllTime, day: defaults.string(forKey: "costDay"))
        let cost = overview.0
        let total: String?
        switch (cost, words) {
        case let (c?, w?): total = "\(c) · \(w)"
        case let (c?, nil): total = c
        case let (nil, w?): total = w
        case (nil, nil): total = nil
        }
        return (total, overview.1)
    }
    private func costUSD(_ facts: LocalSpeech.Facts?) -> Double? {
        let cost = (facts?.speechCost ?? 0) + (facts?.cleanup?.cost ?? 0)
        return cost > 0 ? cost : nil
    }
    nonisolated static func dayKey(_ date: Date) -> String {
        let format = DateFormatter(); format.dateFormat = "yyyy-MM-dd"; return format.string(from: date)
    }
    // Charges appear even before a dictation is delivered; omit an empty count.
    private var todaysCost: String? {
        DeliveryRecord.daySummary(day: defaults.string(forKey: "costDay"), total: defaults.double(forKey: "costToday"),
                                  words: defaults.integer(forKey: "spokenWordsToday"),
                                  allTimeWords: spokenWordsAllTime,
                                  unknown: defaults.string(forKey: "costModelsDay") == Self.dayKey(Date())
                                      && !(defaults.stringArray(forKey: "costModelsUnknown") ?? []).isEmpty)
    }
    private func updateUsageHistoryCosts() {
        var changed = false
        for index in history.indices {
            guard let line = usageStore.costLine(recordingID: history[index].usageRecordingID), history[index].costs != line else { continue }
            history[index].costs = line; changed = true
        }
        if changed { home.update(history: history,failed: AudioOutbox.shared.list()) }
        home.refreshCosts()
    }
    private func showAppPresets(selectedID: String? = nil) {
        let panel = presetWindow ?? FeatureWindow(title: "App writing presets")
        presetWindow = panel; panel.clear()
        panel.text("Settings are captured when you start dictation. Strict-app exclusions always win.")
        if let problem = appPresets.problem { panel.text(problem); panel.show(); return }
        let picker = NSPopUpButton(); let apps = InstalledApps.list()
        for app in apps { picker.addItem(withTitle: app.name); picker.lastItem?.representedObject = app.bundleID }
        for preset in appPresets.value where !apps.contains(where: { $0.bundleID == preset.bundleID }) {
            picker.addItem(withTitle: "Not installed: " + preset.bundleID); picker.lastItem?.representedObject = preset.bundleID
        }
        if let selectedID, let i = picker.itemArray.firstIndex(where: { $0.representedObject as? String == selectedID }) { picker.selectItem(at: i) }
        panel.stack.addArrangedSubview(picker)
        let id = picker.selectedItem?.representedObject as? String ?? ""
        let existing = appPresets.value.first { $0.bundleID == id }
        panel.button("Load selected app") { [weak self] in self?.showAppPresets(selectedID: picker.selectedItem?.representedObject as? String) }
        let engines: [RecoveryConfiguration.Engine?] = [nil,.local,.cloud,.oneStep,.elevenLabs]
        let engine = NSPopUpButton(); engine.addItems(withTitles: ["Inherit global engine","On-device","OpenRouter speech","Gemini one-step","ElevenLabs Scribe"])
        engine.selectItem(at: engines.firstIndex(where: { $0 == existing?.engine }) ?? 0)
        panel.text("Speech engine"); panel.stack.addArrangedSubview(engine)
        func models(_ title: String, ids: [String], selected: String?) -> NSPopUpButton {
            panel.text(title); let popup = NSPopUpButton(); popup.addItem(withTitle: "Inherit global model")
            var ids = ids; if let selected, !ids.contains(selected) { ids.append(selected) }
            for model in ids { popup.addItem(withTitle: ModelCosts.shortName(model)); popup.lastItem?.representedObject = model }
            if let selected, let i = popup.itemArray.firstIndex(where: { $0.representedObject as? String == selected }) { popup.selectItem(at: i) }
            panel.stack.addArrangedSubview(popup); return popup
        }
        let speechPicker = models("OpenRouter speech model",ids: home.speechModelIDs,selected: existing?.speechModel)
        let cleanupPicker = models("Cleanup model",ids: home.cleanupModels.map(\.id),selected: existing?.cleanupModel)
        let style = NSPopUpButton(); style.addItems(withTitles: ["Inherit global writing style"] + AppPreset.Style.allCases.map { $0.rawValue.capitalized })
        if let selected = existing?.style { style.selectItem(at: (AppPreset.Style.allCases.firstIndex(of: selected) ?? 0)+1) }
        panel.text("Writing style"); panel.stack.addArrangedSubview(style)
        let resolved = AppPreset.resolve(bundleID: id,presets: appPresets.value,global: globalRecordingConfiguration,strictApps: Set(strictBundleIDs),literalApps: AICleanup.literalApps)
        panel.text("Saved effective settings: \(resolved.configuration.engine.rawValue) · \(resolved.style.rawValue) · cleanup \(resolved.configuration.cleanupEnabled ? "on" : "off")")
        panel.button("Save loaded app preset") { [weak self] in
            guard let self, !id.isEmpty else { return }
            guard picker.selectedItem?.representedObject as? String == id else { panel.text("Load the selected app before saving."); return }
            let preset = AppPreset(bundleID: id,engine: engines[engine.indexOfSelectedItem],
                speechModel: speechPicker.selectedItem?.representedObject as? String,
                cleanupModel: cleanupPicker.selectedItem?.representedObject as? String,
                style: style.indexOfSelectedItem == 0 ? nil : AppPreset.Style.allCases[style.indexOfSelectedItem-1])
            appPresets.value.removeAll { $0.bundleID == id }; appPresets.value.append(preset)
            _ = appPresets.save(); showAppPresets(selectedID: id)
        }
        panel.button("Reset loaded app to global") { [weak self] in
            guard let self else { return }; appPresets.value.removeAll { $0.bundleID == id }; _ = appPresets.save(); showAppPresets(selectedID: id)
        }
        panel.show()
    }
    @objc private func openWritingTools() {
        guard !writingToolsOpening, !quitting else { return }
        writingToolsOpening = true
        if policy.isActive { policy.cancel(reason: "Writing tools opened"); pump() }
        stopHealthMicrophone()
        if writingTools == nil {
            writingTools = WritingToolsWindow(clipboard: clipboard,
                history: { [weak self] in self?.history ?? [] },
                dictionary: { [weak self] in self?.savedDictionary.terms ?? [] },
                model: { [weak self] in
                    guard let self, let chosen = defaults.string(forKey: "cleanupModel") ?? aiCleanup.order.first?.id,
                          home.cleanupModels.contains(where: { $0.id == chosen && !$0.trains }),
                          prices.models.contains(where: { $0.id == chosen && $0.outputsText }) else { return nil }
                    return chosen
                }, usage: usageStore, canRecord: { [weak self] in
                    guard let self else { return false }
                    return !quitting && !policy.isActive && clipTask == nil && healthAudio == nil && healthMicTask == nil
                }, snippets: snippets)
        }
        Task { [weak self] in
            guard let self else { return }
            defer { writingToolsOpening = false }
            await writingTools?.open()
            home.hide()
        }
    }
    @objc private func openUsageWindow() { rememberFrontApp(); showUsage() }
    @objc private func openInboxWindow() { rememberFrontApp(); showVocabularyInbox() }
    @objc private func openPresetsWindow() { rememberFrontApp(); showAppPresets() }
    @objc private func openHealthWindow() { rememberFrontApp(); showHealth() }
    private func healthSnapshot() -> HealthSnapshot {
        let at = Date()
        let fingerprint = SHA256.hash(data: Data(((speech.openRouterKey ?? "") + "\n" + (speech.elevenLabsKey ?? "")).utf8)).description
        if let previous = healthCredentialFingerprint, previous != fingerprint { healthChecks.invalidate() }
        healthCredentialFingerprint = fingerprint
        func permission(_ id: HealthCheckID,_ allowed: Bool,_ action: String) -> HealthRow {
            HealthRow(id: id,status: allowed ? .ready : .needsAttention,detail: allowed ? "Authorized" : action,checkedAt: at)
        }
        let local = speech.discovery.lowercased().contains("ready") && speech.backend == .apple
        let rows = [permission(.microphone,SystemChecks.microphone,"Open Microphone privacy settings"),
            permission(.speechPermission,SystemChecks.speech,"Open Speech Recognition privacy settings"),
            permission(.accessibility,SystemChecks.accessibility,"Open Accessibility settings"),
            permission(.inputMonitoring,SystemChecks.inputMonitoring,"Open Input Monitoring settings"),
            HealthRow(id: .eventTap,status: keys.active ? .ready : .needsAttention,detail: keys.active ? "Shortcut listener active" : "Review setup checklist and chosen shortcut",checkedAt: at),
            HealthRow(id: .localSpeech,status: local ? .ready : .unknown,detail: speech.discovery,checkedAt: at),
            HealthRow(id: .credential,status: speech.credentialReadPending ? .checking : speech.cloudCredentialReady ? .ready : .unknown,
                detail: speech.cloudCredentialReady ? "Selected provider credential available. Connection is checked separately." : "Select and connect a provider in Settings; no credential is inspected here.",checkedAt: at),
            healthChecks.row(.openRouter),healthChecks.row(.elevenLabs),
            healthChecks.row(.microphoneCapture),healthChecks.row(.transcription)]
        let revision = Bundle.main.object(forInfoDictionaryKey: "CursusSourceRevision") as? String ?? "unlabelled"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return HealthSnapshot(build: version + " · " + revision,engine: currentRecoveryConfiguration.engine,latestFailure: latestHealthFailure,rows: rows)
    }
    private func showHealth() {
        stopHealthMicrophone()
        let panel = healthWindow ?? FeatureWindow(title: "Health & diagnostics")
        healthWindow = panel; panel.clear(); panel.closed = { [weak self] in self?.stopHealthMicrophone() }
        let snapshot = healthSnapshot()
        panel.text("Selected global engine: \(snapshot.engine.rawValue). App presets may override it when recording starts.")
        for row in snapshot.rows {
            let title = row.id.title
            let label = panel.text("\(title) · \(row.status.rawValue)\n\(row.detail)\nChecked \(row.checkedAt.formatted(date: .omitted,time: .standard))")
            label.textColor = row.status == .needsAttention ? .systemOrange : .labelColor
        }
        if let failure = snapshot.latestFailure { panel.text("Latest failure: \(failure.rawValue). Retry from Activity or review setup.") }
        panel.button("Refresh local checks") { [weak self] in self?.showHealth() }
        panel.button("Check OpenRouter connection") { [weak self] in self?.checkHealthProvider(elevenLabs: false) }
        panel.button("Check ElevenLabs connection") { [weak self] in self?.checkHealthProvider(elevenLabs: true) }
        panel.button("Test microphone for five seconds") { [weak self] in self?.testHealthMicrophone() }
        panel.button("Copy diagnostics") { [weak self] in guard let self else { return }; _ = copyHistory(healthSnapshot().diagnostics) }
        panel.button("Open setup checklist") { [weak self] in panel.window.close(); self?.showOnboarding() }
        panel.show()
    }
    private func checkHealthProvider(elevenLabs: Bool) {
        let id: HealthCheckID = elevenLabs ? .elevenLabs : .openRouter
        let token = healthChecks.begin(id); showHealth()
        guard let key = elevenLabs ? speech.elevenLabsKey : speech.openRouterKey else {
            _ = healthChecks.complete(id,token: token,status: .unknown,detail: "No cached provider credential. Select and connect it in Settings first.")
            showHealth(); return
        }
        Task { [weak self] in
            let result = await ProviderBalance.check(elevenLabs: elevenLabs,key: key)
            guard let self, !quitting else { return }
            if result.status == .needsAttention { latestHealthFailure = .providerUnavailable }
            if healthChecks.complete(id,token: token,status: result.status,detail: result.detail), healthWindow?.window.isVisible == true { showHealth() }
        }
    }
    private func stopHealthMicrophone() {
        if let check = healthMicCheck {
            healthChecks.complete(.microphoneCapture, token: check, status: .unknown, detail: "Microphone test cancelled. Samples discarded.")
            healthMicCheck = nil
        }
        healthMicID = UUID(); healthMicTask?.cancel(); healthMicTask = nil
        healthAudio?.close(); healthAudio = nil
    }
    private func testHealthMicrophone() {
        guard !policy.isActive, healthMicTask == nil, let panel = healthWindow else { return }
        guard writingTools?.commandCaptureActive != true else {
            panel.text("Stop command recording in Writing tools before testing the microphone."); return
        }
        guard SystemChecks.microphone else { panel.text("Microphone is not authorized. Use the setup checklist."); return }
        let check = healthChecks.begin(.microphoneCapture)
        healthMicCheck = check
        let audio = NativeAudio(); let token = UUID(); healthMicID = token
        let meter = NSProgressIndicator(); meter.isIndeterminate = false; meter.minValue = 0; meter.maxValue = 1
        meter.style = .bar; meter.widthAnchor.constraint(equalToConstant: 400).isActive = true
        meter.setAccessibilityLabel("Microphone input level"); panel.stack.insertArrangedSubview(meter,at: 0)
        let note = panel.text("Microphone test running. Samples stay in memory and are discarded.")
        do { try audio.prepare(); try audio.start() }
        catch {
            audio.close(); latestHealthFailure = .microphoneUnavailable
            healthChecks.complete(.microphoneCapture, token: check, status: .needsAttention, detail: "Microphone could not start. Review setup.")
            healthMicCheck = nil
            note.stringValue = "Microphone could not start. Review setup."; return
        }
        healthAudio = audio
        healthMicTask = Task { @MainActor [weak self] in
            defer {
                audio.close()
                if self?.healthMicID == token { self?.healthAudio = nil; self?.healthMicTask = nil; self?.healthMicCheck = nil }
            }
            for _ in 0..<100 {
                guard !Task.isCancelled, self?.policy.isActive == false else { return }
                meter.doubleValue = min(1,Double(audio.level)*4)
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled, self?.healthMicID == token, self?.policy.isActive == false else { return }
            do {
                let batch = try audio.finish()
                let captured = batch.frames > 0
                self?.healthChecks.complete(.microphoneCapture, token: check, status: captured ? .ready : .needsAttention,
                    detail: captured ? "Microphone produced samples; samples were discarded. No transcription was requested." : "No microphone samples arrived. Review the input device.")
                note.stringValue = captured ? "Microphone captured samples. Samples discarded; transcription not tested." : "No microphone samples arrived."
            } catch {
                self?.healthChecks.complete(.microphoneCapture, token: check, status: .needsAttention, detail: "Microphone capture failed. Review the input device.")
                note.stringValue = "Microphone capture failed. Samples discarded."
            }
            meter.doubleValue = 0
        }
    }
    private func showUsage() {
        let panel = usageWindow ?? FeatureWindow(title: "Usage & budget")
        usageWindow = panel; panel.clear(); panel.text(usageStore.summary())
        panel.text("Monthly USD warning budget. Leave blank to disable. This never blocks dictation.")
        let amount = NSTextField(string: defaults.object(forKey: "monthlyBudgetUSD") == nil ? "" : String(defaults.double(forKey: "monthlyBudgetUSD")))
        amount.setAccessibilityLabel("Monthly USD warning budget"); panel.stack.addArrangedSubview(amount)
        panel.button("Save budget") { [weak self] in
            guard let self else { return }
            let value = amount.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { defaults.removeObject(forKey: "monthlyBudgetUSD") }
            else if let number = Double(value), number.isFinite, number > 0 { defaults.set(number, forKey: "monthlyBudgetUSD") }
            else { panel.text("Enter a positive USD amount or leave blank."); return }
            checkBudget(); showUsage()
        }
        panel.button("Refresh OpenRouter key cap") {
            Task {
                guard let key = CloudCredentials.load() else { panel.text("OpenRouter credential unavailable"); return }
                panel.text(await ProviderBalance.refresh(elevenLabs: false, key: key))
            }
        }
        panel.button("Refresh ElevenLabs allowance") {
            Task {
                guard let key = CloudCredentials.loadElevenLabs() else { panel.text("ElevenLabs credential unavailable"); return }
                panel.text(await ProviderBalance.refresh(elevenLabs: true, key: key))
            }
        }
        panel.button("Refresh usage") { [weak self] in self?.showUsage() }
        panel.show()
    }
    private func checkBudget() {
        guard let month = Calendar.current.dateInterval(of: .month, for: Date()) else { return }
        let total = usageStore.ledger.totals(in: month).reported
        guard let threshold = UsageLedger.budgetThreshold(total: total, budget: defaults.object(forKey: "monthlyBudgetUSD") as? Double) else { return }
        let parts = Calendar.current.dateComponents([.year,.month],from: Date())
        let monthKey = "\(parts.year ?? 0)-\(parts.month ?? 0)"
        let key = "budgetWarned-\(monthKey)-\(threshold)"
        guard !policy.isActive, !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        if threshold == 100 { defaults.set(true, forKey: "budgetWarned-\(monthKey)-80") }
        if !policy.isActive { pill.show(.done("Monthly budget \(threshold)% reached · dictation continues"), now: ProcessInfo.processInfo.systemUptime) }
    }
    private var shortcutSummary: String {
        let key = policy.binding == .fn ? "Fn" : "Ctrl+Option"
        if keys.active && policy.listener.selected { return "Hold \(key) to dictate" }
        return shortcutFailure ?? "Shortcuts need setup"
    }
    private func refreshHome() {
        checkBudget()
        home.update(history: history, failed: AudioOutbox.shared.list())
        home.refreshCosts()
        home.status.stringValue = "\(shortcutSummary). \(speech.discovery)."
        let engine = speech.backend == .apple ? (speech.cloudCleanupOnDevice ? "On-device" : "On-device only")
            : speech.oneStep ? "Gemini one-step" : "Grok"
        let cleanup = defaults.bool(forKey: "aiCleanup") && (speech.backend == .cloud || speech.cloudCleanupOnDevice) && !speech.oneStep ? " + cleanup" : ""
        home.headline.toolTip = "Selected: " + engine + cleanup + (cleanupContext().style == .smart ? " · Smart" : " · Strict")
        home.headline.setAccessibilityHelp(home.headline.toolTip)
        home.setStatus(!keys.active ? "Needs setup" : grokLocked ? "On-device fallback" : cleanupKeyLocked ? "Cleanup off" : "Ready",
                       ok: keys.active && !grokLocked && !cleanupKeyLocked)
        home.setWarning(grokLocked ? "Grok is off: Mercurius can't read its key, so it's using on-device speech with no cleanup."
            : cleanupKeyLocked ? "AI cleanup is off: Mercurius can't read its key. Allow Keychain access to turn it back on." : nil)
        home.setCounts(words: savedDictionary.terms.count, phrases: takeBackPhrases.count)
        home.loadClipboard()
    }
    // Grok chosen but its key can't be read (new build not yet allowed in Keychain, or no key).
    private var grokLocked: Bool {
        speech.backend == .cloud && keyUnreadable
    }
    // On-device + AI cleanup chosen but its key can't be read: speech works, cleanup doesn't.
    private var cleanupKeyLocked: Bool {
        speech.backend == .apple && speech.cloudCleanupOnDevice && defaults.bool(forKey: "aiCleanup") && keyUnreadable
    }
    private var keyUnreadable: Bool {
        !speech.cloudCredentialReady && (!speech.credentialReadPending || speech.credentialUnresponsiveNow)
    }
    private func watch(_ center: NotificationCenter, _ name: Notification.Name, _ reason: String) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.quitting else { return }
                self.invalidateDelivery()
                self.pill?.hide()
                self.writingTools?.interrupt(reason: reason)
                CaptureExecution.interrupt(self.clipTask, permit: self.clipPermit)
                self.stopHealthMicrophone()
                self.policy.send(.interrupted(reason)); self.pump()
            }
        }
        tokens.append((center, token))
    }
    private func installNotifications() {
        let workspace = NSWorkspace.shared.notificationCenter
        watch(workspace, NSWorkspace.willSleepNotification, "Sleep cancelled session")
        watch(workspace, NSWorkspace.sessionDidResignActiveNotification, "Session resign cancelled session")
        watch(workspace, NSWorkspace.screensDidSleepNotification, "Screen sleep cancelled session")
        watch(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"), "Screen lock cancelled session")
        watch(.default, AVCaptureDevice.wasDisconnectedNotification, "Microphone disconnected")
        let token = workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleObservation() }
        }
        tokens.append((workspace, token))
        // The pill can drop out of WindowServer across these while AppKit still calls it visible.
        let reattach: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.didWakeNotification), (workspace, NSWorkspace.screensDidWakeNotification),
            (workspace, NSWorkspace.activeSpaceDidChangeNotification), (.default, NSApplication.didChangeScreenParametersNotification)]
        for (center, name) in reattach {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pill?.reattach() }
            }
            tokens.append((center, token))
        }
    }
    // Retry processes text normally; delivery requires another explicit action. One retry at a time.
    private var globalRecordingConfiguration: RecoveryConfiguration {
        let local = defaults.string(forKey: "speechBackend") == "apple"
        let scribe = !local && defaults.bool(forKey: "elevenLabsDirect")
        return RecoveryConfiguration(engine: local ? .local : scribe ? .elevenLabs : defaults.bool(forKey: "oneStepSpeech") ? .oneStep : .cloud,
            speechModel: scribe ? ScribeSpeech.id(ScribeSpeech.model(defaults.string(forKey: "scribeModel"))) : defaults.string(forKey: "speechModel") ?? CloudSpeech.model,
            cleanupModel: defaults.string(forKey: "cleanupModel") ?? AICleanup.catalog[0].id,
            cleanupEnabled: defaults.bool(forKey: "aiCleanup") && (!local || defaults.bool(forKey: "onDeviceCleanup")),
            smart: defaults.string(forKey: "cleanupStyle") != "strict")
    }
    private var currentRecoveryConfiguration: RecoveryConfiguration { globalRecordingConfiguration }
    private func retryRecording(_ saved: AudioOutbox.Item, useCurrent: Bool = false) {
        guard retryTask == nil, !policy.isActive else { return }
        var item = saved
        // Resolved here rather than left nil: LocalSpeech.retry has its own fallback to the current
        // engine, so an unknown configuration must not reach it. See RecoveryConfiguration.retryConfiguration.
        item.configuration = RecoveryConfiguration.retryConfiguration(stored: saved.configuration,
                                                                      current: currentRecoveryConfiguration,
                                                                      useCurrent: useCurrent)
        let config = item.configuration ?? currentRecoveryConfiguration
        let startedAt = policy.generation
        let group = UUID(), vocab = vocabulary
        retryID += 1; let id = retryID
        pill.show(.transcribing, now: ProcessInfo.processInfo.systemUptime)
        retryTask = Task { [weak self] in
            guard let self else { return }
            defer { if retryID == id { retryTask = nil } }
            let result = await speech.retry(item, oneStep: config.engine == .oneStep, recordingID: group, vocabulary: vocab)
            guard let result, !Task.isCancelled, !quitting else {
                if !policy.isActive { pill.show(.failed(AudioOutbox.shared.problem ?? "Retry failed; recording remains available until expiry"), now: ProcessInfo.processInfo.systemUptime) }
                refreshHome(); return
            }
            let heard = result.text
            guard !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, heard.utf8.count <= Policy.textLimit else { refreshHome(); return }
            var context = cleanupContext(); context.recordingID = group; context.savedConfiguration = config
            context.style = config.smart ? .smart : .strict; context.oneStep = config.engine == .oneStep
            context.writingStyle = config.writingStyle.flatMap(AppPreset.Style.init(rawValue:))
            context.vocabulary = vocab
            let cleaned = await speech.cleanup?(heard, 4, false, context)
                ?? CleanupOutcome(text: TranscriptCleanup.rules(heard, vocabulary: vocab), model: nil, millis: 0, note: "rules")
            guard !Task.isCancelled, !quitting else { return }
            let text = cleaned.text; let at = Date()
            if Self.handleEmptyRetry(text, failure: { pill.show(.failed($0), now: ProcessInfo.processInfo.systemUptime) }, refresh: { refreshHome() }) { return }
            guard text.utf8.count <= Policy.textLimit else {
                pill.show(.failed("Retry result exceeded the text limit. The recording remains available until expiry."), now: ProcessInfo.processInfo.systemUptime); refreshHome(); return
            }
            guard Date().timeIntervalSince(item.at) < AudioOutbox.lifetime else { refreshHome(); return }
            AudioOutbox.shared.discard(saved)
            let healthToken = healthChecks.begin(.transcription)
            healthChecks.complete(.transcription, token: healthToken, status: .ready,
                detail: "A recent explicit retry produced text. This does not test the current selection or confirm delivery.")
            let recoveredEntry = HistoryEntry(text: text, at: at, raw: text == heard ? nil : heard, detail: speech.retryUsedScribeBackup ? "Recovered by ElevenLabs Scribe (standard retention) · choose Copy or Paste" : "Recovered · choose Copy or Paste",
                usageRecordingID: group, costs: usageStore.costLine(recordingID: group), corrections: vocab.appliedCorrections(in: heard),
                smart: config.smart)
            history.append(recoveredEntry)
            clipboard.add(dictation: text, at: at)
            refreshHome()
            guard !policy.isActive, policy.generation == startedAt else { return }
            home.hide()
            let panel = recoveryWindow ?? FeatureWindow(title: "Recovered recording")
            recoveryWindow = panel; panel.clear(); panel.text(text)
            panel.text("Nothing has been copied or pasted. Choose an app before Paste; the focused field is checked again.")
            let destinations = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
            let picker = NSPopUpButton()
            picker.addItem(withTitle: "Choose a destination app…")
            for app in destinations { picker.addItem(withTitle: app.localizedName ?? "Application") }
            picker.setAccessibilityLabel("Recovered text paste destination")
            panel.stack.addArrangedSubview(picker)
            let token = UUID(); recoveryWindowToken = token
            @MainActor func deliver(_ paste: Bool) {
                let selected = picker.indexOfSelectedItem - 1
                guard !paste || destinations.indices.contains(selected) else {
                    panel.text("Choose a destination app, or use Copy."); return
                }
                let app = paste ? destinations[selected] : nil
                let launch = app?.launchDate
                guard Date().timeIntervalSince(at) < Policy.recoveryLifetime else { panel.clear(); return }
                panel.window.close()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let app, !app.isTerminated, app.launchDate == launch {
                        app.activate()
                        for _ in 0..<50 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                            try? await Task.sleep(for: .milliseconds(20))
                            guard !Task.isCancelled else { return }
                        }
                    }
                    let context = await destination.snapshot()
                    guard !quitting, !Task.isCancelled, deliveryTask == nil, pendingDeliveries.isEmpty else { return }
                    guard let index = Self.recoveryEntryIndex(history, id: recoveredEntry.id, text: text) else {
                        pill.show(.failed("Transcript changed or expired. Use Activity to choose the current text."), now: ProcessInfo.processInfo.systemUptime); return
                    }
                    guard policy.offerRecovery(text, expectedGeneration: startedAt, age: Date().timeIntervalSince(at)) else { return }
                    historyGeneration = policy.generation
                    bindHistoryDelivery(index, generation: policy.generation)
                    history[index].outcomes = [.recognized]
                    if let app {
                        guard !context.secure, let target = context.destination, target.qualified,
                              target.process == "\(app.processIdentifier):\(launch?.timeIntervalSince1970 ?? -1)",
                              !app.isTerminated, app.launchDate == launch else {
                            policy.refuseRecovery(expectedGeneration: policy.generation, context: context)
                            pump(); refreshHome()
                            pill.show(.failed("Paste destination unavailable. Text remains in Activity."), now: ProcessInfo.processInfo.systemUptime); return
                        }
                        if target.route == .qualifiedClipboard {
                            await destination.armRestoreForNextCopy()
                            guard policy.request(.copy, context: context) != nil else {
                                await destination.disarmRestoreForNextCopy(); return
                            }
                            requestedPasteDestination = target; pasteAfterCopy = true
                        } else { _ = policy.request(.paste, context: context, expectedDestination: target) }
                    } else { _ = policy.request(.copy, context: context) }
                    pump()
                }
            }
            panel.button("Copy") { deliver(false) }
            panel.button("Paste into selected app") { deliver(true) }
            panel.show()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Policy.recoveryLifetime))
                guard self?.recoveryWindowToken == token else { return }
                self?.recoveryWindow?.clear(); self?.recoveryWindow?.window.close()
            }
        }
    }
    static func handleEmptyRetry(_ text: String?, failure: (String) -> Void, refresh: () -> Void) -> Bool {
        let message: String
        if let text {
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            message = "No speech was heard. Try recording again"
        } else { message = "Retry failed. Check the network and try again" }
        failure(message)
        refresh()
        return true
    }
    static func recoveryEntryIndex(_ history: [HistoryEntry], id: UUID, text: String) -> Int? {
        history.firstIndex { $0.id == id && $0.text == text }
    }
    private func bindHistoryDelivery(_ index: Int, generation: UInt64) {
        if let original = history[index].wordCountGeneration {
            wordCounter.bindDelivery(generation, to: original)
        } else {
            history[index].wordCountGeneration = generation
            wordCounter.recognized(generation, raw: history[index].raw ?? history[index].text,
                at: ProcessInfo.processInfo.systemUptime - Date().timeIntervalSince(history[index].at))
        }
        history[index].generation = generation
    }
    private func copyHistoryEntry(_ entry: HistoryEntry) {
        guard !policy.isActive, deliveryTask == nil, pendingDeliveries.isEmpty else {
            pill.show(.failed("Finish the current recording or delivery before copying another transcript."), now: ProcessInfo.processInfo.systemUptime); return
        }
        let controller = policy.generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            let context = await destination.snapshot()
            guard !quitting, !Task.isCancelled, deliveryTask == nil, pendingDeliveries.isEmpty,
                  let index = history.firstIndex(where: { $0.id == entry.id }), history[index].text == entry.text,
                  policy.offerRecovery(entry.text, expectedGeneration: controller, age: Date().timeIntervalSince(entry.at)) else { return }
            historyGeneration = policy.generation
            bindHistoryDelivery(index, generation: policy.generation)
            historyOutcomes[policy.generation] = history[index].outcomes
            if policy.request(.copy, context: context) == nil { pill.show(.failed(policy.message), now: ProcessInfo.processInfo.systemUptime) }
            pump(); refreshHome()
        }
    }
    private func showHistoryEntry(_ entry: HistoryEntry) {
        let remaining = Policy.recoveryLifetime - Date().timeIntervalSince(entry.at)
        guard remaining > 0, remaining <= Policy.recoveryLifetime else { return }
        let panel = transcriptDetailWindow ?? FeatureWindow(title: "Dictation details")
        transcriptDetailWindow = panel; transcriptDetailID = entry.id; panel.clear()
        transcriptDetailStatus = panel.text(entry.outcomes.isEmpty ? entry.deliveryStatus : entry.outcomes.map(\.label).joined(separator: "\n"))
        panel.text(entry.raw == nil ? "Transcript" : "Cleaned transcript"); panel.text(entry.text)
        if let raw = entry.raw { panel.text("Original transcript"); panel.text(raw) }
        if let costs = entry.costs { panel.text("Reported usage · " + costs) }
        panel.text("Text expires ten minutes after recognition and when Mercurius quits.")
        panel.button("Copy") { [weak self] in self?.copyHistoryEntry(entry) }
        panel.button("Re-clean") { [weak self] in panel.window.close(); self?.rerunEntryCleanup(entry) }
        panel.closed = { [weak self, weak panel] in
            panel?.clear(); self?.transcriptDetailID = nil; self?.transcriptDetailStatus = nil
        }
        let token = UUID(); transcriptDetailToken = token
        panel.show()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard self?.transcriptDetailToken == token else { return }
            self?.transcriptDetailWindow?.clear(); self?.transcriptDetailWindow?.window.close()
        }
    }
    private func rerunEntryCleanup(_ entry: HistoryEntry) {
        guard history.contains(where: { $0.id == entry.id }), Date().timeIntervalSince(entry.at) >= 0,
              Date().timeIntervalSince(entry.at) < Policy.recoveryLifetime else { return }
        guard let key = speech.openRouterKey else {
            pill.show(.failed("Connect OpenRouter in Settings to run AI cleanup"), now: ProcessInfo.processInfo.systemUptime)
            return
        }
        let source = entry.raw ?? entry.text
        // The app it was dictated into decides, not whichever app is in front now.
        let smart = entry.smart ?? aiCleanup.smart
        guard !(smart ? TranscriptCleanup.isTechnical(source) : TranscriptCleanup.isCodeShaped(source)) else {
            pill.show(.failed("Left as spoken: this looks like code, so it isn't sent for cleanup."), now: ProcessInfo.processInfo.systemUptime)
            return
        }
        let vocab = vocabulary
        let rules = TranscriptCleanup.rules(source, vocabulary: vocab)
        var context = cleanupContext(); context.usageOperation = .reClean; context.recordingID = UUID()
        let token = UUID(); reCleanTokens[entry.id] = token
        Task { [weak self] in
            guard let self else { return }
            let outcome = await aiCleanup.clean(rules, rules: rules, context: context, vocabulary: vocab,
                                                key: key, budget: 4.0, smart: smart)
            addModelSpend(outcome.charges)
            _ = recordCost(speech: nil, cleanup: outcome.cost, count: false)
            guard reCleanTokens[entry.id] == token else { return }
            reCleanTokens.removeValue(forKey: entry.id)
            let modelShort = outcome.model.map(ModelCosts.shortName) ?? "rules (\(outcome.note ?? "unchanged"))"
            let updated = HistoryEntry(
                text: outcome.text,
                at: entry.at,
                raw: outcome.text == source ? nil : source,
                detail: "Re-cleaned (\(modelShort) · \(String(format: "%.1f s", Double(outcome.millis) / 1000)))",
                usageRecordingID: context.recordingID, costs: usageStore.costLine(recordingID: context.recordingID), corrections: vocab.appliedCorrections(in: source), wordCountGeneration: entry.wordCountGeneration, id: entry.id
            )
            guard let index = history.firstIndex(where: { $0.id == entry.id }), Date().timeIntervalSince(entry.at) < Policy.recoveryLifetime else { refreshHome(); return }
            history[index].applyReclean(updated)
            if transcriptDetailID == entry.id { transcriptDetailWindow?.window.close() }
            refreshHome()
            pill.show(.done("Re-cleaned · choose Copy in Activity"), now: ProcessInfo.processInfo.systemUptime)
        }
    }
    // A fix the user made after a paste joins the dictionary. It can be removed in
    // the Dictionary tab like any other word.
    private func learn(_ fix: CorrectionLearner.Correction) {
        vocabularyInbox.value.suggest(term: fix.correct, from: fix.addsReplacement ? fix.heard : nil, source: .correction)
        // Your own fix applies now; a slip of the keyboard waits in the inbox.
        let slip = CorrectionLearner.isKeyboardSlip(heard: fix.heard, correct: fix.correct, isCommonWord: CorrectionWatch.isCommonWord)
        let adopted = !slip && CorrectionLearner.isSafeToAdopt(fix.correct)
            && adopt(term: fix.correct, from: fix.addsReplacement ? fix.heard : nil, approval: .hintAndReplacement)
        _ = vocabularyInbox.save()
        if !policy.isActive {
            pill.show(.done(adopted ? "Added \(fix.correct) to your dictionary" : "Correction suggested · review Vocabulary Inbox"), now: ProcessInfo.processInfo.systemUptime)
        }
    }
    // Moves a waiting suggestion into the dictionary. Undo stays in the Vocabulary inbox.
    // `from` picks the exact suggestion, so an older one for the same word never goes live in its place.
    private func adopt(term: String, from: String?, approval: VocabularyInbox.Approval) -> Bool {
        guard let suggestion = vocabularyInbox.value.pending.first(where: { $0.term == term && $0.from == from }) else { return false }
        let saved = savedDictionary
        let wasHintOnly = (defaults.stringArray(forKey: "recognitionOnlyTerms") ?? []).contains(term.lowercased())
        guard let next = vocabularyInbox.value.accept(suggestion.id, terms: saved.terms, replacements: saved.replacements,
                                                      revision: defaults.integer(forKey: "dictionaryRevision") + 1,
                                                      approval: approval, wasRecognitionOnly: wasHintOnly) else { return false }
        if approval == .hintAndReplacement {
            var hints = Set(defaults.stringArray(forKey: "recognitionOnlyTerms") ?? [])
            hints.remove(term.lowercased())
            defaults.set(Array(hints).sorted(), forKey: "recognitionOnlyTerms")
        }
        saveDictionary(next)
        return true
    }
    private func markDictionaryModeChanged(_ term: String) {
        var versions = defaults.dictionary(forKey: "dictionaryEntryVersions") as? [String:Int] ?? [:]
        versions["term:" + term.lowercased()] = defaults.integer(forKey: "dictionaryRevision")
        defaults.set(versions, forKey: "dictionaryEntryVersions")
    }
    private func showVocabularyInbox() {
        defaults.set(true,forKey: "seenVocabularyInboxNotice")
        home.approvalFirstNotice = false
        vocabularyInbox.value.purge(); _ = vocabularyInbox.save()
        let panel = inboxWindow ?? FeatureWindow(title: "Vocabulary inbox")
        inboxWindow = panel; panel.clear()
        panel.text("Recognition hints help engines spell names. Replacements change matching words after recognition. Your own name fixes and new words you say often are added automatically; undo them here. Anything that looks like a slip or a mishearing waits below for you to approve.")
        if let problem = vocabularyInbox.problem { panel.text(problem); panel.show(); return }
        if vocabularyInbox.value.pending.isEmpty { panel.text("No suggestions waiting.") }
        for suggestion in vocabularyInbox.value.pending {
            panel.text("\(suggestion.from.map { $0 + " → " } ?? "")\(suggestion.term) · \(suggestion.source.rawValue) · \(suggestion.count) occurrences")
            let edit = NSTextField(string: suggestion.term); edit.setAccessibilityLabel("Suggested dictionary spelling")
            panel.stack.addArrangedSubview(edit)
            let choices: [(String, VocabularyInbox.Approval)] = suggestion.from == nil
                ? [("Add recognition hint", .hintOnly)]
                : [("Add recognition hint only", .hintOnly), ("Add hint and replacement", .hintAndReplacement)]
            for (title, approval) in choices {
            panel.button(title) { [weak self] in
                guard let self else { return }
                let saved = savedDictionary
                let term = edit.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let wasHintOnly = (defaults.stringArray(forKey: "recognitionOnlyTerms") ?? []).contains(term.lowercased())
                guard let next = vocabularyInbox.value.accept(suggestion.id,editedTerm: edit.stringValue,terms: saved.terms,replacements: saved.replacements, revision: defaults.integer(forKey: "dictionaryRevision")+1, approval: approval, wasRecognitionOnly: wasHintOnly) else {
                    panel.text("Cannot accept: dictionary is full, spelling is invalid, or a saved correction conflicts."); return
                }
                var hints = Set(defaults.stringArray(forKey: "recognitionOnlyTerms") ?? [])
                if approval == .hintOnly, !saved.terms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
                    hints.insert(term.lowercased())
                } else if approval == .hintAndReplacement { hints.remove(term.lowercased()) }
                defaults.set(Array(hints).sorted(), forKey: "recognitionOnlyTerms")
                saveDictionary(next)
                if hints.contains(term.lowercased()) != wasHintOnly { markDictionaryModeChanged(term) }
                _ = vocabularyInbox.save(); showVocabularyInbox()
            }
            }
            panel.button("Ignore") { [weak self] in
                guard let self else { return }; vocabularyInbox.value.ignore(suggestion.id); _ = vocabularyInbox.save(); showVocabularyInbox()
            }
        }
        for change in vocabularyInbox.value.accepted.reversed() {
            panel.button("Undo accepted \(change.term)") { [weak self] in
                guard let self else { return }; let saved = savedDictionary
                let versions = defaults.dictionary(forKey: "dictionaryEntryVersions") as? [String:Int] ?? [:]
                let keys = ["term:"+change.term.lowercased()] + (change.from.map { ["rule:"+$0.lowercased()] } ?? [])
                guard keys.allSatisfy({ (versions[$0] ?? 0) <= change.revision }),
                      let next = vocabularyInbox.value.undo(change.id,terms: saved.terms,replacements: saved.replacements, revision: change.revision, recognitionOnly: (defaults.stringArray(forKey: "recognitionOnlyTerms") ?? []).contains(change.term.lowercased())) else {
                    panel.text("This correction has since been edited. Undo left it unchanged."); return
                }
                if let before = change.recognitionOnlyBefore {
                    var hints = Set(defaults.stringArray(forKey: "recognitionOnlyTerms") ?? [])
                    if before { hints.insert(change.term.lowercased()) } else { hints.remove(change.term.lowercased()) }
                    defaults.set(Array(hints).sorted(), forKey: "recognitionOnlyTerms")
                }
                saveDictionary(next)
                if change.recognitionOnlyBefore != change.recognitionOnlyAfter { markDictionaryModeChanged(change.term) }
                _ = vocabularyInbox.save(); showVocabularyInbox()
            }
        }
        for suggestion in vocabularyInbox.value.ignored {
            panel.button("Restore ignored \(suggestion.term)") { [weak self] in
                guard let self else { return }
                guard vocabularyInbox.value.restore(suggestion.id) else {
                    panel.text("Suggestion inbox is full. Review pending suggestions before restoring this one."); return
                }
                _ = vocabularyInbox.save(); showVocabularyInbox()
            }
        }
        panel.show()
    }
    @objc private func changeTakeBacks() {
        defaults.set(home.dropTakeBacks.state == .on, forKey: "dropTakeBacks"); refreshHome()
    }
    @objc private func changeCleanupStyle() {
        aiCleanup.smart = home.cleanupStyle.indexOfSelectedItem == 0
        defaults.set(aiCleanup.smart ? "smart" : "strict", forKey: "cleanupStyle")
        home.refreshPrices(); refreshHome()
    }
    @objc private func changeCleanupModel() {
        let id = home.cleanupModel.selectedItem?.representedObject as? String
        defaults.set(id, forKey: "cleanupModel")
        aiCleanup.order = AICleanup.order(choosing: id, from: home.cleanupModels)
        home.refreshPrices()
    }
    @objc private func changeScribeModel() {
        let model = ScribeSpeech.model(home.scribeModel.selectedItem?.representedObject as? String)
        defaults.set(model, forKey: "scribeModel")
        speech.scribeModel = model
        home.refreshPrices(); refresh()
    }
    @objc private func changeSpeechModel() {
        let id = home.speechModel.selectedItem?.representedObject as? String ?? CloudSpeech.model
        defaults.set(id, forKey: "speechModel")
        speech.transcriptionModel = id
        home.refreshPrices()
    }
    @objc private func changeOpenAtLogin() {
        defaults.set(home.opensAtLogin.state == .on, forKey: "openAtLogin")
        applyOpenAtLogin(userAsked: true)
    }
    // A dictation app that is gone after a restart looks broken: the Mini's copy quit on logout
    // on 2026-11-12 and nothing brought it back. On by default; the Settings switch turns it off.
    // `userAsked`: the Settings switch was just flipped. At launch, a login item someone turned off
    // in System Settings (requiresApproval) is left alone; only the switch sends them there.
    private func applyOpenAtLogin(userAsked: Bool = false) {
        let item = SMAppService.mainApp
        switch (defaults.bool(forKey: "openAtLogin"), item.status) {
        case (true, .notRegistered), (true, .notFound):
            do { try item.register() }
            catch { Self.clipLog.error("open at login failed: \(error.localizedDescription, privacy: .public)") }
        case (true, .requiresApproval) where userAsked:
            SMAppService.openSystemSettingsLoginItems()
        case (false, .enabled), (false, .requiresApproval):
            do { try item.unregister() }
            catch { Self.clipLog.error("open at login removal failed: \(error.localizedDescription, privacy: .public)") }
        default: break
        }
        // The switch shows what macOS will actually do, not only what was asked.
        home.opensAtLogin.state = item.status == .enabled ? .on : .off
    }
    @objc private func changeCloseOnOutsideClick() {
        defaults.set(home.closesOnOutsideClick.state == .on, forKey: "panelClosesOnOutsideClick")
        home.applyCloseBehavior()
    }
    @objc private func changeScreenText() { defaults.set(home.screenText.state == .on, forKey: "screenTextEnabled") }
    @objc private func changeCopyAfterCapture() { defaults.set(home.copyAfterCapture.state == .on, forKey: "copyAfterCapture") }
    @objc private func changePillStyle() {
        defaults.set(PillStyle.Theme.allCases[max(0, home.pillTheme.indexOfSelectedItem)].rawValue, forKey: "pillTheme")
        defaults.set(PillStyle.Motion.allCases[max(0, home.pillMotion.indexOfSelectedItem)].rawValue, forKey: "pillMotion")
        pill.applyAppearance()
    }
    @objc private func changeLivePreview() {
        defaults.set(home.livePreview.state == .on, forKey: "livePreview")
        speech.previewEnabled = home.livePreview.state == .on
    }
    @objc private func changeAutoAdd() {
        defaults.set(home.autoAddNames.state == .on, forKey: "autoAddNames")
        if home.autoAddNames.state == .on { addNamesSaidOften() }
    }
    // Names said 3 times today join the dictionary as terms (no replacement). One added this
    // way, or any word the user removed (saveDictionary), is never added again.
    private func addNamesSaidOften() {
        guard defaults.bool(forKey: "autoAddNames") else { return }
        let skip = Set(defaults.stringArray(forKey: "removedNames") ?? [])
        let suggestions = RepeatedTerms.suggest(names: namesSeen.map(\.words),existing: vocabulary,isCommonWord: CorrectionWatch.isCommonWord)
        for suggestion in suggestions where suggestion.count >= 3 && !skip.contains(suggestion.term.lowercased()) {
            vocabularyInbox.value.suggest(term: suggestion.term,from: nil,source: .repeated,count: suggestion.count)
            // A new word said often joins by itself; one close to a saved word is probably a mishearing, so it waits.
            // The spell check is English, so in another language an ordinary word would look like a name.
            let english = SpeechLanguageStore.choice.active.map { $0.lowercased().hasPrefix("en") } ?? true
            if english, CorrectionLearner.isNewWord(suggestion.term, existing: savedDictionary.terms + vocabulary.terms) {
                _ = adopt(term: suggestion.term, from: nil, approval: .hintAndReplacement)
            }
        }
        _ = vocabularyInbox.save()
    }
    @objc private func changeLearn() {
        defaults.set(home.learnCorrections.state == .on, forKey: "learnCorrections")
        if home.learnCorrections.state == .off { correctionWatch.stop() }
    }
    private func pillClicked() {
        if policy.isActive && policy.state != .finalizing && policy.state != .delivering { stop() }
        else if let offer = pill.content,
                offer.allowsRecoveryCopy(recoveryGeneration: policy.recovery?.generation, controllerGeneration: policy.generation) {
            copyRecovery(offered: offer)
            openPanel(.clipboard)
            pill.hide()
        } else { pill.hide() }
    }
    @objc private func stop() { policy.stop(); pump() }
    @objc private func copyLast() { copyRecovery() }
    private func copyRecovery(offered: PillContent? = nil) {
        guard offered.map({ $0.allowsRecoveryCopy(recoveryGeneration: policy.recovery?.generation,
                                                controllerGeneration: policy.generation) }) ?? true else { return }
        guard deliveryTask == nil && pendingDeliveries.isEmpty, menuRequest.reserve() else { return }
        // A plain copy never takes a restore snapshot.
        Task { [weak self, destination] in
            await destination.disarmRestoreForNextCopy()
            guard let self else { return }
            defer { menuRequest.release() }
            guard !quitting, deliveryTask == nil, pendingDeliveries.isEmpty,
                  offered.map({ $0.allowsRecoveryCopy(recoveryGeneration: policy.recovery?.generation,
                                                     controllerGeneration: policy.generation) }) ?? true else { return }
            _ = policy.request(.copy, context: currentContext()); pump()
        }
    }
    // Copies, then pastes into the field focused now (the menu does not take focus).
    @objc private func pasteLast() {
        guard deliveryTask == nil && pendingDeliveries.isEmpty, policy.recovery != nil,
              menuRequest.reserve() else { return }
        let target = currentContext().destination
        Task { [weak self, destination] in
            await destination.armRestoreForNextCopy()
            guard let self else { return }
            defer { menuRequest.release() }
            guard !quitting, deliveryTask == nil, pendingDeliveries.isEmpty,
                  let target, currentContext().destination == target,
                  policy.request(.copy, context: currentContext()) != nil else {
                await destination.disarmRestoreForNextCopy(); return
            }
            requestedPasteDestination = target
            pasteAfterCopy = true
            pump()
        }
    }
    // false: secure input (a password field) is active, so nothing was copied.
    @discardableResult private func copyHistory(_ text: String) -> Bool {
        guard policy.copyEnabled, !IsSecureEventInputEnabled() else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
    private func rememberFrontApp() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
    }
    @objc private func showHistory() { openPanel(.home) }
    @objc private func showSettings() { openPanel(.settings) }
    @objc private func showDictionary() { openPanel(.dictionary) }
    @objc private func showOnboarding() {
        rememberFrontApp(); onboarding.showDictationKey(fn: policy.binding == .fn); onboarding.show()
    }
    // Hand focus back to the app the user came from once our windows are gone.
    private func windowClosed() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !home.isShown, !onboarding.isVisible, cardStorage?.isShown != true else { return }
            // Closing the panel by clicking another app leaves focus there.
            let stillOurs = NSWorkspace.shared.frontmostApplication?.processIdentifier
                == ProcessInfo.processInfo.processIdentifier
            if Self.mayHandBackFocus(stillOurs: stillOurs, windows: NSApp.windows) { previousApp?.activate() }
            previousApp = nil
        }
    }
    // A button in the panel can open one of our windows (Speech languages, Health…) as the panel
    // closes; handing focus back then buried that window and looked like a crash. Popovers, the
    // pill and the confetti are untitled, so they never hold focus here.
    static func mayHandBackFocus(stillOurs: Bool, windows: [NSWindow]) -> Bool {
        stillOurs && !windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
    }
    @objc private func changeBackend() {
        retryTask?.cancel()
        invalidateDelivery()
        policy.cancel(reason: "Speech engine changed")
        pump()
        let index = home.engine.indexOfSelectedItem
        let value: SpeechBackend = index == 2 || index == 3 ? .apple : .cloud
        defaults.set(index == 4, forKey: "elevenLabsDirect")
        speech.elevenLabsDirect = index == 4
        defaults.set(value.rawValue, forKey: "speechBackend")
        defaults.set(index == 1, forKey: "oneStepSpeech")
        defaults.set(index == 3, forKey: "onDeviceCleanup")
        speech.oneStep = index == 1
        speech.cloudCleanupOnDevice = index == 3
        speech.select(value)
        home.refreshPrices(); refresh()
    }
    @objc private func changeCleanup() {
        defaults.set(home.aiCleanup.state == .on, forKey: "aiCleanup")
        home.refreshPrices(); refreshHome()
    }
    @objc private func changeKeep() {
        let keep = home.keepOnClipboard.state == .on
        defaults.set(keep, forKey: "keepOnClipboard")
        Task { [destination] in await destination.setRestoreEnabled(!keep) }
    }
    @objc private func changeBinding() {
        let selected: Binding = home.shortcut.indexOfSelectedItem == 0 ? .fn : .controlOption
        guard selected != policy.binding else { return }
        invalidateDelivery()
        policy.setBinding(selected); defaults.set(selected.rawValue, forKey: "binding")
        keys.controlOptionChords = selected == .controlOption
        home.showDictationKey(fn: selected == .fn)
        onboarding.showDictationKey(fn: selected == .fn)
        // setBinding resets the listener; the running tap serves the new keys.
        if keys.active {
            policy.setListener(Listener(shortcutsEnabled: true, suppressingTapActive: true,
                                        competingBindingsAcknowledged: true))
        }
        pump(); onboarding.refresh()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        invalidateDelivery(); observationTask?.cancel(); deliveryTask?.cancel()
        policy.cancel(reason: "Quit")
        for action in policy.drainActions() { if case let .closeAdapters(id) = action { speech.close(id) } }
        // Write the line for a recording cut off by quitting, and any still waiting.
        if let generation = logTracker.settled(),
           let entry = ledger.finished(generation, inFlight: false, failure: "app quit") {
            writeLog(generation, entry, failure: entry.failure)
        }
        for (generation, entry) in ledger.delivered(inFlight: { _ in false }) {
            writeLog(generation, entry, failure: entry.failure ?? "app quit")
        }
        stopHealthMicrophone()
        CaptureExecution.interrupt(clipTask, permit: clipPermit)
        quitting = true; speech.shutdown(); keys.close()
        Task { await destination.close() }
        keys.receive = nil; keys.unavailable = nil; keys.recovered = nil; timer?.invalidate(); timer = nil
        for (center, token) in tokens { center.removeObserver(token) }; tokens.removeAll()
        writingTools?.clearSession(); retryTask?.cancel(); history.removeAll(); namesSeen.removeAll(); AudioOutbox.shared.purge()
        cardStorage?.flush(); clipboard.dropDictations(); clipboard.flush()
        pill.hide(); home.hide(); onboarding.window.orderOut(nil)
        NSStatusBar.system.removeStatusItem(item)
    }
}

@main enum CursusVoxMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--verify-pill-presentation") {
            app.setActivationPolicy(.accessory)
            Task { let result = await NativeDiagnostics.verifyPillPresentation(); fflush(stdout); exit(result) }
            app.run(); return
        }
        if CommandLine.arguments.contains("--verify-permissions") {
            app.setActivationPolicy(.prohibited)
            NativeDiagnostics.verifyPermissions(); fflush(stdout); exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--verify-live-preview"), index + 1 < CommandLine.arguments.count {
            app.setActivationPolicy(.prohibited)
            Task { let result = await NativeDiagnostics.verifyLivePreview(CommandLine.arguments[index + 1]); fflush(stdout); exit(result) }
            app.run(); return
        }
        if CommandLine.arguments.contains("--migrate-cloud-credential") ||
            CommandLine.arguments.contains("--provision-elevenlabs-credential") ||
            CommandLine.arguments.contains("--check-elevenlabs-credential") ||
            CommandLine.arguments.contains("--provision-cloud-credential") ||
            CommandLine.arguments.contains("--check-cloud-credential") {
            app.setActivationPolicy(.prohibited)
            let elevenLabs = CommandLine.arguments.contains("--provision-elevenlabs-credential") || CommandLine.arguments.contains("--check-elevenlabs-credential")
            let migrating = CommandLine.arguments.contains("--migrate-cloud-credential")
            let provisioning = migrating || CommandLine.arguments.contains("--provision-cloud-credential") || CommandLine.arguments.contains("--provision-elevenlabs-credential")
            Task {
                let result: Int32 = await Task.detached {
                    if provisioning {
                        let status = elevenLabs ? CloudCredentials.installElevenLabsFromEnvironment() : CloudCredentials.installFromEnvironment(rebindAccess: migrating)
                        print("SCOPED_KEYCHAIN_INSTALL_STATUS", status)
                        return status == 0 ? 0 : 1
                    }
                    let available = elevenLabs ? CloudCredentials.loadElevenLabs() != nil : CloudCredentials.load() != nil
                    print("SCOPED_KEYCHAIN_CREDENTIAL_PRESENT", available)
                    return available ? 0 : 2
                }.value
                fflush(stdout); exit(result)
            }
            app.run(); return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--self-test-docs"), index + 3 < CommandLine.arguments.count {
            app.setActivationPolicy(.prohibited)
            let args = CommandLine.arguments
            Task { await CaptureSelfTest.docs(browser: args[index + 1], page: args[index + 2], writingTo: args[index + 3]); exit(0) }
            app.run(); return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--self-test-keys"), index + 1 < CommandLine.arguments.count {
            app.setActivationPolicy(.prohibited)
            let letter = CommandLine.arguments[index + 1]
            let report = index + 2 < CommandLine.arguments.count ? CommandLine.arguments[index + 2] : nil
            Task { await CaptureSelfTest.pressChord(letter, report: report); exit(0) }
            app.run(); return
        }
        // Test hook for the Air over SSH: counts only, never page text.
        if let index = CommandLine.arguments.firstIndex(of: "--self-test-capture"), index + 1 < CommandLine.arguments.count {
            app.setActivationPolicy(.prohibited)
            let out = CommandLine.arguments[index + 1]
            let extra = Array(CommandLine.arguments.dropFirst(index + 2))
            Task { await CaptureSelfTest.run(writingTo: out, also: extra); exit(0) }
            app.run(); return
        }
        if CommandLine.arguments.contains("--demo-pill") {
            app.setActivationPolicy(.accessory)
            Task { await PillDemo.run(); exit(0) }
            app.run(); return
        }
        if CommandLine.arguments.contains("--verify-capture") {
            app.setActivationPolicy(.prohibited)
            Task {
                let result = await NativeDiagnostics.verifyCapture()
                fflush(stdout)
                exit(result)
            }
            app.run()
            return
        }
        let delegate = Application()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
