import AppKit
import Testing
@testable import CursusVox

@Test func aResultGetsThreeColorsOfConfettiAndAFailureOneGreyPuff() {
    let success = Celebration.cells(for: .success)
    #expect(success.count == 3)
    #expect(success.allSatisfy { $0.contents != nil && $0.birthRate > 0 && $0.yAcceleration < 0 })
    let failure = Celebration.cells(for: .failure)
    #expect(failure.count == 1)
    #expect(failure[0].velocity < success[0].velocity)   // a puff, not a burst
    #expect(Celebration.piece != nil && Celebration.dot != nil)
}

@MainActor @Test func reduceMotionPlaysNothingAndThePanelNeverTakesClicks() {
    let celebration = Celebration()
    #expect(celebration.panel.ignoresMouseEvents)
    #expect(!celebration.panel.canBecomeKey)
    celebration.reduceMotion = { true }
    #expect(!celebration.play(.success, koa: NSPoint(x: 400, y: 100)))
    #expect(!celebration.panel.isVisible)
}

@MainActor @Test func theBurstHasASlowerFloatingLayer() {
    let floaters = Celebration.floaters()
    let fast = Celebration.cells(for: .success)
    #expect(floaters.count == 3)
    #expect(floaters.allSatisfy { $0.contents != nil && $0.lifetime > fast[0].lifetime && $0.spin < fast[0].spin })
    #expect(floaters.allSatisfy { Double($0.lifetime + $0.lifetimeRange) <= Celebration.duration })
    #expect(Celebration.extraCells(for: .failure).isEmpty)
}

// A punchy pop that ends with the popup, with a shockwave ring and sparkles.
@MainActor @Test func theBurstIsShortAndEndsWithThePopup() {
    #expect(Celebration.duration <= 1.4 && Celebration.burst <= 0.1)
    let cells = Celebration.cells(for: .success) + Celebration.extraCells(for: .success)
    #expect(cells.allSatisfy { Double($0.lifetime + $0.lifetimeRange) <= Celebration.duration })
    let sparkle = Celebration.sparkle()
    #expect(sparkle.scaleSpeed > 0 && sparkle.alphaSpeed < -1)   // swells and blinks out
    #expect(Celebration.extraCells(for: .success).count == 7)   // floaters, sparkles, stars, leaves, ribbons
}

@MainActor @Test func theShockwaveOnlyPlaysForAResult() {
    let celebration = Celebration()
    defer { celebration.stop() }
    celebration.reduceMotion = { false }
    celebration.play(.failure, koa: NSPoint(x: 400, y: 100))
    #expect(celebration.ring.animation(forKey: "shockwave") == nil)
    celebration.play(.success, koa: NSPoint(x: 400, y: 100))
    #expect(celebration.ring.animation(forKey: "shockwave") != nil)
    // "the confetti isn't stopping": the pour is a timed Core Animation burst over a
    // zero model rate, so it ends without the main actor (it used to wait for a Task).
    #expect(celebration.burstLength == Celebration.burst)
    celebration.stop()
    #expect(!celebration.pouring)
    #expect(celebration.ring.animation(forKey: "shockwave") == nil)
}
