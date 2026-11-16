import AppKit
import Testing
@testable import CursusVox

// Speech languages… opened a window while the Home panel closed; handing focus back to the
// previous app then buried that window, which looked like a crash.
@MainActor @Test func anOpenTitledWindowKeepsFocusWithCursusVox() {
    _ = NSApplication.shared
    let feature = FeatureWindow(title: "Speech languages")
    let untitled = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    defer { feature.window.orderOut(nil); untitled.orderOut(nil) }
    untitled.orderFrontRegardless()
    // Only untitled panels (the pill, confetti) on screen: closing Home still hands focus back.
    #expect(Application.mayHandBackFocus(stillOurs: true, windows: [feature.window, untitled]))
    feature.window.orderFrontRegardless()
    #expect(!Application.mayHandBackFocus(stillOurs: true, windows: [feature.window, untitled]))
    // Focus already left for another app: nothing to hand back either way.
    feature.window.orderOut(nil)
    #expect(!Application.mayHandBackFocus(stillOurs: false, windows: [feature.window, untitled]))
}
