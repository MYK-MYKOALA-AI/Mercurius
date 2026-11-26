import AppKit
import Testing
@testable import CursusVox

@MainActor struct PillPresentationTests {
    // Every session shows Koa, the waveform and the live words together while listening.
    @Test func everySessionShowsKoaWaveformAndWords() {
        _ = NSApplication.shared
        let pill = RecordingPill()
        pill.reduceMotion = { true }
        defer { pill.hide() }
        pill.show(.listening, now: 0)
        pill.preview(settled: "Synthetic words", volatile: "continue")
        #expect(pill.mascotVisible)
        #expect(pill.waveformVisible)
        #expect(pill.shownPreview == "Synthetic words continue")
        // On release the words leave and Koa thinks in a cloud instead.
        pill.show(.transcribing, now: 1)
        #expect(pill.mascotVisible)
        #expect(pill.shownPreview.isEmpty && pill.bubbleFrame.height == 0)
        #expect(pill.thinkingCloudVisible)
        #expect(!pill.thinkingCloudMoving && !pill.shimmering)   // Reduce Motion: still
        pill.hide()
        pill.show(.starting, now: 2)
        #expect(pill.mascotVisible)
        #expect(pill.shownPreview.isEmpty)
    }
}
