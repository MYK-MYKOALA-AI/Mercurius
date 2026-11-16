import Foundation
import Testing
@testable import CursusCore

@MainActor private final class RecoveryClock: PolicyClock { var now: TimeInterval = 0 }
@MainActor struct RecoveryOfferTests {
    @Test func recoveredTextNeedsExplicitActionAndExpires() {
        let clock = RecoveryClock(); let policy = Policy(clock: clock)
        #expect(policy.offerRecovery("owned fixture",expectedGeneration: 0))
        #expect(policy.drainActions().allSatisfy { if case .commitReady = $0 { return false }; return true })
        #expect(policy.request(.copy,context: Context(destination: nil,secureEventInput: true)) == nil)
        clock.now = 600; #expect(policy.recovery == nil)
    }
    @Test func staleRetryCannotReplaceNewSession() {
        let clock = RecoveryClock(); let policy = Policy(clock: clock)
        #expect(!policy.offerRecovery("stale",expectedGeneration: 1))
        #expect(!policy.offerRecovery("",expectedGeneration: 0))
        #expect(!policy.offerRecovery(String(repeating: "a",count: Policy.textLimit+1),expectedGeneration: 0))
    }
}

@MainActor @Test func lateRecoveryOfferKeepsItsOriginalExpiry() {
    let clock = RecoveryClock(); let policy = Policy(clock: clock)
    #expect(policy.offerRecovery("owned fixture", expectedGeneration: 0, age: 599))
    clock.now = 1
    #expect(policy.recovery == nil)
    #expect(!policy.offerRecovery("expired", expectedGeneration: 0, age: 600))
    #expect(!policy.offerRecovery("invalid", expectedGeneration: 0, age: .nan))
}

@MainActor @Test func explicitRecoveryPasteCannotMoveToAnotherFieldOrSelection() throws {
    let clock = RecoveryClock(); let policy = Policy(clock: clock)
    let target = Destination(process: "fixture", window: "window", element: "field", classification: .normal,
        enabled: true, editable: true, route: .qualifiedAX)
    #expect(policy.offerRecovery("owned fixture", expectedGeneration: 0))
    let token = try #require(policy.request(.paste, context: Context(destination: target), expectedDestination: target))
    var changed = target; changed.element = "other-field"
    var calls = 0
    let result = policy.commit(token, context: Context(destination: changed)) { _ in calls += 1; return .axConfirmed }
    #expect(result == nil); #expect(calls == 0)
    let good = try #require(policy.request(.paste, context: Context(destination: target), expectedDestination: target))
    let sent = policy.commit(good, context: Context(destination: target)) { _ in calls += 1; return .axConfirmed }
    #expect(sent != nil); #expect(calls == 1)
}

@MainActor @Test func eachRecoveryOfferHasItsOwnDeliveryIdentity() {
    let policy = Policy(clock: RecoveryClock())
    #expect(policy.offerRecovery("first", expectedGeneration: 0))
    let first = policy.generation
    #expect(policy.offerRecovery("second", expectedGeneration: first))
    #expect(policy.generation != first)
    #expect(policy.recovery?.generation == policy.generation)
    #expect(policy.lastOutcomes == [.recognized]); #expect(policy.lastSubmittedOutcome == nil)
}

@MainActor @Test func secureRecoveryRefusalReportsItsIdentityWithoutKeepingText() {
    let policy = Policy(clock: RecoveryClock())
    #expect(policy.offerRecovery("synthetic text", expectedGeneration: 0))
    let generation = policy.generation
    _ = policy.drainActions()
    #expect(policy.request(.copy, context: Context(destination: nil, secureEventInput: true)) == nil)
    #expect(policy.recovery == nil)
    #expect(policy.drainActions().contains(.outcome(generation, .deliveryBlocked)))
}
@MainActor @Test func offeringExistingTextDoesNotAnnounceAnotherTranscription() {
    let policy = Policy(clock: RecoveryClock())
    #expect(policy.offerRecovery("existing text", expectedGeneration: 0))
    #expect(!policy.drainActions().contains { if case .outcome(_, .recognized) = $0 { return true }; return false })
}

@MainActor @Test func secureObservationReportsQueuedManualRecoveryRefusal() throws {
    for observeFirst in [false, true] {
        let policy = Policy(clock: RecoveryClock())
        #expect(policy.offerRecovery("synthetic text", expectedGeneration: 0))
        let generation = policy.generation
        let token = try #require(policy.request(.copy, context: Context(destination: nil)))
        _ = policy.drainActions()
        let secure = Context(destination: nil, secureEventInput: true)
        if observeFirst { policy.send(.observed(secure)) }
        var calls = 0
        let effect = policy.commit(token, context: secure) { _ in calls += 1; return .copied(attributableCounter: 1) }
        #expect(effect == nil && calls == 0 && policy.recovery == nil)
        #expect(policy.drainActions().contains(.outcome(generation, .deliveryBlocked)))
    }
}

private actor RecoveryFailureGate {
    var entered = false, released = false
    let result: EffectResult
    init(result: EffectResult = .failed("synthetic secure refusal")) { self.result = result }
    func submit() async -> EffectResult {
        entered = true
        while !released { await Task.yield() }
        return result
    }
    func wait() async { while !entered { await Task.yield() } }
    func release() { released = true }
}
@MainActor @Test func failedInFlightRecoveryReportsItsOwnOutcomeAfterSecureCancellation() async throws {
    let policy = Policy(clock: RecoveryClock())
    #expect(policy.offerRecovery("old text", expectedGeneration: 0))
    let old = policy.generation, context = Context(destination: nil)
    let token = try #require(policy.request(.copy, context: context))
    let gate = RecoveryFailureGate()
    let task = Task { await policy.commitAsync(token, context: context) { _ in await gate.submit() } }
    await gate.wait()
    policy.send(.observed(Context(destination: nil, secureEventInput: true)))
    #expect(policy.recovery == nil)
    #expect(policy.offerRecovery("new text", expectedGeneration: policy.generation))
    _ = policy.drainActions()
    await gate.release(); _ = await task.value
    #expect(policy.drainActions().contains(.outcome(old, .deliveryBlocked)))
    #expect(policy.recovery?.text == "new text")
    #expect(policy.lastOutcomes == [.recognized]); #expect(policy.lastSubmittedOutcome == nil)
}

@MainActor @Test func selectedDestinationRefusalReportsTheBoundHistoryIdentity() {
    for secure in [false, true] {
        let policy = Policy(clock: RecoveryClock())
        #expect(policy.offerRecovery("synthetic text", expectedGeneration: 0))
        let generation = policy.generation
        _ = policy.drainActions()
        policy.refuseRecovery(expectedGeneration: generation, context: Context(destination: nil, secureEventInput: secure))
        let actions = policy.drainActions()
        #expect(actions.contains(.outcome(generation, .deliveryBlocked)))
        #expect(!actions.contains { if case .commitReady = $0 { return true }; return false })
        if secure { #expect(policy.recovery == nil) }
    }
}

@MainActor @Test func startingRecordingBeforeManualCommitReportsTheOldRefusal() throws {
    let policy = Policy(clock: RecoveryClock()), context = Context(destination: nil)
    #expect(policy.offerRecovery("synthetic text", expectedGeneration: 0))
    let old = policy.generation
    let token = try #require(policy.request(.copy, context: context))
    #expect(policy.start(context: context))
    _ = policy.drainActions()
    var calls = 0
    let result = policy.commit(token, context: context) { _ in calls += 1; return .copied(attributableCounter: 1) }
    #expect(result == nil && calls == 0)
    #expect(policy.drainActions().contains(.outcome(old, .deliveryBlocked)))
    #expect(policy.isActive)
}

@MainActor @Test func newFinalReportsRefusalBeforeRemovingTheOldManualJob() throws {
    let policy = Policy(clock: RecoveryClock()), context = Context(destination: nil)
    #expect(policy.offerRecovery("old synthetic text", expectedGeneration: 0))
    let old = policy.generation
    let token = try #require(policy.request(.copy, context: context))
    #expect(policy.start(context: context))
    let current = try #require(policy.activeGeneration)
    let ready = Availability(frameworkAvailable: true, localeSupported: true, assetsInstalled: true, microphone: .authorized, speech: .authorized)
    policy.send(.startupCompleted(current, ready, acquiredAdapter: true))
    policy.stop(); _ = policy.drainActions()
    policy.send(.final(current, "new synthetic text"))
    #expect(policy.drainActions().contains(.outcome(old, .deliveryBlocked)))
    var calls = 0
    #expect(policy.commit(token, context: context) { _ in calls += 1; return .copied(attributableCounter: 1) } == nil)
    #expect(calls == 0)
    #expect(policy.recovery?.text == "new synthetic text")
}

@MainActor @Test func successfulLateRecoveryCannotChangeTheNewDecisionMetadata() async throws {
    let policy = Policy(clock: RecoveryClock()), context = Context(destination: nil)
    #expect(policy.offerRecovery("old text", expectedGeneration: 0))
    let old = policy.generation
    let token = try #require(policy.request(.copy, context: context))
    let gate = RecoveryFailureGate(result: .copied(attributableCounter: 1))
    let task = Task { await policy.commitAsync(token, context: context) { _ in await gate.submit() } }
    await gate.wait()
    policy.send(.observed(Context(destination: nil, secureEventInput: true)))
    #expect(policy.offerRecovery("new text", expectedGeneration: policy.generation))
    let current = policy.generation
    _ = policy.drainActions()
    await gate.release(); _ = await task.value
    #expect(policy.drainActions().contains(.outcome(old, .copied)))
    #expect(policy.recovery?.generation == current && policy.recovery?.text == "new text")
    #expect(policy.lastOutcomes == [.recognized])
    #expect(policy.lastSubmittedOutcome == nil)
}

// A recording recovered without its stored settings must never inherit the current engine: that could
// upload audio the user recorded on-device after they switched to a cloud engine (Sol round 2).
@Test func recoveredRecordingRetriesPrivatelyAndNeedsOptInForTheCurrentEngine() {
    let cloud = RecoveryConfiguration(engine: .cloud, speechModel: "openai/whisper", cleanupEnabled: true)
    let stored = RecoveryConfiguration(engine: .local, speechModel: "apple-speech")
    let recovered = RecoveryConfiguration.retryConfiguration(stored: nil, current: cloud, useCurrent: false)
    #expect(recovered.engine == .local)
    #expect(recovered.cleanupEnabled == false)
    #expect(RecoveryConfiguration.retryConfiguration(stored: stored, current: cloud, useCurrent: false) == stored)
    #expect(RecoveryConfiguration.retryConfiguration(stored: nil, current: cloud, useCurrent: true) == cloud)
}
