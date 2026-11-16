import AppKit
import Speech
import Testing
@testable import CursusVox

@MainActor @Test func unavailablePreviewExplainsMissingPermissionAndClearsOnEnd() async {
    let preview = LivePreview(authorization: { .denied })
    var updates = 0
    preview.changed = { updates += 1 }
    _ = preview.begin()
    for _ in 0..<100 where preview.unavailable == nil { await Task.yield() }
    #expect(preview.unavailable == .permission)
    #expect(preview.isEmpty)
    #expect(updates > 0)
    await preview.end().value
    #expect(preview.unavailable == nil)
}

@MainActor @Test func unavailablePreviewShowsAReasonWithoutReplacingHeardWords() {
    _ = NSApplication.shared
    let pill = RecordingPill()
    pill.reduceMotion = { true }
    defer { pill.hide() }
    pill.show(.listening, now: 0)
    pill.preview(settled: "", volatile: "", unavailable: .permission)
    #expect(pill.shownPreview.contains("Speech Recognition"))
    pill.preview(settled: "Synthetic words", volatile: "", unavailable: .recognition)
    #expect(pill.shownPreview.contains("Synthetic words"))
    pill.hide()
    #expect(pill.shownPreview.isEmpty)
    pill.show(.starting, now: 1)
    #expect(pill.shownPreview.isEmpty)
}

@MainActor @Test func repeatingRecordingStateRecoversAnOffscreenPopup() throws {
    _ = NSApplication.shared
    let screens = NSScreen.screens
    try #require(!screens.isEmpty)
    let pill = RecordingPill()
    pill.reduceMotion = { true }
    defer { pill.hide() }
    pill.show(.listening, now: 0)
    pill.panel.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
    pill.show(.listening, now: 0.05)
    #expect(screens.contains { $0.visibleFrame.intersects(pill.panel.frame) })
}
