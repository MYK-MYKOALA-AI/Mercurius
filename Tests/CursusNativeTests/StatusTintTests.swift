import AppKit
import Testing
@testable import CursusVox

@MainActor private final class TintCountingButton: NSButton {
    var tintWrites = 0
    override var contentTintColor: NSColor? {
        get { super.contentTintColor }
        set { tintWrites += 1; super.contentTintColor = newValue }
    }
}

@MainActor @Test func repeatedPollsOnlyInvalidateStatusTintOnTransitions() {
    _ = NSApplication.shared
    let button = TintCountingButton()
    button.contentTintColor = nil
    button.tintWrites = 0
    // Two refreshes per 50 ms poll, for ten minutes in each state.
    for _ in 0..<24_000 { Application.updateStatusTint(button, recording: false) }
    #expect(button.tintWrites == 0)
    for _ in 0..<24_000 { Application.updateStatusTint(button, recording: true) }
    #expect(button.tintWrites == 1)
    #expect(button.contentTintColor == .systemRed)
    for _ in 0..<24_000 { Application.updateStatusTint(button, recording: false) }
    #expect(button.tintWrites == 2)
    #expect(button.contentTintColor == nil)
    Application.updateStatusTint(nil, recording: true)
}
