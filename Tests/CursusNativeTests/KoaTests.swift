import AppKit
import Testing
@testable import CursusVox

private let clipsFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Koa", isDirectory: true)
private let counts: [KoaClip: Int] = [.popIn: 12, .listenCalm: 48, .listenLoud: 48, .think: 48, .happy: 19, .oops: 19, .shrug: 14]

@Test func koaPopsInThenListensAndFollowsTheVoice() {
    var koa = KoaDirector()
    koa.begin(now: 100)
    #expect(koa.frame(now: 100.2) { counts[$0]! } == (.popIn, 4))
    // The pop-in (12 frames, 0.5 s) hands over to the calm loop.
    #expect(koa.frame(now: 100.6) { counts[$0]! }.clip == .listenCalm)
    // Speaking up switches to the lively loop at the same frame, so it doesn't jump.
    let before = koa.frame(now: 101) { counts[$0]! }.index
    for _ in 0..<20 { koa.hear(0.3, now: 101) }
    #expect(koa.frame(now: 101) { counts[$0]! } == (.listenLoud, before))
    // A small dip is not enough to calm down; real quiet is.
    for _ in 0..<3 { koa.hear(0.06, now: 101) }
    #expect(koa.clip == .listenLoud)
    for _ in 0..<30 { koa.hear(0, now: 101) }
    #expect(koa.clip == .listenCalm)
}

@Test func koaThinksInALoopAndHoldsTheLastFrameOfAReaction() {
    var koa = KoaDirector()
    koa.begin(now: 0)
    koa.set(.thinking, now: 1)
    #expect(koa.frame(now: 1 + 49.5 / 24) { counts[$0]! } == (.think, 1))   // loops
    koa.set(.happy, now: 10)
    #expect(koa.frame(now: 30) { counts[$0]! } == (.happy, 18))            // holds
    // The voice never moves Koa off a reaction.
    for _ in 0..<20 { koa.hear(1, now: 30) }
    #expect(koa.clip == .happy)
    // Thinking during the pop-in goes straight to the think loop.
    koa.begin(now: 50); koa.set(.thinking, now: 50.1)
    #expect(koa.frame(now: 50.2) { counts[$0]! }.clip == .think)
}

@Test func koaFinishesSayingTheResultEvenAfterATimerJump() {
    let text = "Hey Casey, I'll meet you at 6pm"
    #expect(RecordingPill.typed(text, elapsed: 0) == "")
    #expect(RecordingPill.typed(text, elapsed: 0.1) == "Hey Ca")
    // The timer stalls, then fires long after: the full text, not a prefix.
    #expect(RecordingPill.typed(text, elapsed: 30) == text)
    #expect(RecordingPill.typed(text, elapsed: Double(text.count) / 60) == text)
    #expect(RecordingPill.typed(text, elapsed: -1) == "")
}

// Through the pill itself: the result starts empty, types forward, and completes after a stall.
@MainActor @Test func pillTypesTheResultThenCompletes() {
    let pill = RecordingPill()
    pill.reduceMotion = { false }
    pill.show(.done("Pasted into Notes"), now: 100)
    #expect(pill.shownResult == "")
    pill.animationFrame(now: 100.125)   // 7.5 characters' worth
    #expect(pill.shownResult == "Pasted ")
    pill.animationFrame(now: 160)
    #expect(pill.shownResult == "Pasted into Notes")
    pill.hide()
}

@Test func everyPillStateHasAKoaMood() {
    #expect(RecordingPill.mood(.starting) == .listening)
    #expect(RecordingPill.mood(.listening) == .listening)
    #expect(RecordingPill.mood(.transcribing) == .thinking)
    #expect(RecordingPill.mood(.busy("Clipping")) == .thinking)
    #expect(RecordingPill.mood(.done("Pasted")) == .happy)
    #expect(RecordingPill.mood(.delivered(status: "Inserted", transcript: "Fresh words")) == .happy)
    #expect(RecordingPill.mood(.failed("Too short; hold Fn while you talk")) == .shrug)
    #expect(RecordingPill.mood(.failed("Couldn't paste — click to copy last, or open Clipboard")) == .oops)
}

// A paste is a quick "✓ Inserted" and gone in about a second; the transcript stays in Activity.
@MainActor @Test func aPasteSaysInsertedWithoutTheTranscriptAndLeavesInASecond() {
    let pill = RecordingPill()
    pill.reduceMotion = { true }
    func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    pill.show(.delivered(status: "Paste sent · check editor · cleaned", transcript: "Fresh words"), now: 100)
    pill.animationFrame(now: 100)
    #expect(pill.content?.isTerminal == true && pill.bubbleFrame.height == 0)
    #expect(pill.shownResult == "✓ Inserted")
    let labels = pill.panel.contentView.map(fields) ?? []
    #expect(!labels.contains { $0.stringValue.contains("Fresh words") })
    pill.tick(now: 100.9)
    #expect(pill.content != nil)
    pill.tick(now: 101.05)
    #expect(pill.content == nil)
}

// A note the user must act on stays readable; plain status notes drop.
@MainActor @Test func aPasteKeepsOnlyNotesThatNeedAction() {
    #expect(RecordingPill.insertedLabel("Inserted").text == "✓ Inserted")
    #expect(RecordingPill.insertedLabel("Paste sent · check editor · on-device · code left as spoken") == ("✓ Inserted", false))
    #expect(RecordingPill.insertedLabel("Paste sent · check editor · not cleaned: out of credit")
        == ("✓ Inserted · not cleaned: out of credit", true))
    let pill = RecordingPill()
    pill.reduceMotion = { true }
    pill.show(.delivered(status: "Paste sent · check editor · not cleaned: out of credit", transcript: "Words"), now: 100)
    pill.tick(now: 101.5)
    #expect(pill.content != nil)
    pill.hide()
}

// The bundled clips decode to the expected frames, with a transparent background.
@Test func koaClipsDecodeWithTransparency() async throws {
    let frames = KoaFrames()
    await frames.load(from: clipsFolder)
    #expect(frames.loaded)
    for clip in KoaClip.allCases {
        let images = frames.images(clip)
        #expect(images.count == counts[clip], "\(clip)")
        let first = try #require(images.first)
        #expect(max(first.width, first.height) == KoaFrames.pixels)
        #expect(first.alphaInfo != .none && first.alphaInfo != .noneSkipFirst && first.alphaInfo != .noneSkipLast)
        // The top-left corner is background, so it must be see-through.
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(first, in: CGRect(x: 0, y: -CGFloat(first.height) + 1, width: CGFloat(first.width), height: CGFloat(first.height)))
        let alpha = try #require(context.data?.assumingMemoryBound(to: UInt8.self))[3]
        #expect(alpha < 10, "\(clip) corner alpha \(alpha)")
    }
}

@MainActor @Test func reduceMotionKeepsKoaStill() async {
    let frames = KoaFrames()
    await frames.load(from: clipsFolder)
    let view = KoaView(frame: NSRect(x: 0, y: 0, width: 58, height: 58), frames: frames)
    view.reduceMotion = { true }
    view.begin(now: 0); view.hear(1, now: 0.1); view.advance(now: 0.3)
    #expect(view.shown?.clip == .listenCalm && view.shown?.index == 0)
    #expect(view.pose == KoaMotion())
    view.reduceMotion = { false }
    view.advance(now: 0.3)
    #expect(view.shown?.clip == .popIn)
}

@Test func koaMotionStaysInsideItsReservedSpaceAndReactionsRest() {
    for mood: KoaDirector.Mood in [.listening, .thinking, .happy, .oops, .shrug] {
        for step in 0...600 {
            let pose = KoaMotion.pose(mood: mood, elapsed: Double(step) / 30, amount: 2)
            #expect(abs(pose.x) <= 3 && pose.y >= 0 && pose.y <= 1.6 && abs(pose.turn) <= 0.018)
            // Four-point inset contains translation plus the rotated corner's displacement.
            #expect(abs(pose.x) + 34 * abs(sin(pose.turn)) < 4)
            if mood == .happy || mood == .oops || mood == .shrug { #expect(pose == KoaMotion()) }
        }
    }
    #expect(KoaMotion.pose(mood: .listening, elapsed: 2, amount: 0) == KoaMotion())
    #expect(KoaMotion.pose(mood: .listening, elapsed: -1, amount: 1) == KoaMotion())
}

@MainActor @Test func pillCelebratesSuccessOnceAndResetsForTheNextActivity() {
    let pill = RecordingPill()
    pill.reduceMotion = { false }
    pill.show(.listening, now: 100)
    pill.show(.done("Pasted"), now: 101)
    #expect(pill.celebration.playCount == 1)
    pill.show(.done("Pasted"), now: 101.1)
    pill.show(.done("Pasted · on-device"), now: 101.2)
    #expect(pill.celebration.playCount == 1)
    pill.show(.listening, now: 102)
    #expect(!pill.celebration.panel.isVisible)
    pill.show(.done("Pasted"), now: 103)
    #expect(pill.celebration.playCount == 2)
    pill.hide()
    // A quick result leaves before its confetti ends; the confetti finishes on its own.
    #expect(pill.celebration.panel.isVisible && !pill.isAnimating)
    pill.celebration.stop()
    pill.animationFrame(now: 104)
    #expect(pill.shownResult.isEmpty)
}

@MainActor @Test func pillPreviewKeepsItsSizeAndMotionPreferenceStopsEffects() {
    let pill = RecordingPill()
    pill.reduceMotion = { false }
    pill.show(.listening, now: 100)
    pill.preview(settled: "Hello", volatile: "")
    let first = pill.bubbleFrame
    pill.preview(settled: String(repeating: "more words ", count: 30), volatile: "now")
    #expect(pill.bubbleFrame == first)
    // Beside Koa, not on top of him: right of his head, above the capsule.
    #expect(pill.bubbleFrame.minX >= pill.capsuleFrame.minX + RecordingPill.koaBeside)
    #expect(pill.bubbleFrame.minY > pill.capsuleFrame.maxY)
    #expect(pill.bubbleFrame.minY < pill.capsuleFrame.maxY + RecordingPill.koaOverflow)
    pill.show(.done("Pasted"), now: 101)
    pill.reduceMotion = { true }
    pill.animationFrame(now: 101)
    #expect(pill.shownResult == "Pasted")
    #expect(!pill.celebration.panel.isVisible)
    #expect(pill.capsuleFrame.width >= RecordingPill.listeningWidth)
    pill.hide()
}

@MainActor @Test func repeatedResultDoesNotExtendItsLifetime() {
    let pill = RecordingPill()
    pill.reduceMotion = { true }
    pill.show(.done("Pasted"), now: 100)
    pill.show(.done("Pasted"), now: 102)
    pill.tick(now: 102.3)
    #expect(pill.content == nil)
    pill.hide()
}

@MainActor @Test func hidingThePanelStopsParticleAndAnimationWork() {
    let pill = RecordingPill()
    pill.reduceMotion = { false }
    pill.show(.done("Pasted"), now: 100)
    pill.panel.orderOut(nil)
    pill.animationFrame(now: 101)
    #expect(!pill.isAnimating && !pill.celebration.panel.isVisible)
    pill.hide()
}

@Test func repeatedThinkingDoesNotRestartTheClip() {
    var director = KoaDirector()
    director.begin(now: 100)
    director.set(.thinking, now: 101)
    director.set(.thinking, now: 102)
    #expect(director.frame(now: 102) { counts[$0]! } == (.think, 24))
}

// A new session right after a result starts fading must not be ordered out by that fade.
@MainActor @Test func pillStartedDuringAFadeStaysOrderedIn() async throws {
    let pill = RecordingPill()
    pill.reduceMotion = { false }
    pill.show(.done("Pasted"), now: 100)
    pill.hide()
    pill.show(.starting, now: 101)
    try await Task.sleep(for: .milliseconds(450))
    #expect(pill.panel.isVisible)
    #expect(pill.panel.alphaValue == 1)
    #expect(pill.content == .starting)
    pill.hide()
}

// Wake, display and Space changes: idle leaves the window list, active stays up with its words.
@MainActor @Test func pillReattachOrdersIdleOutAndKeepsActiveUp() {
    let pill = RecordingPill()
    pill.reduceMotion = { true }
    pill.show(.listening, now: 100)
    pill.preview(settled: "Still talking", volatile: "")
    pill.reattach()
    #expect(pill.panel.isVisible)
    #expect(pill.content == .listening && pill.shownPreview.contains("Still talking"))
    pill.hide()
    pill.reattach()
    #expect(!pill.panel.isVisible && pill.panel.alphaValue == 0)
    pill.show(.starting, now: 101)
    #expect(pill.panel.isVisible)
    pill.hide()
}

// A Space or display change while Koa is still typing a result keeps the label wide enough for all of it.
@MainActor @Test func pillReattachDuringTypedResultKeepsItsFullWidth() {
    let pill = RecordingPill()
    pill.reduceMotion = { false }
    pill.show(.done("Pasted into Notes"), now: 100)
    let full = pill.resultWidth
    #expect(full > 0 && pill.shownResult == "")
    pill.reattach()
    #expect(pill.resultWidth == full)
    pill.hide()
}

@MainActor @Test func panelNeverOrderedInIsNotOnScreen() {
    let pill = RecordingPill()
    #expect(!RecordingPill.isOnScreen(pill.panel))
}
