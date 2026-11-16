import CoreGraphics
import AppKit
import Testing
@testable import CursusVox

@Suite struct ChordTests {
    @Test func fnPlusABareLetterIsAChord() {
        #expect(GlobalKeys.isChord([], fnHeld: true, controlOption: false))
        #expect(!GlobalKeys.isChord(.maskCommand, fnHeld: true, controlOption: false))
        #expect(!GlobalKeys.isChord([], fnHeld: false, controlOption: false))
    }
    @Test func controlOptionPlusALetterIsAChordOnlyWithThatHoldKey() {
        #expect(GlobalKeys.isChord([.maskControl, .maskAlternate], fnHeld: false, controlOption: true))
        #expect(!GlobalKeys.isChord([.maskControl, .maskAlternate], fnHeld: false, controlOption: false))
        // Control alone, Option alone, or with Command/Shift keep their usual meaning.
        #expect(!GlobalKeys.isChord(.maskControl, fnHeld: false, controlOption: true))
        #expect(!GlobalKeys.isChord(.maskAlternate, fnHeld: false, controlOption: true))
        #expect(!GlobalKeys.isChord([.maskControl, .maskAlternate, .maskCommand], fnHeld: false, controlOption: true))
        #expect(!GlobalKeys.isChord([.maskControl, .maskAlternate, .maskShift], fnHeld: false, controlOption: true))
    }
}

@Suite struct ShortcutSafetyTests {
    @Test func fnCannotJoinTheControlOptionChord() {
        #expect(!GlobalKeys.isChord([.maskControl, .maskAlternate], fnHeld: true, controlOption: true))
        #expect(!GlobalKeys.isChord([.maskControl, .maskAlternate, .maskSecondaryFn], fnHeld: false, controlOption: true))
    }
    @Test func mediaEventsDoNotCancelDictation() throws {
        let event = try #require(CGEvent(source: nil))
        let media = try #require(CGEventType(rawValue: UInt32(NSEvent.EventType.systemDefined.rawValue)))
        #expect(GlobalKeys.keyEvent(type: media, event: event) == nil)
        if case .otherKeyDown? = GlobalKeys.keyEvent(type: .keyDown, event: event) {} else { Issue.record("Ordinary key must cancel") }
    }
}
