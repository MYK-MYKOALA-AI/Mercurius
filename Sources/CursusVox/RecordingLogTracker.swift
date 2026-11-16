// Decides when each recording gets its one delivery-log line, independent of
// what the pill managed to show: a recording is logged when it settles, or when
// the next one starts first (including one that fails before any refresh).
struct RecordingLogTracker {
    private var current: UInt64?
    private var logged: UInt64?

    // A recording started; returns the previous one if it still needs logging.
    mutating func started(_ generation: UInt64) -> UInt64? {
        defer { current = generation }
        guard let previous = current, previous != generation, previous != logged else { return nil }
        logged = previous
        return previous
    }
    // Dictation is idle again; returns the current recording if not yet logged.
    mutating func settled() -> UInt64? {
        guard let current, current != logged else { return nil }
        logged = current
        return current
    }
}
