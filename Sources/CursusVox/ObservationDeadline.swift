import Foundation

struct ObservationDeadline: Sendable {
    static let duration: TimeInterval = 0.2
    let expiresAt: TimeInterval
    init(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        expiresAt = now + Self.duration
    }
    func remaining(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        max(0, min(Self.duration, expiresAt - now))
    }
}
