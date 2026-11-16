import AppKit

// `CursusVox --self-test-capture <file>`: for every running browser and the frontmost app, tries the
// direct page read, the Accessibility read and a full clip, and writes one JSON line per app with
// counts and outcomes only (no page text, no URLs beyond the host).
@MainActor enum CaptureSelfTest {
    // `CursusVox --self-test-docs <browser bundle> <docs page address> <file>`: the Google Docs export
    // alone, as fn+W and fn+T run it, with no keys pressed and no window brought forward. Writes one
    // JSON line of counts (no document text, no file name).
    static func docs(browser: String, page: String, writingTo path: String) async {
        var row: [String: Any] = ["browser": browser]
        if let export = GoogleDocs.export(for: page) {
            row["format"] = export.fileExtension
            let started = Date()
            if let file = await DocsExport.fetch(export, browser: browser) {
                let body = GoogleDocs.body(file.text, isTable: export.isTable)
                row["words"] = body.split(whereSeparator: \.isWhitespace).count
                row["bytes"] = file.text.utf8.count
                row["trashed"] = file.left == nil
            } else { row["export"] = "none" }
            row["seconds"] = (Date().timeIntervalSince(started) * 10).rounded() / 10
        } else { row["export"] = "not a docs page" }
        let data = (try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])) ?? Data()
        FileManager.default.createFile(atPath: path, contents: data + Data("\n".utf8))
    }
    static func run(writingTo path: String, also extra: [String] = []) async {
        let clipper = WebClipper()
        var lines: [String] = []
        let browsers = Set(FrontPage.chromium + FrontPage.safari + ["org.mozilla.firefox"])
        var apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier.map(browsers.contains) == true }
        if let front = NSWorkspace.shared.frontmostApplication, !apps.contains(front) { apps.append(front) }
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier.map(extra.contains) == true && !apps.contains(app) {
            apps.append(app)
        }
        for app in apps {
            guard let bundle = app.bundleIdentifier else { continue }
            var row: [String: Any] = ["app": bundle, "accessibilityTrusted": AXIsProcessTrusted()]
            if browsers.contains(bundle), bundle != "org.mozilla.firefox" {
                switch await FrontPage.read(bundle: bundle, timeout: 8) {
                case let .success(page): row["direct"] = "ok"; row["directHTMLChars"] = page.html.count
                    row["host"] = URL(string: page.url)?.host ?? "-"
                case let .failure(problem): row["direct"] = String(describing: problem)
                }
            }
            if let seen = await ScreenText.read(pid: app.processIdentifier, wantPage: browsers.contains(bundle)) {
                row["axWords"] = seen.words; row["axBlocks"] = seen.blocks.count
                row["axHost"] = seen.url.flatMap { URL(string: $0)?.host } ?? "-"
                row["axTitleChars"] = seen.title.count
                if GoogleDocs.isDocument(seen.url) {
                    let lower = seen.text.lowercased()
                    row["docsScreenReaderNotice"] = lower.contains("screen reader support")
                    row["docsMarker"] = lower.contains("wombat seventeen")
                }
                if let url = seen.url, url.hasPrefix("http"), seen.words > 0 {
                    row["axNoteChars"] = seen.note(url: url).markdown.count
                    if let id = YouTubeTranscript.videoID(url) {
                        let lines = await YouTubeTranscript.fetch(id: id)
                        row["transcriptWords"] = lines.map { $0.reduce(0) { $0 + $1.text.split(separator: " ").count } } ?? -1
                    }
                    if let copy = try? await clipper.clip(html: seen.html, url: url, timeout: 20) {
                        row["axViaClipperChars"] = copy.markdown.count
                    }
                }
            } else { row["ax"] = "no window" }
            if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8) { lines.append(line) }
        }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    // `CursusVox --self-test-keys t|w`: presses fn+T or fn+W at the HID level, exactly the events a
    // keyboard sends (fn flag change, the letter with the fn flag, fn up), so the running copy's event
    // tap and chord handling are exercised end to end. The result shows up in the running app's log.
    static func pressChord(_ letter: String, report path: String? = nil) async {
        guard let key: CGKeyCode = ["t": 17, "w": 13][letter.lowercased()] else { return }
        let facts = "postEventAccess=\(CGPreflightPostEventAccess()) accessibility=\(AXIsProcessTrusted())\n"
        if let path { try? facts.write(toFile: path, atomically: true, encoding: .utf8) }
        func post(_ make: () -> CGEvent?) { make()?.post(tap: .cghidEventTap) }
        func fnChange(_ down: Bool) -> CGEvent? {
            guard let event = CGEvent(source: CGEventSource(stateID: .hidSystemState)) else { return nil }
            event.type = .flagsChanged
            event.setIntegerValueField(.keyboardEventKeycode, value: 63)
            event.flags = down ? .maskSecondaryFn : []
            return event
        }
        func letterEvent(_ down: Bool) -> CGEvent? {
            let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: key, keyDown: down)
            event?.flags = .maskSecondaryFn
            return event
        }
        post { fnChange(true) }
        try? await Task.sleep(for: .milliseconds(120))
        post { letterEvent(true) }
        try? await Task.sleep(for: .milliseconds(60))
        post { letterEvent(false) }
        try? await Task.sleep(for: .milliseconds(60))
        post { fnChange(false) }
        try? await Task.sleep(for: .milliseconds(200))
    }
}
