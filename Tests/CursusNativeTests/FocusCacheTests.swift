import Foundation
import Testing
import CursusCore
@testable import CursusVox

@MainActor struct FocusCacheTests {
    let field = Destination(process: "owned", window: "window", element: "text",
        classification: .normal, enabled: true, editable: true, route: .qualifiedAX)
    @Test func shortcutCacheNeverRetainsClipboardCounter() {
        let cache = FocusCache()
        cache.update(Context(destination: field, clipboardCounter: 42), at: 10)
        let context = cache.read(at: 10.1, secureInput: false)
        #expect(context.destination == field)
        #expect(context.clipboardCounter == nil)
    }
    @Test func secureInputOverridesRecentNormalField() {
        let cache = FocusCache(); cache.update(Context(destination: field), at: 10)
        #expect(cache.read(at: 10.1, secureInput: true).secure)
    }
    @Test func staleInvalidatedOrBackwardClockCannotAdmitDestination() {
        let cache = FocusCache(); cache.update(Context(destination: field), at: 10)
        #expect(cache.read(at: 11, secureInput: false).destination == nil)
        #expect(cache.read(at: 9, secureInput: false).destination == nil)
        cache.invalidate()
        #expect(cache.read(at: 10.1, secureInput: false).destination == nil)
    }
}
