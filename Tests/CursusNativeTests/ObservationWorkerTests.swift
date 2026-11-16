import Foundation
import Testing
import CursusCore
@testable import CursusVox

private final class SlowObservation: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var main = false
    private var timedOut = false
    func read(_ deadline: ObservationDeadline) -> Context {
        lock.lock(); main = Thread.isMainThread; lock.unlock()
        // This owned callback can release the worker only if the main run loop
        // remains free. No native target, field, keyboard or clipboard is touched.
        DispatchQueue.main.async { self.release.signal() }
        let status = release.wait(timeout: .now() + 0.15)
        lock.lock(); timedOut = status == .timedOut; lock.unlock()
        return Context(destination: nil)
    }
    var result: (onMain: Bool, timedOut: Bool) {
        lock.lock(); defer { lock.unlock() }; return (main, timedOut)
    }
}

// Tests that need the main run loop to answer within 150 ms, and tests that hold it for longer
// (building Home's panel), run one at a time so one never fails because of the other.
@Suite(.serialized) struct MainRunLoop {}

extension MainRunLoop {
@MainActor @Test func slowObservationDoesNotBlockMainRunLoopCallbacks() async {
    let probe = SlowObservation()
    let native = NativeContext(observation: { probe.read($0) })
    _ = await native.snapshot()
    #expect(!probe.result.onMain)
    #expect(!probe.result.timedOut)
    await native.close()
}
}

@Test func lateObservationCannotQualifyDestination() async {
    let native = NativeContext(observation: { _ in
        Thread.sleep(forTimeInterval: 0.22)
        return Context(destination: Destination(process: "fixture", window: "window", element: "field",
            classification: .normal, enabled: true, editable: true, route: .qualifiedAX))
    })
    let result = await native.snapshot()
    #expect(result.destination == nil)
    await native.close()
}
