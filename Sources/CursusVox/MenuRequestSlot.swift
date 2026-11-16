// One Copy last / Paste last request at a time. Reserved on the main actor
// before the request suspends, released when it has been queued or abandoned.
@MainActor final class MenuRequestSlot {
    private var busy = false
    func reserve() -> Bool {
        guard !busy else { return false }
        busy = true
        return true
    }
    func release() { busy = false }
}
