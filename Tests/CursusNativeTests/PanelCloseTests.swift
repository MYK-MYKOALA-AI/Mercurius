import AppKit
import Testing
@testable import CursusVox

// Settings › Panel: on (the default), the panel closes on any click elsewhere; off, it stays.
@MainActor @Test func panelClosesOnOutsideClicksUnlessPinned() {
    let home = HomePanel()
    home.closesOnOutsideClick.state = .on
    home.applyCloseBehavior()
    #expect(home.popover.behavior == .transient)
    home.closesOnOutsideClick.state = .off
    home.applyCloseBehavior()
    #expect(home.popover.behavior == .applicationDefined)
    #expect(!home.watchingOutsideClicks)   // nothing is watched while the panel is closed
}

// Flipping the switch while the panel is open adds or removes the monitor at once (on, off, on).
@MainActor @Test func outsideClickMonitorFollowsTheSwitchWhileOpen() {
    let home = HomePanel()
    home.closesOnOutsideClick.state = .on
    home.syncOutsideClicks(shown: true)
    #expect(home.watchingOutsideClicks)
    home.closesOnOutsideClick.state = .off
    home.syncOutsideClicks(shown: true)
    #expect(!home.watchingOutsideClicks)
    home.closesOnOutsideClick.state = .on
    home.syncOutsideClicks(shown: true)
    #expect(home.watchingOutsideClicks)
    home.syncOutsideClicks(shown: false)   // closed: nothing watched
    #expect(!home.watchingOutsideClicks)
}
