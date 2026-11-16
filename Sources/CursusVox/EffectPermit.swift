import Foundation

// Only this state crosses the controller/SDK boundary. No lock is held while
// calling another process. Claim linearizes submission; it cannot undo a post.
final class EffectPermit: @unchecked Sendable {
    private enum State { case available, claimed, revoked }
    private let lock = NSLock()
    private var state = State.available
    let expiresAt: TimeInterval
    init(expiresAt: TimeInterval) { self.expiresAt = expiresAt }
    var valid: Bool {
        lock.lock(); defer { lock.unlock() }
        return state == .available && ProcessInfo.processInfo.systemUptime < expiresAt
    }
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == .available, ProcessInfo.processInfo.systemUptime < expiresAt else { return false }
        state = .claimed; return true
    }
    func revoke() {
        lock.lock(); defer { lock.unlock() }
        if state == .available { state = .revoked }
    }
}
