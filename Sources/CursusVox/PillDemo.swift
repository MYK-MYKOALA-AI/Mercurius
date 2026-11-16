import AppKit

// `--demo-pill`: plays the pill on screen with made-up words (no microphone, no
// dictation, nothing pasted), a result with its confetti and a failure with its
// puff, then quits. For checking the look on a real display.
@MainActor enum PillDemo {
    static func run() async {
        // Koa's frames load at launch in the app; the demo needs them too.
        await Task.detached(priority: .userInitiated) { await KoaFrames.shared.load() }.value
        let pill = RecordingPill()
        pill.applyAppearance()
        func at() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        for round in 0..<2 {
            pill.show(.starting, now: at())
            pill.show(.listening, now: at())
            let words = ["Hey Casey,", "I'll meet you", "at 5pm,", "no wait,", "6pm"]
            var settled = ""
            for (index, word) in words.enumerated() {
                for step in 0..<12 {
                    pill.level(Float(0.15 + 0.5 * abs(sin(Double(index * 12 + step) * 0.6))))
                    await wait(0.05)
                }
                pill.preview(settled: settled, volatile: word)
                settled += (settled.isEmpty ? "" : " ") + word
            }
            await wait(0.8)
            pill.show(.transcribing, now: at())
            await wait(1.4)
            pill.show(round == 0 ? .done("Pasted into Notes") : .failed("Grok didn't answer. Try again"), now: at())
            await wait(3.2)
            pill.hide()
            await wait(0.8)
        }
    }
}
