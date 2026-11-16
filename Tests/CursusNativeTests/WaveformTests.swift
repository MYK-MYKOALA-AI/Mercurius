import AppKit
import Testing
@testable import CursusVox

@MainActor struct WaveformTests {
    @Test func levelsAndTheProcessingWaveStayBetweenFloorAndFull() {
        #expect(Waveform.level(0) == 0.05)
        #expect(Waveform.level(-1) == 0.05)
        #expect(Waveform.level(4) == 1)
        let wave = Waveform.processingBars(count: 29, time: 3.7)
        #expect(wave.count == 29)
        #expect(wave.allSatisfy { $0 >= 0.05 && $0 <= 1 })
    }

    @Test func historyNeverOutgrowsTheBarsThatFitAndEntersOnTheRight() {
        let wave = Waveform(frame: NSRect(x: 0, y: 0, width: 116, height: 22))
        #expect(wave.barCount == 29)
        for _ in 0..<200 { wave.push(0.3) }
        let (values, start) = wave.bars()
        #expect(values.count == 29)
        #expect(start + CGFloat(values.count) * 4 - 1 == 116)
        wave.reset()
        wave.push(0.3)
        #expect(wave.bars().values.count == 1)
    }

    @Test func edgesFadeOutAndTheMiddleStaysSolid() {
        #expect(Waveform.fade(x: 0, width: 116) == 0)
        #expect(Waveform.fade(x: 116, width: 116) == 0)
        #expect(Waveform.fade(x: 58, width: 116) == 1)
        #expect(Waveform.fade(x: 12, width: 116) == 0.5)
    }

    @Test func thinkingFillsTheWidthAndGrowsOutOfTheLastBars() {
        let wave = Waveform(frame: NSRect(x: 0, y: 0, width: 116, height: 22))
        for _ in 0..<40 { wave.push(1) }
        wave.settle()
        wave.thinking = true
        let first = wave.bars()
        #expect(first.values.count == 29)
        #expect(first.start == 0)
        #expect(first.values.allSatisfy { $0 == 1 })
        for _ in 0..<30 { wave.frame() }
        let rolled = wave.bars().values, expected = Waveform.processingBars(count: 29, time: 0.06 * 30)
        #expect(zip(rolled, expected).allSatisfy { abs($0 - $1) < 1e-9 })
    }
}
