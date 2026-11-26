import AppKit
import CoreGraphics

// Which app the user is actually in when a capture shortcut arrives.
//
// NSWorkspace.shared.frontmostApplication is the obvious choice and the wrong one here: a press
// comes in through the event tap while CursusVox is not the active app, and that property can
// report the app that was front before this one (2026-11-01: Fn+T in Finder was logged as a clip
// of Comet). The topmost ordinary window in the window server's front-to-back list is the app
// whose window is really in front, which is what a clip must pin. NSWorkspace stays the fallback
// for the rare case the list can't be read.
enum FrontApp {
    // `layer == 0` is an app's own window: the Dock, menu bar, floating panels (our card is layer
    // 3) and screen savers all sit above it and are not the app being clipped.
    static func current() -> NSRunningApplication? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return NSWorkspace.shared.frontmostApplication
        }
        for window in windows {
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let owner = window[kCGWindowOwnerPID as String] as? Int,
                  let app = NSRunningApplication(processIdentifier: pid_t(owner)) else { continue }
            return app
        }
        return NSWorkspace.shared.frontmostApplication
    }
}
