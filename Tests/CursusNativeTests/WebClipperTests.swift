import Foundation
import ApplicationServices
import Testing
@testable import CursusVox

private let article = """
<!doctype html><html lang="en"><head><title>Ship it Friday | Kora Notes</title>
<meta name="author" content="Example Author"><meta name="description" content="How we ship.">
<meta property="og:site_name" content="Kora Notes"></head>
<body><nav>Home · About · Login</nav><article><h1>Ship it Friday</h1>
<p>We ship every <strong>Friday</strong>. The checklist lives in <a href="/docs/checklist">the docs</a>.</p>
<ul><li>Run the tests</li><li>Tag the release</li></ul><pre><code>swift test</code></pre>
<p>Questions go to the team channel, and the release notes go out on Monday morning.</p></article>
<footer>© 2026 Cookie banner</footer></body></html>
"""

@MainActor @Test func pageBecomesAMarkdownNoteWithFrontmatter() async throws {
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/cursus-clip.js")
    let note = try await WebClipper(script: script).clip(html: article, url: "https://notes.example.com/ship")
    #expect(note.title.contains("Ship it Friday"))
    #expect(note.markdown.hasPrefix("---"))
    #expect(note.markdown.contains("https://notes.example.com/ship"))
    #expect(note.markdown.contains("**Friday**"))
    #expect(note.markdown.contains("[the docs](https://notes.example.com/docs/checklist)"))
    #expect(note.markdown.contains("- Run the tests"))
    #expect(!note.markdown.contains("Cookie banner"))
}

@Test func looseOldNotesExpireButFoldersStay() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Clips"), withIntermediateDirectories: true)
    let old = root.appendingPathComponent("old.md"), fresh = root.appendingPathComponent("fresh.md")
    let kept = root.appendingPathComponent("Clips/kept.md")
    for file in [old, fresh, kept] { try "x".write(to: file, atomically: true, encoding: .utf8) }
    let past = Date().addingTimeInterval(-ClipsVault.lifetime - 60)
    try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: old.path)
    try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: kept.path)
    ClipsVault.purge(in: root)
    #expect(!FileManager.default.fileExists(atPath: old.path))
    #expect(FileManager.default.fileExists(atPath: fresh.path))
    #expect(FileManager.default.fileExists(atPath: kept.path))
}

@Test func purgeNeverRemovesFolders() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("archive.md", isDirectory: true)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("Saved"), withIntermediateDirectories: true)
    try "keep".write(to: folder.appendingPathComponent("Saved/x.md"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ClipsVault.lifetime - 60)],
                                          ofItemAtPath: folder.path)
    ClipsVault.purge(in: root)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Saved/x.md").path))
}

@Test func browserScriptReadsUrlAndPageFromOneTab() throws {
    let chrome = try #require(FrontPage.script(for: "com.google.Chrome"))
    #expect(chrome.contains("set t to active tab of front window"))
    #expect(chrome.contains("URL of t") && chrome.contains("execute t javascript"))
    #expect(FrontPage.script(for: "org.mozilla.firefox") == nil)
    #expect(FrontPage.script(for: "com.evil\" & do shell script \"x") == nil)
}

// A clip that timed out never answers the next one.
@MainActor @Test func aLateClipNeverAnswersTheNextOne() async throws {
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/cursus-clip.js")
    let clipper = WebClipper(script: script)
    await #expect(throws: (any Error).self) { _ = try await clipper.clip(html: "<html><body><p>a</p></body></html>", url: "https://a.example/", timeout: 0.000_1) }
    let note = try await clipper.clip(html: "<html><head><title>Second page</title></head><body><article><p>Second body text that is long enough to keep.</p></article></body></html>",
                                      url: "https://b.example/")
    #expect(note.markdown.contains("https://b.example/"))
}

// fn+W through Accessibility and fn+T: every word read is kept, in a note with the clipper's properties.
@MainActor @Test func screenTextBecomesAFullNote() {
    let seen = ScreenText.Capture(title: "Koala \"facts\" - Wikipedia", url: "https://en.wikipedia.org/wiki/Koala",
                                  blocks: [.heading("Koala"), .line("The koala is an arboreal herbivorous marsupial."), .line("<b>not html</b> & more")])
    #expect(seen.words == 12)
    #expect(seen.text == "# Koala\nThe koala is an arboreal herbivorous marsupial.\n<b>not html</b> & more")
    let note = seen.note(url: seen.url!, now: Date(timeIntervalSince1970: 0))
    #expect(note.markdown.hasPrefix("---\ntitle: \"Koala \\\"facts\\\" - Wikipedia\"\nsource: \"https://en.wikipedia.org/wiki/Koala\"\nsite: \"en.wikipedia.org\"\nclipped: 1970-01-01T00:00:00Z\ntags:\n  - clippings\n---\n"))
    #expect(note.markdown.contains("## Koala\n\nThe koala is an arboreal herbivorous marsupial.\n\n<b>not html</b> & more"))
    #expect(seen.html.contains("<p>&lt;b&gt;not html&lt;/b&gt; &amp; more</p>"))
    #expect(note.title == "Koala \"facts\" - Wikipedia")
}

// Fn+T in a non-browser app: site is the app name, source is app://bundle, headings stay structured.
@MainActor @Test func windowClipNoteUsesAppSiteAndHeadings() {
    #expect(ScreenText.clipSource(url: nil, bundleID: "com.apple.Notes") == "app://com.apple.Notes")
    #expect(ScreenText.clipSource(url: "https://docs.example/x", bundleID: "com.apple.Notes") == "https://docs.example/x")
    let seen = ScreenText.Capture(title: "Shopping list", url: nil,
                                  blocks: [.heading("Groceries"), .line("Milk and eggs"), .heading("Other"), .line("Batteries")])
    let note = seen.note(site: "Notes", bundleID: "com.apple.Notes", now: Date(timeIntervalSince1970: 0))
    #expect(note.markdown.contains("source: \"app://com.apple.Notes\""))
    #expect(note.markdown.contains("site: \"Notes\""))
    #expect(note.markdown.contains("## Groceries\n\nMilk and eggs\n\n## Other\n\nBatteries"))
    let draft = ClipDraft(note: note)
    #expect(draft.title == "Shopping list")
    #expect(draft.site == "Notes")
    #expect(draft.source == "app://com.apple.Notes")
    #expect(draft.body.contains("## Groceries"))
}

// YouTube clips: only real video pages qualify; captions render with timestamps.
@Test func youTubeTranscriptsComeOnlyFromVideoPages() {
    #expect(YouTubeTranscript.videoID("https://www.youtube.com/watch?v=jNQXAC9IVRw&t=4") == "jNQXAC9IVRw")
    #expect(YouTubeTranscript.videoID("https://youtu.be/jNQXAC9IVRw") == "jNQXAC9IVRw")
    #expect(YouTubeTranscript.videoID("https://www.youtube.com/shorts/jNQXAC9IVRw") == "jNQXAC9IVRw")
    #expect(YouTubeTranscript.videoID("https://youtube.com.evil.example/watch?v=jNQXAC9IVRw") == nil)
    #expect(YouTubeTranscript.videoID("https://www.youtube.com/results?search_query=koala") == nil)
    #expect(YouTubeTranscript.videoID("https://www.youtube.com/watch?v=../../etc") == nil)
    let json3 = Data(#"{"events":[{"tStartMs":1200,"segs":[{"utf8":"All right,"},{"utf8":" so here we are"}]},{"tStartMs":5000,"segs":[{"utf8":"\n"}]},{"tStartMs":3725000,"segs":[{"utf8":"the end"}]}]}"#.utf8)
    let lines = YouTubeTranscript.parse(json3: json3)
    #expect(lines == [.init(seconds: 1, text: "All right, so here we are"), .init(seconds: 3725, text: "the end")])
    #expect(YouTubeTranscript.render(lines ?? []) == "[0:01] All right, so here we are\n[1:02:05] the end")
    let root: [String: Any] = ["captions": ["playerCaptionsTracklistRenderer": ["captionTracks": [
        ["languageCode": "de", "baseUrl": "https://www.youtube.com/de"],
        ["languageCode": "en", "kind": "asr", "baseUrl": "https://www.youtube.com/asr"],
        ["languageCode": "en", "baseUrl": "https://www.youtube.com/en"]]]]]
    #expect(YouTubeTranscript.chooseTrack(root) == "https://www.youtube.com/en")
}

// Live check against YouTube (opt-in: CURSUS_LIVE_YOUTUBE=1); never runs in the normal suite.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CURSUS_LIVE_YOUTUBE"] == "1"))
func liveYouTubeTranscript() async {
    for (address, minimum) in [("https://www.youtube.com/watch?v=dQw4w9WgXcQ", 300), ("https://youtu.be/jNQXAC9IVRw", 20)] {
        let fetched = await YouTubeTranscript.fetch(id: YouTubeTranscript.videoID(address) ?? "") ?? []
        let lines = YouTubeTranscript.render(fetched).split(separator: "\n").filter { $0.hasPrefix("[") }
        let words = lines.reduce(0) { $0 + $1.split(separator: " ").count - 1 }
        print("LIVE-YOUTUBE \(address.suffix(11)) lines=\(lines.count) words=\(words)")
        #expect(words >= minimum, "\(address)")
    }
}

// Google Docs: only document pages, and only a menus-sized capture, get the screen-reader hint.
@Test func googleDocsHintOnlyForThinDocsCaptures() {
    #expect(GoogleDocs.isDocument("https://docs.google.com/document/d/abc/edit"))
    #expect(GoogleDocs.isDocument("https://docs.google.com/spreadsheets/d/abc/edit"))
    #expect(!GoogleDocs.isDocument("https://docs.google.com.evil.example/document/d/abc"))
    #expect(!GoogleDocs.isDocument("https://drive.google.com/drive/my-drive"))
    #expect(GoogleDocs.hidesText(url: "https://docs.google.com/document/d/abc/edit", words: 84))
    #expect(!GoogleDocs.hidesText(url: "https://docs.google.com/document/d/abc/edit", words: 900))
    #expect(!GoogleDocs.hidesText(url: "https://example.com/doc", words: 10))
}

@MainActor @Test func converterNetworkIsDeniedByPolicy() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let script = folder.appendingPathComponent("network-probe.js")
    try """
    window.CursusClip = async () => {
      const denied = await new Promise(resolve => {
        addEventListener('securitypolicyviolation', e => resolve(e.effectiveDirective), {once:true});
        fetch('https://network.example.invalid/probe').catch(() => {});
        setTimeout(() => resolve('no enforced policy'), 500);
      });
      return JSON.stringify({noteName:'Probe', title:'Probe', note:denied});
    };
    """.write(to: script, atomically: true, encoding: .utf8)
    let result = try await WebClipper(script: script).clip(html: "synthetic", url: "https://notes.example.invalid/")
    #expect(result.markdown == "connect-src")
}

@MainActor @Test func conversionRejectsOverlapAndCancellationDoesNotPoisonTheNextClip() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let script = folder.appendingPathComponent("delayed.js")
    try """
    window.CursusClip = async (html) => {
      if (html === 'slow') await new Promise(r => setTimeout(r, 300));
      return JSON.stringify({noteName:'Probe', note:html});
    };
    """.write(to: script, atomically: true, encoding: .utf8)
    let clipper = WebClipper(script: script)
    let first = Task { try await clipper.clip(html: "slow", url: "https://notes.example.invalid/") }
    await Task.yield()
    await #expect(throws: (any Error).self) { _ = try await clipper.clip(html: "overlap", url: "https://notes.example.invalid/") }
    first.cancel()
    await #expect(throws: CancellationError.self) { _ = try await first.value }
    let next = try await clipper.clip(html: "next", url: "https://notes.example.invalid/")
    #expect(next.markdown == "next")
}

@Test func captureFocusReturningDoesNotRestoreRevokedAdmission() {
    let permit = EffectPermit(expiresAt: ProcessInfo.processInfo.systemUptime + 60)
    #expect(permit.valid)
    CaptureObservation.observedChange(permit)
    #expect(!permit.valid)
    CaptureObservation.observedChange(permit)
    #expect(!permit.valid)
}

@MainActor @Test func captureLimitsProduceAnActionablePartialResult() {
    var walker = ScreenReader.Walker(deadline: Date().addingTimeInterval(-1))
    walker.walk(AXUIElementCreateApplication(getpid()))
    #expect(walker.partial && walker.blocks.isEmpty)
    let capture = ScreenText.Capture(title: "Fixture", url: "https://notes.example/a", blocks: [.line("Some words")], partial: true)
    #expect(capture.note(url: capture.url!).markdown.contains("Partial capture"))
    let result = Application.captureStatus(words: 2, from: "Fixture", copied: true, copyProblem: nil, kept: capture.text,
                                   whole: capture.text, thin: false, leftBehind: nil, partial: true)
    if case let .failed(message) = result { #expect(message.contains("Partial capture") && message.contains("Copied")) }
    else { Issue.record("Partial capture warning missing") }
}

// WebKit dispatches to its navigation delegate by ObjC selector, so the guard is enforced
// only while the clipper exposes that selector. It did not: a `nonisolated` method whose
// decisionHandler is the SDK's WK_SWIFT_UI_ACTOR closure fails the requirement ("nearly
// matches"), so nothing was registered and the default policy — load the request — applied.
// Declaring it main-actor isolated restores the registration.
@MainActor @Test func theNavigationGuardIsRegisteredOnTheClipper() {
    let clipper = WebClipper()
    #expect(clipper.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")),
            "WebKit calls the guard through this selector; without it nothing is cancelled")
}
