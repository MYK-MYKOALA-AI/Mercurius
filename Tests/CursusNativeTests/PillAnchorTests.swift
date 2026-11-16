import AppKit
import Testing
@testable import CursusVox

// The popup sits beside the text cursor.
private let area = NSRect(x: 0, y: 30, width: 1440, height: 840)   // visibleFrame: Dock below, menu bar above
private let size = NSSize(width: 380, height: 106)

@Test func withNoCaretThePopupSitsBottomCentre() {
    #expect(RecordingPill.origin(for: size, anchor: nil, area: area) == NSPoint(x: 530, y: 48))
}

@Test func thePopupHangsBelowTheCaretLineWithItsCapsuleFixed() {
    let line = NSRect(x: 700, y: 600, width: 2, height: 18)
    let small = RecordingPill.origin(for: size, anchor: line, area: area)
    #expect(small == NSPoint(x: 511, y: 600 - 10 - RecordingPill.tallest))
    // A taller popup (words, the thought cloud) grows upward: the capsule doesn't move and the top stays clear of the line.
    let tall = NSSize(width: 380, height: RecordingPill.tallest)
    let grown = RecordingPill.origin(for: tall, anchor: line, area: area)
    #expect(grown.y == small.y)
    #expect(grown.y + tall.height <= line.minY)
}

// A caret scrolled out of sight falls back to bottom-centre instead of pushing the popup off-screen.
@Test func aCaretOutOfSightFallsBackToBottomCentre() {
    let offscreen = NSRect(x: 700, y: -400, width: 2, height: 18)
    #expect(RecordingPill.origin(for: size, anchor: offscreen, area: area) == RecordingPill.origin(for: size, anchor: nil, area: area))
    // Partly under the menu bar: the popup still lands inside the visible area.
    let high = RecordingPill.origin(for: size, anchor: NSRect(x: 700, y: 860, width: 2, height: 40), area: area)
    #expect(high.y >= area.minY && high.y + size.height <= area.maxY)
}

@Test func nearTheBottomThePopupSitsAboveTheLine() {
    let line = NSRect(x: 700, y: 150, width: 2, height: 18)
    let origin = RecordingPill.origin(for: size, anchor: line, area: area)
    #expect(origin.y == CGFloat(150 + 18 + 10))
    #expect(origin.y >= line.maxY)
}

@Test func thePopupStaysOnScreenAtTheEdges() {
    let left = RecordingPill.origin(for: size, anchor: NSRect(x: 4, y: 600, width: 2, height: 18), area: area)
    #expect(left.x == 8)
    // The empty room left of the capsule may hang off the screen, so the capsule stays near the caret.
    let slack = RecordingPill.origin(for: size, anchor: NSRect(x: 4, y: 600, width: 2, height: 18), area: area, leftSlack: 100)
    #expect(slack.x == -92)
    let right = RecordingPill.origin(for: size, anchor: NSRect(x: 1436, y: 600, width: 2, height: 18), area: area)
    #expect(right.x + size.width == CGFloat(1440 - 8))
    let top = RecordingPill.origin(for: size, anchor: NSRect(x: 700, y: 80, width: 2, height: 800), area: area)
    #expect(top.y + size.height <= area.maxY)
}

@Test func axRectanglesFlipToCocoa() {
    // AX: 100 pt down from the top of a 900 pt primary display, 18 pt tall.
    #expect(RecordingPill.cocoaRect(fromAX: CGRect(x: 50, y: 100, width: 2, height: 18), primaryTop: 900)
        == NSRect(x: 50, y: 782, width: 2, height: 18))
}

@MainActor @Test func anAnchoredPopupMovesAndHidingForgetsTheCaret() {
    let pill = RecordingPill()
    pill.reduceMotion = { true }
    pill.show(.listening, now: 0)
    let line = NSRect(x: 700, y: 600, width: 2, height: 18)
    pill.anchor = line
    let capsuleBottom = pill.panel.frame.minY + pill.capsuleFrame.minY
    #expect(pill.panel.frame.maxY <= line.minY - RecordingPill.anchorGap)
    // Words appear and the popup grows, but the capsule stays where it was (no jump).
    pill.preview(settled: String(repeating: "more words ", count: 30), volatile: "now")
    #expect(pill.panel.frame.minY + pill.capsuleFrame.minY == capsuleBottom)
    #expect(pill.panel.frame.height <= RecordingPill.tallest)
    #expect(pill.panel.frame.maxY <= line.minY - RecordingPill.anchorGap)
    pill.show(.transcribing, now: 1)
    #expect(pill.panel.frame.minY + pill.capsuleFrame.minY == capsuleBottom)
    #expect(pill.panel.frame.height <= RecordingPill.tallest)
    pill.hide()
    #expect(pill.anchor == nil)
}

@MainActor @Test func thinkingMovesOnlyWithMotion() {
    let pill = RecordingPill()
    pill.reduceMotion = { false }
    pill.show(.listening, now: 0)
    pill.show(.transcribing, now: 1)
    #expect(pill.thinkingCloudVisible && pill.thinkingCloudMoving && pill.shimmering)
    pill.show(.busy("Clipping page…"), now: 2)   // no confetti on screen
    #expect(!pill.thinkingCloudVisible && !pill.shimmering)
    pill.hide()
}
