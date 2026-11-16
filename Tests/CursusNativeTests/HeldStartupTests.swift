import AppKit
import Testing
import CursusCore
@testable import CursusVox

@MainActor @Test func nativeNonDictationKeyDownIsForwardedWithoutPostingEvents() {
    let arrow = CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: true)!
    guard case .otherKeyDown? = GlobalKeys.keyEvent(type: .keyDown, event: arrow) else {
        Issue.record("Navigation must reach controller admission"); return
    }
    #expect(GlobalKeys.keyEvent(type: .keyUp, event: arrow) == nil)
    let space = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true)!
    guard case .spaceDown(repeated: false)? = GlobalKeys.keyEvent(type: .keyDown, event: space) else {
        Issue.record("Space must retain its explicit toggle mapping"); return
    }
}
