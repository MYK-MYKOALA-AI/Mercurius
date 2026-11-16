import AppKit
import QuartzCore
import Foundation
import Testing
import CursusCore
@testable import CursusVox

// Matched synthetic renders of the delivery text change, without microphone or editor access.
@MainActor @Test func renderDeliveredTranscriptEchoForReview() async throws {
    guard let dir = ProcessInfo.processInfo.environment["CURSUS_RENDER_UI"] else { return }
    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: .aqua)
    await KoaFrames.shared.load(from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Koa"))
    let pill = RecordingPill()
    pill.reduceMotion = { true }
    defer { pill.hide() }
    for (name, transcript) in [("pill-echo-before", Optional<String>.none),
                               ("pill-echo-after", "Send the build notes before lunch.")] {
        let content = try #require(PillDisplay.result([.recognized, .pasteSentUnconfirmed], onDevice: false,
                                                     transcript: transcript))
        pill.show(content, now: 100); pill.settleForSnapshot(); pill.panel.alphaValue = 1
        let view = try #require(pill.panel.contentView?.superview)
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded(); CATransaction.flush()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }
}

// Opt-in layout snapshots: CURSUS_RENDER_UI=<dir> swift test --filter UIRender.
// Renders the real views offscreen; it is not proof of live on-screen behaviour.
@MainActor @Test func renderUIForReview() async throws {
    guard let dir = ProcessInfo.processInfo.environment["CURSUS_RENDER_UI"] else { return }
    await KoaFrames.shared.load(from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Koa"))
    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["CURSUS_RENDER_DARK"] == nil ? .aqua : .darkAqua)
    // The frame view includes the window background, so text is drawn on it.
    func save(_ window: NSWindow, _ name: String) throws {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
        window.displayIfNeeded()
        let view = try #require(window.contentView?.superview)
        window.contentView?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        view.needsDisplay = true
        view.displayIfNeeded()
        CATransaction.flush()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }
    let onboarding = Onboarding()
    onboarding.rows = {
        [.init(title: "Microphone", detail: "Allowed", status: .done, button: nil, action: nil),
         .init(title: "Accessibility", detail: "So Mercurius can paste into the app you're using. Turn on Mercurius in the list.",
               status: .todo, button: "Allow", action: {}),
         .init(title: "Input Monitoring", detail: "So Mercurius notices when you hold the shortcut. Turn on Mercurius in the list.",
               status: .todo, button: "Allow", action: {}),
         .init(title: "Globe (🌐) key", detail: "In Keyboard settings set “Press 🌐 key to” to Do Nothing, or macOS also reacts when you hold Fn.",
               status: .warning, button: "Open Keyboard", action: {}),
         .init(title: "Grok", detail: "Connected", status: .done, button: nil, action: nil),
         .init(title: "On-device speech", detail: "Allowed, used when Grok is unavailable", status: .done, button: nil, action: nil)]
    }
    onboarding.refresh(force: true)
    try save(onboarding.window, "onboarding")
    // The panel's content, hosted in an offscreen window so it can be drawn.
    let home = HomePanel()
    home.showDictationKey(fn: true)
    home.savedDictionary = { (terms: ["Vercel", "Tessah"], replacements: ["vassal": "Vercel"]) }
    home.dropTakeBacks.state = .on
    home.takeBackPhrases = { TakeBack.defaults + ["no weight"] }
    home.suggestions = { [.init(term: "Riverton", count: 5), .init(term: "Kora", count: 3)] }
    home.update(history: [HistoryEntry(text: "Send Sam the build notes before lunch.", at: Date(),
                                       detail: "Grok · 2.1 s · cleaned 0.3 s"),
                          HistoryEntry(text: "Deploy the Supabase migration then ping me on Telegram.", at: Date(),
                                       raw: "Deploy the super base migration then um ping me on telegram.",
                                       detail: "Grok · 1.9 s · cleaned 0.4 s")])
    home.update(history: [HistoryEntry(text: "Send Sam the build notes before lunch.", at: Date(),
                                       detail: "Grok · 2.1 s · cleaned 0.3 s",
                                       costs: "grok-stt-1.0 $0.00058 · gpt-oss-120b $0.000041"),
                          HistoryEntry(text: "Deploy the Supabase migration then ping me on Telegram.", at: Date(),
                                       raw: "Deploy the super base migration then um ping me on telegram.",
                                       detail: "Grok · 1.9 s · cleaned 0.4 s",
                                       costs: "grok-stt-1.0 $0.00053 · gemma-4-31b-it $0.000020 · gpt-oss-120b $0.000038")],
                failed: [AudioOutbox.Item(id: UUID(), at: Date(), seconds: 6.2)])
    home.setStatus("Ready", ok: true)
    home.setCounts(words: 12, phrases: 7)
    home.status.stringValue = "Hold Fn to dictate. Grok connected."
    // The main clipboard with one of each kind, from a throwaway store.
    let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storeRoot) }
    let store = ClipboardStore(root: storeRoot)
    let now = Date()
    store.add(capture: "Quarterly numbers…", title: "Q3 board update — Google Docs", source: "Google Chrome",
              url: "https://docs.google.com/document/d/x", now: now.addingTimeInterval(-3 * 3600))
    let saved = store.add(clip: ClipDraft(title: "How the Koala sleeps 20 hours a day", properties: [
        .init(name: "source", kind: .text, value: "https://en.wikipedia.org/wiki/Koala")], body: "x"), source: "Safari",
        now: now.addingTimeInterval(-26 * 3600))
    store.markSaved(saved, file: URL(fileURLWithPath: "/tmp/Koala.md"), draft: ClipDraft(title: "How the Koala sleeps 20 hours a day", properties: [], body: "x"))
    let pinned = store.add(capture: "words", title: "Release checklist", source: "Notes", url: nil, now: now.addingTimeInterval(-40 * 3600))
    store.setPinned(pinned, true)
    store.add(clip: ClipDraft(title: "Ship it Friday: how we release every week without drama", properties: [
        .init(name: "source", kind: .text, value: "https://notes.example.com/ship")], body: String(repeating: "word ", count: 900)),
        source: "Comet", now: now.addingTimeInterval(-20 * 60))
    store.add(dictation: "Send Sam the build notes before lunch.", at: now.addingTimeInterval(-90))
    home.clipboardItems = { store.items }
    home.clipboardProblem = { nil }
    let host = NSWindow(contentRect: NSRect(origin: .zero, size: HomePanel.size), styleMask: [.borderless],
                        backing: .buffered, defer: false)
    host.contentView = try #require(home.popover.contentViewController?.view)
    host.backgroundColor = .windowBackgroundColor
    host.contentView?.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    let listPrices: [String: ModelPrice] = [
        "x-ai/grok-stt-1.0": .init(prompt: 0.0000277777777778, completion: 0, transcription: true),
        "google/gemini-3.1-flash-lite": .init(prompt: 0.00000025, completion: 0.0000015),
        "openai/gpt-oss-120b": .init(prompt: 0.00000015, completion: 0.0000006),
        "google/gemma-4-31b-it": .init(prompt: 0.0000002, completion: 0.0000004)]
    home.price = { listPrices[$0] }
    home.strictApps = { ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable"] }
    home.todaysCosts = { ("Today $0.014 · 1,234 words spoken", "grok-stt-1.0 $0.012 · gpt-oss-120b $0.0018") }
    home.pricesUpdated = { Date(timeIntervalSince1970: 1_760_745_600) }
    for (tab, name) in [(HomePanel.Page.home, "panel-home"), (.dictionary, "panel-dictionary"),
                        (.takeBacks, "panel-takebacks"), (.settings, "panel-settings"), (.clipboard, "panel-clipboard")] {
        home.select(tab); home.loadDictionary(); home.loadTakeBacks(); home.loadClipboard()
        try save(host, name)
        if tab == .dictionary { #expect(home.quickWordField.visibleRect.height > 0) }
    }
    home.engine.selectItem(at: 3)
    home.aiCleanup.state = .on
    if let index = home.cleanupModel.itemArray.firstIndex(where: {
        $0.representedObject as? String == "nvidia/nemotron-3-super-120b-a12b:free"
    }) { home.cleanupModel.selectItem(at: index) }
    home.select(.settings)
    try save(host, "panel-settings-nemotron")
    // The rest of Settings, scrolled to the bottom.
    home.select(.settings)
    func scrolls(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls) }
    if let scroll = scrolls(host.contentView!).first(where: { !$0.isHiddenOrHasHiddenAncestor && $0.documentView is FlippedView }),
       let document = scroll.documentView {
        document.layoutSubtreeIfNeeded()
        document.scroll(NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentSize.height)))
    }
    try save(host, "panel-settings-lower")
    func sectionControls(_ view: NSView) -> [NSSegmentedControl] {
        if let control = view as? NSSegmentedControl, control.segmentCount == 3 { return [control] }
        return view.subviews.flatMap(sectionControls)
    }
    let sections = try #require(sectionControls(host.contentView!).first)
    sections.selectedSegment = 2
    sections.sendAction(sections.action, to: sections.target)
    try save(host, "panel-settings-general")

    home.setWarning("Grok is off: Mercurius can't read its key, so it's using on-device speech with no cleanup.")
    home.setStatus("Ready · On-device", ok: false)
    home.select(.home); try save(host, "panel-home-warning")
    home.setWarning(nil); home.update(history: [])
    try save(host, "panel-home-empty")
    home.clipboardItems = { [] }; home.loadClipboard(force: true); home.select(.clipboard)
    try save(host, "panel-clipboard-empty")

    // The fn+W review card: reading, ready, a long title with the Markdown view, and a failure.
    let card = ClipCard()
    card.folders = { ["Clips", "Reading", "Work"] }
    card.planned = { title, folder in
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Mercurius Clips/\(ClipsVault.safeFolder(folder))/\(ClipsVault.safeName(title)).md")
    }
    func shoot(_ name: String) throws { card.present(); card.settleForSnapshot(); try save(card.panel, name) }
    var token = card.begin("Reading the Safari page…", site: "Safari")
    try shoot("card-extracting")
    let body = """
    # Ship it Friday

    We ship every **Friday**. The checklist lives in [the docs](https://notes.example.com/docs).

    - Run the tests
    - Tag the release
    - Post the notes

    > Small releases, often, beat big ones.

    ```
    swift test
    ```

    Questions go to the team channel, and the release notes go out on Monday morning.
    """
    let properties: [ClipDraft.Property] = [
        .init(name: "source", kind: .text, value: "https://notes.example.com/ship"),
        .init(name: "author", kind: .list, items: ["Lee Example"]),
        .init(name: "published", kind: .date, value: "2026-10-01"),
        .init(name: "created", kind: .datetime, value: "2026-10-13T09:30:00+11:00"),
        .init(name: "description", kind: .text, value: "How we ship every week without drama."),
        .init(name: "tags", kind: .list, items: ["clippings"])]
    card.offer(ClipDraft(title: "Ship it Friday", properties: properties, body: body), token: token, storeID: nil)
    try shoot("card-ready")
    token = card.begin("Reading the Comet page…", site: "Comet")
    var long = ClipDraft(title: "The surprisingly long history of why koalas sleep twenty hours a day, and what eucalyptus has to do with it (a field guide)",
                         properties: properties, body: body)
    long.originalBytes = 3_400_000
    card.offer(long, token: token, storeID: nil)
    card.propertiesOpen = false
    card.load(long, savedAt: nil, folder: "Reading", storeID: nil)
    try shoot("card-long-title")
    card.propertiesOpen = true
    // Taller than any screen: the content scrolls and Save stays in view.
    token = card.begin("Reading the Safari page…", site: "Safari")
    card.offer(ClipDraft(title: String(repeating: "A title that keeps on going ", count: 12),
                         properties: properties + (0..<30).map { .init(name: "field\($0)", kind: .text, value: "value \($0)") },
                         body: body), token: token, storeID: nil)
    try shoot("card-overlong")
    // A thin Google Docs read: the draft loads with the hint on show.
    token = card.begin("Reading the Chrome page…", site: "Google Chrome")
    card.offer(ClipDraft(title: "Q3 board update", properties: [.init(name: "source", kind: .text, value: "https://docs.google.com/document/d/x/edit")],
                         body: "File Edit View Insert Format Tools"), token: token, storeID: nil, notice: GoogleDocs.hint)
    try shoot("card-docs-notice")
    token = card.begin("Reading the Chrome page…", site: "Google Chrome")
    card.fail("Couldn't read this Google Chrome page. Check Mercurius is on in System Settings › Privacy & Security › Accessibility.", token: token)
    try shoot("card-error")
    card.panel.orderOut(nil)
    // Koa's frames, from the repository (the test runner has no app bundle).
    await KoaFrames.shared.load(from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Koa"))
    // Koa over time, left to right: popping in, listening quietly, talking loudly (squashed, glowing),
    // thinking, then happy and oops.
    let beats: [(mood: KoaDirector.Mood?, level: Float, at: TimeInterval)] =
        [(nil, 0, 0.15), (.listening, 0.01, 1.0), (.listening, 0.6, 1.3), (.listening, 0.9, 1.45),
         (.thinking, 0, 2.2), (.thinking, 0, 2.9), (.happy, 0, 4.4), (.oops, 0, 4.4)]
    let strip = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 96 * beats.count, height: 104), styleMask: [.borderless],
                         backing: .buffered, defer: false)
    strip.backgroundColor = NSColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 1)
    for (index, beat) in beats.enumerated() {
        let view = KoaView(frame: NSRect(x: 96 * CGFloat(index) + 10, y: 14, width: 76, height: 76))
        view.reduceMotion = { false }
        strip.contentView?.addSubview(view)
        view.begin(now: 0)
        if let mood = beat.mood { view.set(mood, now: mood == .happy || mood == .oops ? 4 : mood == .thinking ? 2 : 0.6) }
        for _ in 0..<20 { view.hear(beat.level, now: beat.at) }
        view.layoutSubtreeIfNeeded(); view.advance(now: beat.at)
    }
    try save(strip, "koa-strip")
    let pill = RecordingPill()
    pill.engine = "Grok + cleanup"
    for (name, state) in [("pill-listening", PillContent.listening), ("pill-transcribing", .transcribing),
                          ("pill-pasted", .done("Hey Casey, I'll meet you at 6pm")), ("pill-copied", .done("Copied, no text field — ⌘V to paste")),
                          ("pill-error", .failed("Grok isn't set up and on-device speech isn't ready"))] {
        pill.show(state, now: 0)
        if state == .listening { for level: Float in [0.2, 0.5, 0.9, 0.6, 0.3, 0.7, 0.4, 0.8, 0.5] { pill.level(level) } }
        pill.settleForSnapshot(); pill.panel.alphaValue = 1
        try save(pill.panel, name)
    }
    pill.hide()
    pill.show(.listening, now: 0)
    for step in 0..<26 { pill.level(Float(0.03 + 0.22 * abs(sin(Double(step) * 0.7)) * Double(step) / 26)) }
    pill.settleForSnapshot(); pill.panel.alphaValue = 1
    pill.preview(settled: "umm Casey, I'll meet you at 5pm,", volatile: "no 6pm")
    pill.settleForSnapshot(); try save(pill.panel, "pill-live")
    pill.preview(settled: "So I was thinking we should book a meeting for Friday with the whole team, and then after that we can go through the launch checklist together, look at the open bugs, decide who owns the release notes, and maybe grab lunch near the office if everyone is free. No wait, wait,", volatile: "how about we book it for Saturday")
    pill.settleForSnapshot(); try save(pill.panel, "pill-live-long")
    pill.show(.transcribing, now: 0)
    pill.settleForSnapshot(); try save(pill.panel, "pill-live-finishing")
    pill.show(.delivered(status: "Paste sent · check editor · cleaned", transcript: "Hey Casey, I'll meet you at 6pm by the station."), now: 0)
    pill.settleForSnapshot(); try save(pill.panel, "pill-inserted")
    pill.show(.done("Can you see there's a big spill? Now the box is ultra wide and there's a big black section on the listening and transcribing section."), now: 0)
    pill.settleForSnapshot(); try save(pill.panel, "pill-done-long")
    pill.show(.listening, now: 0); pill.preview(settled: "Short again", volatile: "")
    pill.settleForSnapshot(); try save(pill.panel, "pill-after-long")
    pill.hide()
    host.orderOut(nil); onboarding.window.orderOut(nil)
    // Particles are drawn by the window server, so the confetti needs a real screen capture
    // (screen-recording permission). Opt in with CURSUS_RENDER_CONFETTI=1.
    guard ProcessInfo.processInfo.environment["CURSUS_RENDER_CONFETTI"] == "1" else { return }
    for (name, state) in [("confetti-done", PillContent.done("Pasted into Notes")),
                          ("confetti-failed", .failed("Grok didn't answer; try again"))] {
        pill.celebration.reduceMotion = { false }
        pill.show(state, now: 0); pill.settleForSnapshot(); pill.panel.alphaValue = 1
        // Replays for a few seconds so an outside screenshot tool can catch it too.
        for _ in 0..<8 {
            let koa = NSPoint(x: pill.celebration.panel.frame.minX + Celebration.origin.x,
                              y: pill.celebration.panel.frame.minY + Celebration.origin.y)
            pill.celebration.play(state == .done("Pasted into Notes") ? .success : .failure, koa: koa)
            try await Task.sleep(for: .seconds(0.6))
        }
        let frame = pill.celebration.panel.frame.union(pill.panel.frame)
        let top = (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-R\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))",
                             URL(fileURLWithPath: dir).appendingPathComponent(name + ".png").path]
        try capture.run(); capture.waitUntilExit()
        pill.hide()
        try await Task.sleep(for: .seconds(1.6))
    }
}
