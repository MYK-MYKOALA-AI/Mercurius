import Foundation

// Blocking Accessibility IPC uses one serial queue, never the main executor or
// an unbounded set of detached operations.
final class AXExecutor: SerialExecutor {
    private let queue = DispatchQueue(label: "au.com.mykoala.mercurius.accessibility", qos: .userInitiated)
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}

final class FocusNotifications: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    private var scheduled = false
    func set(_ value: (@Sendable () -> Void)?) {
        lock.lock(); callback = value; lock.unlock()
    }
    func notify() {
        lock.lock()
        guard callback != nil, !scheduled else { lock.unlock(); return }
        scheduled = true; lock.unlock()
        DispatchQueue.main.async { [self] in
            lock.lock(); let action = callback; scheduled = false; lock.unlock()
            action?()
        }
    }
}
