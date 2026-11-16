import Foundation
import CursusCore

@MainActor final class FocusCache {
    private var context = Context(destination: nil)
    private var observedAt: TimeInterval?
    static let lifetime: TimeInterval = 0.3
    func update(_ value: Context, at now: TimeInterval) {
        context = value
        context.clipboardCounter = nil
        observedAt = now
    }
    func invalidate() { context = Context(destination: nil); observedAt = nil }
    func read(at now: TimeInterval, secureInput: Bool) -> Context {
        guard let observedAt, now >= observedAt, now - observedAt <= Self.lifetime else {
            return Context(destination: nil, secureEventInput: secureInput)
        }
        var result = context
        result.secureEventInput = result.secureEventInput || secureInput
        return result
    }
}
