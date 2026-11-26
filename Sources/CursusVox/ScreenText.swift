import AppKit
import ApplicationServices
import Carbon
import CursusCore
import CursusPlatform
import os

// The words in an app's front window, read through Accessibility (which CursusVox already has for
// pasting). Works in any browser without "Allow JavaScript from Apple Events" or Automation, and in
// ordinary apps. Password fields are never read. Used by fn+T (structured clip) and as fn+W's fallback.
// Every Accessibility call runs on its own serial queue, never the main thread, inside a deadline.
enum ScreenText {
    enum Problem: Error, Equatable, Sendable {
        case permission, protectedContent, excludedApplication, unavailableWindow, unsupportedInterface, changedOrigin, cancelled, timedOut, empty, readFailed
        var message: String {
            switch self {
            case .permission: return "Allow Mercurius in System Settings › Privacy & Security › Accessibility, then try again."
            case .protectedContent: return "This window or focused field is protected. Switch to ordinary content and try again."
            // Not a fault the user can fix by clicking: the app itself is one CursusVox never reads.
            case .excludedApplication: return "Mercurius doesn't read this app's window (a password app, the login window, the Dock or a remote session). Switch to another window and try again."
            case .unavailableWindow: return "The app's front window could not be identified. Click its window, then try again."
            case .unsupportedInterface: return "The app did not provide the Accessibility interface needed for a safe capture."
            case .changedOrigin: return "Capture cancelled because the source window or page changed. Return to it and try again."
            case .cancelled: return "Capture cancelled."
            case .timedOut: return "Reading the window reached its time limit. Try again when the app has settled."
            case .empty: return "The window's accessible content contains no readable text."
            case .readFailed: return "The app could not return its accessible text. Try again; this does not mean the window is empty."
            }
        }
    }
    struct Attribute {
        let value: Any?
        let status: AXError
    }
    nonisolated static func attribute(_ element: AXUIElement, _ name: String) -> Attribute {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
        return Attribute(value: status == .success ? raw : nil, status: status)
    }

    struct Capture {
        let title: String
        let url: String?      // the page address when the window shows a web page
        let blocks: [Block]
        let partial: Bool
        let readFailed: Bool
        init(title: String, url: String?, blocks: [Block], partial: Bool = false, readFailed: Bool = false) {
            self.title = title; self.url = url; self.blocks = blocks; self.partial = partial; self.readFailed = readFailed
        }
        var text: String {
            blocks.map { block in
                switch block {
                case let .heading(words): return "# " + words
                case let .line(words): return words
                }
            }.joined(separator: "\n")
        }
        // Simple HTML for the web clipper, so a fallback clip becomes the same kind of note.
        var html: String {
            let body = blocks.map { block -> String in
                switch block {
                case let .heading(words): return "<h2>\(escape(words))</h2>"
                case let .line(words): return "<p>\(escape(words))</p>"
                }
            }.joined(separator: "\n")
            return "<!doctype html><html><head><title>\(escape(title))</title></head><body><article>\n\(body)\n</article></body></html>"
        }
        var words: Int {
            blocks.reduce(0) { total, block in
                switch block {
                case let .heading(w), let .line(w): return total + w.split(whereSeparator: \.isWhitespace).count
                }
            }
        }
        // Empty text does not discard page metadata needed by document/transcript fallbacks.
        var textProblem: Problem? {
            guard words == 0 else { return nil }
            return readFailed ? .readFailed : partial ? .timedOut : .empty
        }
        // A clip note with the same properties as the web clipper's, keeping every word read:
        // the clipper's article detection drops most of a page seen this way (YouTube kept 270 characters).
        // Non-web windows use `site` (app name) and `app://bundleID` as source when there is no http(s) URL.
        func note(url: String? = nil, site: String? = nil, bundleID: String? = nil, now: Date = Date()) -> WebClipper.Note {
            let body = blocks.map { block -> String in
                switch block { case let .heading(words): return "## " + words; case let .line(words): return words }
            }.joined(separator: "\n\n")
            let source = ScreenText.clipSource(url: url ?? self.url, bundleID: bundleID)
            return ScreenText.note(title: ScreenText.pageTitle(title, app: site, url: url ?? self.url), url: source, body: partial
                ? body + "\n\n> Partial capture: some window content could not be read. Return to the source to check what is missing."
                : body, site: site, now: now)
        }
    }
    // Tab states Chromium browsers append to a window title.
    static let tabStates = ["Audio playing", "Audio muted", "Camera or microphone recording", "Camera recording",
                            "Microphone recording", "Sharing your screen", "Bluetooth device connected",
                            "USB device connected", "Network error", "Crashed"]
    // The page's own title from a window title: no trailing " - <app>", no tab state, and on
    // YouTube no " - YouTube" or unread-count prefix. Never strips a title down to nothing.
    static func pageTitle(_ window: String, app: String?, url: String?) -> String {
        var title = window.trimmingCharacters(in: .whitespaces)
        func dropSuffix(_ suffix: String) -> Bool {
            let tail = " - " + suffix
            guard let range = title.range(of: tail, options: [.anchored, .backwards, .caseInsensitive]),
                  range.lowerBound > title.startIndex else { return false }
            title = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            return true
        }
        if let app = app?.trimmingCharacters(in: .whitespaces), !app.isEmpty { _ = dropSuffix(app) }
        while tabStates.contains(where: dropSuffix) {}
        if let url, YouTubeTranscript.videoID(url) != nil {
            let cleaned = YouTubeTranscript.title(fromWindow: title)
            if !cleaned.isEmpty { title = cleaned }
        }
        return title.isEmpty ? window.trimmingCharacters(in: .whitespaces) : title
    }
    // http(s) page address when present; otherwise a stable app:// bundle reference for frontmatter.
    static func clipSource(url: String?, bundleID: String?) -> String {
        if let url, let scheme = URL(string: url)?.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            return url
        }
        if let bundleID, !bundleID.isEmpty { return "app://\(bundleID)" }
        return "app://"
    }
    // One clip note: the web clipper's properties above `body` (Markdown), named after `title`
    // or, without one, the page's host / app site. Google Docs exports become notes through this too.
    // `site` is the app or host name shown in frontmatter (app name for non-web windows).
    static func note(title: String, url: String, body: String, site: String? = nil, now: Date = Date()) -> WebClipper.Note {
        let host = URL(string: url)?.host
        let siteName = site?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSite = (siteName?.isEmpty == false ? siteName! : (host ?? ""))
        let name = title.isEmpty ? (host ?? (siteName?.isEmpty == false ? siteName! : nil) ?? "Clip") : title
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ") + "\""
        }
        let markdown = """
        ---
        title: \(quoted(name))
        source: \(quoted(url))
        site: \(quoted(resolvedSite))
        clipped: \(ISO8601DateFormatter().string(from: now))
        tags:
          - clippings
        ---

        \(body)

        """
        return WebClipper.Note(name: name, markdown: markdown, title: name)
    }
    enum Block: Equatable, Sendable { case heading(String), line(String) }


    nonisolated static let nodeLimit = 40_000
    nonisolated static let depthLimit = 160
    nonisolated static let characterLimit = 2_000_000

    struct Origin: @unchecked Sendable {
        let pid: pid_t
        let launch: Date
        let window: AXUIElement
        // The address of the pinned page, when the app is a browser. The AXWebArea element itself
        // is not kept: a browser replaces it as a page loads, so the read resolves it again by
        // address (2026-11-01).
        let page: String?
        let observation: CaptureObservation
        let interface: CaptureInterfaceLease
        let identity: CaptureAdmission.Origin
        var title: String { identity.title }
        var address: String? { identity.document }
    }
    private static let reader = ScreenReader()
    static func begin(pid: pid_t) async -> Origin? { try? await reader.begin(pid: pid) }
    static func start(pid: pid_t) async -> Result<Origin, Problem> {
        do { return .success(try await reader.begin(pid: pid)) }
        catch { return .failure(error) }
    }
    static func result(origin: Origin, within seconds: Double = 5) async -> Result<Capture, Problem> {
        if Task.isCancelled { return .failure(.cancelled) }
        let capture = await read(origin: origin, within: seconds)
        return result(from: capture, cancelled: Task.isCancelled)
    }
    static func result(from capture: Capture?, cancelled: Bool) -> Result<Capture, Problem> {
        if cancelled { return .failure(.cancelled) }
        guard let capture else { return .failure(.changedOrigin) }
        return .success(capture)
    }
    static func isCurrent(_ origin: Origin) async -> Bool { await reader.isCurrent(origin) }
    static func read(origin: Origin, wantPage: Bool = false, within seconds: Double = 5) async -> Capture? {
        await reader.read(origin: origin, wantPage: wantPage, deadline: Date().addingTimeInterval(seconds))
    }
    static func read(pid: pid_t, wantPage: Bool = false, within seconds: Double = 5) async -> Capture? {
        guard let origin = await begin(pid: pid) else { return nil }
        return await read(origin: origin, wantPage: wantPage, within: seconds)
    }
    static func address(pid: pid_t) async -> String? { await begin(pid: pid)?.address }
    static func front(pid: pid_t) async -> (address: String?, title: String)? {
        guard let origin = await begin(pid: pid) else { return nil }
        return (origin.address, origin.title)
    }

    nonisolated static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
    nonisolated static func role(_ element: AXUIElement) -> String? { value(element, "AXRole") }
    // The address an AXWebArea reports. The one place the address of a page element is read.
    nonisolated static func pageAddress(_ web: AXUIElement) -> String? {
        (value(web, "AXURL") as URL?)?.absoluteString ?? (value(web, "AXURL") as String?)
    }
    nonisolated static func children(_ element: AXUIElement) -> [AXUIElement] { value(element, "AXChildren") ?? [] }
    nonisolated static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? T
    }
    nonisolated static func findWebArea(_ root: AXUIElement, depth: Int, until deadline: Date = .distantFuture) -> AXUIElement? {
        walkWebAreas(root, depth: depth, until: deadline) { _ in true }
    }
    // The page area holding the address we pinned. A browser re-creates the AXWebArea element as
    // a page loads and hosts cross-origin frames as further web areas, so identity must be the
    // address, not the element: a Stripe frame inside Comet made the old CFEqual check refuse a
    // capture that was still on the right page (2026-11-01).
    nonisolated static func findWebArea(_ root: AXUIElement, page: String?, depth: Int, until deadline: Date) -> AXUIElement? {
        guard let page, !page.isEmpty else { return nil }
        return walkWebAreas(root, depth: depth, until: deadline) { pageAddress($0) == page }
    }
    private nonisolated static func walkWebAreas(_ root: AXUIElement, depth: Int, until deadline: Date,
                                                matching: (AXUIElement) -> Bool) -> AXUIElement? {
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while let (element, level) = stack.popLast(), visited < nodeLimit, Date() < deadline, !Task.isCancelled {
            visited += 1
            AXUIElementSetMessagingTimeout(element, 0.5)
            if role(element) == "AXWebArea", matching(element) { return element }
            if level < depth { stack.append(contentsOf: children(element).reversed().map { ($0, level + 1) }) }
        }
        return nil
    }
}

// Serial Accessibility work off the main thread (the fn shortcuts' event tap runs on main).
actor ScreenReader {
    private nonisolated let executor = AXExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private static let clipLog = Logger(subsystem: "au.com.mykoala.mercurius", category: "clip")

    private var interfaces: [String: (users: Int, enhanced: Bool?, app: FieldHandle)] = [:]
    private func acquireInterface(app: AXUIElement, key: String) -> CaptureInterfaceLease {
        if var entry = interfaces[key] { entry.users += 1; interfaces[key] = entry }
        else {
            let enhanced: Bool? = ScreenText.value(app, "AXEnhancedUserInterface")
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            if enhanced == false { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
            interfaces[key] = (1, enhanced, FieldHandle(element: app))
        }
        return CaptureInterfaceLease { Task { await self.releaseInterface(key) } }
    }
    private func releaseInterface(_ key: String) {
        guard var entry = interfaces[key] else { return }
        entry.users -= 1
        if entry.users > 0 { interfaces[key] = entry; return }
        interfaces[key] = nil
        if entry.enhanced == false {
            AXUIElementSetAttributeValue(entry.app.element, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }
    }
    private func admission(pid: pid_t, requiringFront: Bool) -> CaptureAdmission.Outcome {
        let app = NSRunningApplication(processIdentifier: pid)
        let classification = NativeTargets.classifyCapture(bundleID: app?.bundleIdentifier, name: app?.localizedName)
        // The same front-app source the shortcut used: NSWorkspace can report the previous app and
        // would refuse a capture that is standing in front of the right window (2026-11-01). At the
        // start the shortcut has already resolved which app is front, so requiring it again there
        // only races the press; while a capture is running it is the protection that matters.
        let front = FrontApp.current()?.processIdentifier
        return CaptureAdmission.admit(classification: classification,
            secureInput: IsSecureEventInputEnabled(),
            credentialApplication: app?.bundleIdentifier == Bundle.main.bundleIdentifier
                || CaptureAdmission.isCredentialApplication(name: app?.localizedName, bundleID: app?.bundleIdentifier),
            knownProcess: CursusProcessSameUser(pid)
                && (!requiringFront || front == pid),
            windowAvailable: true)
    }
    // The app's launch time, or the epoch when macOS does not report one (Finder, launched at
    // login, has no launchDate; requiring it refused every Fn+T in Finder, 2026-11-01). A restart
    // is still caught: a new process gets a new pid and a fresh window element.
    private func launchStamp(_ pid: pid_t) -> Date {
        NSRunningApplication(processIdentifier: pid)?.launchDate ?? Date(timeIntervalSince1970: 0)
    }
    // A focused element that exists must be readable: a password field or an unknown control
    // refuses the read. An app that exposes no focused element at all (T3 Code, Comet; both
    // return kAXErrorNoValue for AXFocusedUIElement) is captured from its front window instead,
    // and the walker still skips every secure or unclassified text field it meets (2026-11-01).
    private func protectedFocus(_ app: AXUIElement) -> Bool {
        let result = ScreenText.attribute(app, "AXFocusedUIElement")
        if result.status == .noValue || result.status == .attributeUnsupported { return false }
        guard let raw = result.value, CFGetTypeID(raw as CFTypeRef) == AXUIElementGetTypeID() else { return true }
        let focused = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, 0.5)
        let role = ScreenText.role(focused)
        let subrole: String? = ScreenText.value(focused, "AXSubrole")
        return !CaptureAdmission.readableFocus(role: role, subrole: subrole)
    }
    // The window a capture pins: the focused one, else the app's main window, else its first
    // window. A windowless lookup would refuse a capture that has a perfectly readable window.
    private func frontWindow(_ app: AXUIElement) -> AXUIElement? {
        if let window: AXUIElement = ScreenText.value(app, "AXFocusedWindow") { return window }
        if let window: AXUIElement = ScreenText.value(app, "AXMainWindow") { return window }
        let windows: [AXUIElement] = ScreenText.value(app, "AXWindows") ?? []
        return windows.first
    }
    // The page actually read AND the address the window claims: a browser can report a stale window
    // address, so the page is what the clip pins, but a change to either still marks the capture stale.
    private func identity(_ window: AXUIElement, pid: pid_t, launch: Date, address: String? = nil) -> CaptureAdmission.Origin {
        let document = [address, Self.document(window)].compactMap { $0 }.joined(separator: " | ")
        return .init(process: "\(pid):\(launch.timeIntervalSince1970)", window: "origin",
                     document: document.isEmpty ? nil : document, title: ScreenText.value(window, "AXTitle") ?? "")
    }
    // The address the window itself claims, when it has one.
    private static func document(_ window: AXUIElement) -> String? {
        (ScreenText.value(window, "AXDocument") as URL?)?.absoluteString
            ?? (ScreenText.value(window, "AXDocument") as String?)
    }
    func begin(pid: pid_t) async throws(ScreenText.Problem) -> ScreenText.Origin {
        guard AXIsProcessTrusted() else { throw .permission }
        guard !Task.isCancelled else { throw .cancelled }
        let admitted = admission(pid: pid, requiringFront: false)
        // Say which refusal it was: "this window is protected" for an app CursusVox never reads
        // left the user guessing which app or which field was the problem (2026-11-01).
        if admitted != .allowed {
            Self.clipLog.info("capture refused at admission: \(String(describing: admitted), privacy: .public)")
            switch admitted {
            case .refused(.excludedApplication): throw .excludedApplication
            case .refused(.unavailableWindow): throw .unavailableWindow
            default: throw .protectedContent
            }
        }
        let launch = launchStamp(pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        // One actor-owned lease keeps tree setup/restoration serialized across captures and late cleanup.
        let interface = acquireInterface(app: app, key: "\(pid):\(launch.timeIntervalSince1970)")
        guard !protectedFocus(app) else { throw .protectedContent }
        guard let window = frontWindow(app) else { throw .unavailableWindow }
        AXUIElementSetMessagingTimeout(window, 0.5)
        guard let observation = CaptureObservation(app: app, pid: pid) else { throw .unsupportedInterface }
        // Browser page binding is separate from a desktop window, which may host several URL-less web views.
        let browser = FrontPage.isBrowser(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
        // The window's own address first, so the page we read is the one the window claims. A browser
        // can report a stale address (Comet held a previous site while the tab showed another), so a
        // window with no matching page area falls back to the page area in front of it rather than
        // refusing a capture that is genuinely on a real page (2026-11-01).
        func frontPageArea() -> AXUIElement? {
            if let address = Self.document(window), let match = ScreenText.findWebArea(window, page: address, depth: 40, until: Date().addingTimeInterval(0.5)) {
                return match
            }
            return ScreenText.findWebArea(window, depth: 40, until: Date().addingTimeInterval(0.5))
        }
        var web = browser ? frontPageArea() : nil
        let until = Date().addingTimeInterval(2)
        while web == nil, browser, Date() < until {
            guard observation.permit.valid, admission(pid: pid, requiringFront: true) == .allowed, !Task.isCancelled else { throw .changedOrigin }
            try? await Task.sleep(for: .milliseconds(100))
            web = frontPageArea()
        }
        let page = web.flatMap(Self.pageURL)
        if browser && (web == nil || page == nil) { throw .unsupportedInterface }
        if let document = Self.document(window), let page, document != page {
            // Hosts only: a full address can carry tokens, and this log is readable system-wide.
            let host = { (url: String) in URL(string: url)?.host ?? "unparsed" }
            Self.clipLog.info("front window reports \(host(document), privacy: .public) while its page area reads \(host(page), privacy: .public)")
        }
        let windowIdentity = identity(window, pid: pid, launch: launch, address: page)
        let origin = ScreenText.Origin(pid: pid, launch: launch, window: window, page: page,
                                       observation: observation, interface: interface, identity: windowIdentity)
        guard isCurrent(origin) else { throw .changedOrigin }
        return origin
    }
    func isCurrent(_ origin: ScreenText.Origin) -> Bool {
        if let reason = staleness(origin) {
            Self.clipLog.info("capture stale: \(reason, privacy: .public)")
            return false
        }
        return true
    }
    // Which check refused a capture, as a short token that carries no page text: a failed clip
    // then says why in the log instead of only "the window changed" (2026-11-01).
    private func staleness(_ origin: ScreenText.Origin) -> String? {
        let admitted = admission(pid: origin.pid, requiringFront: true)
        if !origin.observation.permit.valid { return "focus moved in the app" }
        if admitted != .allowed { return "admission \(String(describing: admitted))" }
        if launchStamp(origin.pid) != origin.launch { return "app restarted" }
        let app = AXUIElementCreateApplication(origin.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        if protectedFocus(app) { return "focused field is protected" }
        guard let focused = frontWindow(app) else { return "no front window" }
        if !CFEqual(focused, origin.window) { return "a different window is front" }
        if let page = origin.page {
            guard ScreenText.findWebArea(origin.window, page: page, depth: 40, until: Date().addingTimeInterval(1)) != nil else { return "the page area was not found" }
        }
        let current = identity(origin.window, pid: origin.pid, launch: origin.launch, address: origin.page)
        if current.process != origin.identity.process || current.window != origin.identity.window { return "a different window is front" }
        if current.document != origin.identity.document { return "the window's address changed" }
        if current.title != origin.identity.title { return "the window was retitled" }
        if !origin.observation.permit.valid { return "focus moved in the app" }
        if Task.isCancelled { return "cancelled" }
        return nil
    }

    func read(origin: ScreenText.Origin, wantPage: Bool, deadline: Date) async -> ScreenText.Capture? {
        guard isCurrent(origin) else { return nil }
        let app = AXUIElementCreateApplication(origin.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var best: ScreenText.Capture?
        // Chrome takes a few seconds to build a background or freshly asked-for page.
        while Date() < deadline, !Task.isCancelled {
            guard isCurrent(origin) else { return nil }
            if let capture = Self.capture(origin, wantPage: wantPage, deadline: deadline) {
                if capture.words >= (best?.words ?? -1) { best = capture }
                if capture.words >= 20, !wantPage || capture.url != nil { break }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return isCurrent(origin) ? best : nil
    }

    private static func pageURL(_ web: AXUIElement) -> String? { ScreenText.pageAddress(web) }
    private static func capture(_ origin: ScreenText.Origin, wantPage: Bool, deadline: Date) -> ScreenText.Capture? {
        // Read the page area that still holds the pinned address: a browser replaces the element as
        // a page loads, and using the replaced one reads an empty tree.
        let web = origin.page.flatMap { ScreenText.findWebArea(origin.window, page: $0, depth: 40, until: min(deadline, Date().addingTimeInterval(1))) }
        if origin.page != nil, web == nil { return nil }
        let url = web.flatMap(pageURL)
        if wantPage {
            guard let url, let scheme = URL(string: url)?.scheme, ["http", "https"].contains(scheme) else { return nil }
        }
        var walker = Walker(deadline: deadline, permit: origin.observation.permit)
        if let web { walker.walkPage(web) } else { walker.walk(origin.window) }
        // Focus moving mid-walk invalidates the capture, however good the words look.
        guard origin.observation.permit.valid else { return nil }
        return ScreenText.Capture(title: origin.title, url: url, blocks: walker.blocks, partial: walker.partial, readFailed: walker.readFailed)
    }

    // Iterative (no recursion to overflow), bounded by nodes, depth, characters and the deadline.
    struct Walker {
        let deadline: Date
        private let permit: EffectPermit?
        var blocks: [ScreenText.Block] = []
        private(set) var partial = false
        private(set) var readFailed = false
        private let readAttribute: (AXUIElement, String) -> ScreenText.Attribute
        private let secureInput: () -> Bool
        private var line = ""
        private var nodes = 0
        private var remaining = ScreenText.characterLimit
        init(deadline: Date, permit: EffectPermit? = nil,
             readAttribute: @escaping (AXUIElement, String) -> ScreenText.Attribute = ScreenText.attribute,
             secureInput: @escaping () -> Bool = { IsSecureEventInputEnabled() }) {
            self.deadline = deadline; self.permit = permit; self.readAttribute = readAttribute; self.secureInput = secureInput
        }
        private mutating func value<T>(_ element: AXUIElement, _ name: String) -> T? {
            let result = readAttribute(element, name)
            if result.status != .success && result.status != .attributeUnsupported && result.status != .noValue {
                partial = true; readFailed = true
            }
            return result.value as? T
        }

        private static let skipped: Set<String> = ["AXSecureTextField", "AXMenuBar", "AXMenu", "AXMenuItem", "AXScrollBar",
                                                   "AXImage", "AXToolbar"]
        private static let inline: Set<String> = ["AXStaticText", "AXLink", "AXTextField", "AXTextArea"]
        // Page furniture around the content: site header, menus, sidebars, footer, search box.
        static let furniture: Set<String> = ["AXLandmarkBanner", "AXLandmarkNavigation", "AXLandmarkComplementary",
                                            "AXLandmarkContentInfo", "AXLandmarkSearch"]
        // Below this many words a main landmark is a loading shell, not the page's content.
        static let mainMinimumWords = 20

        // A web page: its main landmark when it has real content, otherwise the whole page;
        // either way without the page furniture.
        mutating func walkPage(_ root: AXUIElement) {
            // A read error while looking for main is not a gap in the clip.
            let (wasPartial, hadFailure) = (partial, readFailed)
            let found = findMain(root)
            (partial, readFailed) = (wasPartial, hadFailure)
            guard let main = found else { walk(root); return }
            let start = self
            walk(main)
            let words = blocks.reduce(0) { total, block in
                switch block { case let .heading(w), let .line(w): return total + w.split(whereSeparator: \.isWhitespace).count }
            }
            if words < Self.mainMinimumWords { self = start; walk(root) }
        }
        // Nodes the main-landmark search may queue; main sits near the top of a page.
        static let mainSearchNodes = 4000
        // Breadth-first and shallow, with at most a quarter of the time left (never over 0.25 s), so a
        // page without a main landmark still has time for the whole-page walk. Same guards as the walk.
        private mutating func findMain(_ root: AXUIElement) -> AXUIElement? {
            let until = min(deadline, Date().addingTimeInterval(min(0.25, deadline.timeIntervalSinceNow / 4)))
            var queue: [(AXUIElement, Int)] = [(root, 0)], index = 0
            while index < queue.count, Date() < until, permit?.valid != false, !secureInput(), !Task.isCancelled {
                let (element, depth) = queue[index]; index += 1
                // Each request is capped by the search time left, so the search never overruns its share.
                func ready() -> Bool {
                    let left = until.timeIntervalSinceNow
                    guard left > 0, permit?.valid != false, !secureInput(), !Task.isCancelled else { return false }
                    AXUIElementSetMessagingTimeout(element, Float(min(0.05, left)))
                    return true
                }
                guard ready() else { break }
                if (value(element, "AXSubrole") as String?) == "AXLandmarkMain" { return element }
                guard depth < 12, queue.count < Self.mainSearchNodes, ready() else { continue }
                let children: [AXUIElement] = value(element, "AXChildren") ?? []
                queue += children.prefix(Self.mainSearchNodes - queue.count).map { ($0, depth + 1) }
            }
            return nil
        }
        private enum Step { case visit(AXUIElement, Int), flush, heading(start: Int) }

        mutating func walk(_ root: AXUIElement) {
            var stack: [Step] = [.visit(root, 0)]
            while let step = stack.popLast() {
                switch step {
                case .flush: flush()
                case let .heading(start):
                    flush()
                    // Collapse the heading's own lines into one heading block.
                    let words = blocks[start...].map { block -> String in
                        switch block { case let .heading(w), let .line(w): return w }
                    }.joined(separator: " ")
                    blocks.removeSubrange(start...)
                    if !words.isEmpty { blocks.append(.heading(words)) }
                case let .visit(element, depth):
                    nodes += 1
                    guard permit?.valid != false, !secureInput(), nodes < ScreenText.nodeLimit, remaining > 0, depth < ScreenText.depthLimit, Date() < deadline, !Task.isCancelled else { partial = true; continue }
                    AXUIElementSetMessagingTimeout(element, 0.5)
                    let kind: String = value(element, "AXRole") ?? ""
                    if Self.skipped.contains(kind) { continue }
                    switch kind {
                    case "AXStaticText":
                        let words: String? = value(element, "AXValue") ?? value(element, "AXTitle")
                        add(words); continue
                    case "AXTextField":
                        // Password fields are text fields with a secure subrole. A field is read only when its subrole
                        // reads back and isn't secure; an unknown classification is skipped (fail closed).
                        let subrole: String? = value(element, "AXSubrole")
                        if let subrole,
                           CaptureAdmission.readableFocus(role: "AXTextField", subrole: subrole) { add(value(element, "AXValue")) }
                        continue
                    case "AXTextArea":
                        // macOS has no secure text area (passwords are always text fields); document bodies live here.
                        add(value(element, "AXValue"))
                        continue
                    case "AXHeading":
                        flush()
                        stack.append(.heading(start: blocks.count))
                    default:
                        if kind == "AXGroup", let subrole: String = value(element, "AXSubrole"),
                           Self.furniture.contains(subrole) { continue }
                        if !Self.inline.contains(kind) { flush(); stack.append(.flush) }
                    }
                    let children: [AXUIElement] = value(element, "AXChildren") ?? []
                    for child in children.reversed() { stack.append(.visit(child, depth + 1)) }
                }
            }
            flush()
        }
        private mutating func add(_ text: String?) {
            guard var text, !text.isEmpty, remaining > 0 else { return }
            if text.count > remaining { text = String(text.prefix(remaining)); partial = true }
            remaining -= text.count
            line += (line.isEmpty || line.hasSuffix(" ") ? "" : " ") + text
        }
        private mutating func flush() {
            let words = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !words.isEmpty { blocks.append(.line(words)) }
            line = ""
        }
    }
}

// Observed focus changes revoke admission; returning to the source cannot restore that permit.
final class CaptureObservation: @unchecked Sendable {
    let permit: EffectPermit
    private let observer: AXObserver
    private let app: AXUIElement
    private let names: [String]
    private let info: UnsafeMutableRawPointer
    init?(app: AXUIElement, pid: pid_t) {
        let permit = EffectPermit(expiresAt: ProcessInfo.processInfo.systemUptime + 60)
        let names = ["AXFocusedWindowChanged", "AXFocusedUIElementChanged"]
        var created: AXObserver?
        let callback: AXObserverCallback = { _,_,_, info in
            guard let info else { return }
            CaptureObservation.observedChange(Unmanaged<EffectPermit>.fromOpaque(info).takeUnretainedValue())
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return nil }
        let info = Unmanaged.passRetained(permit).toOpaque()
        var registered: [String] = []
        for name in names {
            guard AXObserverAddNotification(created, app, name as CFString, info) == .success else {
                for added in registered { AXObserverRemoveNotification(created, app, added as CFString) }
                Unmanaged<EffectPermit>.fromOpaque(info).release()
                return nil
            }
            registered.append(name)
        }
        self.observer = created; self.app = app; self.permit = permit; self.info = info; self.names = names
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }
    nonisolated static func observedChange(_ permit: EffectPermit) { permit.revoke() }
    private struct Cleanup: @unchecked Sendable {
        let observer: AXObserver
        let app: AXUIElement
        let names: [String]
        let info: UnsafeMutableRawPointer
        func unregister() {
            AXUIElementSetMessagingTimeout(app, 0.1)
            for name in names { AXObserverRemoveNotification(observer, app, name as CFString) }
            // Releases the +1 taken by passRetained. This runs on the main thread, after the run-loop
            // source has been invalidated, so no callback can be holding the same pointer.
            _ = Unmanaged<EffectPermit>.fromOpaque(info).takeRetainedValue()
        }
    }
    deinit {
        permit.revoke()
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFRunLoopSourceInvalidate(source)
        let cleanup = Cleanup(observer: observer, app: app, names: names, info: info)
        // AX callbacks are delivered on the main run loop. Tearing down on a background queue released
        // the permit's +1 on another thread, so a callback that ran in the gap could read a freed
        // object. The whole teardown now happens on the main thread, after the source is invalidated.
        if Thread.isMainThread { cleanup.unregister() }
        else { DispatchQueue.main.async { cleanup.unregister() } }
    }
}

final class CaptureInterfaceLease: @unchecked Sendable {
    private let release: @Sendable () -> Void
    init(release: @escaping @Sendable () -> Void) { self.release = release }
    deinit { release() }
}
