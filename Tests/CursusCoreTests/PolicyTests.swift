import Foundation
import Testing
@testable import CursusCore

@MainActor private final class FakeClock: PolicyClock { var now: TimeInterval = 0 }
@MainActor private struct Harness {
    let clock = FakeClock()
    let policy: Policy
    let normal = Destination(process: "owned-process", window: "window-A", element: "field-A",
                             classification: .normal, enabled: true, editable: true, route: .qualifiedAX, selection: SelectionAnchor(location: 0, length: 0))
    let ready = Availability(frameworkAvailable: true, localeSupported: true, assetsInstalled: true,
                             microphone: .authorized, speech: .authorized)
    init() {
        policy = Policy(clock: clock)
        policy.setListener(Listener(shortcutsEnabled: true, suppressingTapActive: true,
                                    competingBindingsAcknowledged: true))
        _ = policy.drainActions()
    }
    var context: Context { Context(destination: normal, clipboardCounter: 10) }
    func begin(_ mode: Mode = .toggle, destination: Destination? = nil) -> UInt64 {
        _ = policy.start(mode: mode, context: Context(destination: destination ?? normal, clipboardCounter: 10))
        let id = policy.activeGeneration!
        policy.send(.startClipboardSample(id, 10))
        policy.send(.startupCompleted(id, ready, acquiredAdapter: true))
        return id
    }
    @discardableResult func final(_ text: String = "original words", destination: Destination? = nil) -> UInt64 {
        let id = begin(destination: destination)
        policy.stop()
        policy.send(.final(id, text))
        return id
    }
    func token() -> CommitToken? {
        policy.drainActions().compactMap {
            if case let .commitReady(t) = $0 { return t }
            return nil
        }.last
    }
    @discardableResult func commit(_ token: CommitToken, context: Context? = nil,
                                  result: EffectResult) -> Effect? {
        policy.commit(token, context: context ?? self.context) { _ in result }
    }
}
private func captures(_ actions: [Action]) -> Int {
    actions.filter { if case .captureStarted = $0 { true } else { false } }.count
}
private func closes(_ actions: [Action], _ id: UInt64) -> Bool { actions.contains(.closeAdapters(id)) }
private func effects(_ actions: [Action]) -> [Effect] {
    actions.compactMap { if case let .effect(e) = $0 { e } else { nil } }
}

@MainActor @Test func unconfirmedAXDoesNotClaimReadbackOrRetryInsertion() {
    let h = Harness()
    h.policy.setCopyEnabled(false)
    _ = h.policy.drainActions()
    _ = h.final()
    let copyToken = h.token()!
    #expect(h.commit(copyToken, result: .failed("Copy Off emits no write")) == nil)
    let token = h.token()!
    #expect(h.commit(token, result: .axSent) != nil)
    #expect(h.policy.lastOutcomes == [.recognized, .insertedUnconfirmed])
    #expect(h.commit(token, result: .axConfirmed) == nil)
}

@MainActor @Test func holdReleaseAndDuplicateFlags() {
    let h = Harness()
    #expect(!h.policy.key(.flags(fn: true, control: false, option: false), context: h.context))
    let id = h.policy.activeGeneration!
    h.policy.key(.flags(fn: true, control: false, option: false), context: h.context)
    h.policy.send(.startupCompleted(id, h.ready, acquiredAdapter: true))
    h.clock.now = Policy.minimumHeld
    h.policy.key(.flags(fn: false, control: false, option: false), context: h.context)
    h.policy.key(.flags(fn: false, control: false, option: false), context: h.context)
    let a = h.policy.drainActions()
    #expect(captures(a) == 1)
    #expect(a.filter { if case .finalizeRequested = $0 { true } else { false } }.count == 1)
    #expect(h.policy.state == .finalizing)
}

// The mic starts the moment Fn goes down so the first word isn't clipped. A tap
// shorter than a deliberate hold (Fn used for something else) is discarded, never sent.
@MainActor @Test func shortHeldTapIsDiscardedWithoutTranscribing() {
    let h = Harness()
    h.policy.key(.flags(fn: true, control: false, option: false), context: h.context)
    let id = h.policy.activeGeneration!
    h.policy.send(.startupCompleted(id, h.ready, acquiredAdapter: true))
    #expect(h.policy.state == .recordingHeld)
    h.clock.now = Policy.minimumHeld - 0.01
    h.policy.key(.flags(fn: false, control: false, option: false), context: h.context)
    let a = h.policy.drainActions()
    #expect(!a.contains(.finalizeRequested(id, timed: false)))
    #expect(closes(a, id))
    #expect(h.policy.state == .idle)
    #expect(h.policy.recovery == nil)   // nothing was recorded before it
}

@MainActor @Test func shortHeldTapKeepsTheLastRecoveryForCopyLast() {
    let h = Harness()
    h.final("older words")
    h.policy.commit(h.token()!, context: h.context) { _ in .copied(attributableCounter: nil) }
    h.commit(h.token()!, result: .axConfirmed)
    #expect(h.policy.recovery?.text == "older words")
    h.clock.now = 1
    h.policy.key(.flags(fn: true, control: false, option: false), context: h.context)
    let id = h.policy.activeGeneration!
    h.policy.send(.startupCompleted(id, h.ready, acquiredAdapter: true))
    h.clock.now = 1 + Policy.minimumHeld - 0.01
    h.policy.key(.flags(fn: false, control: false, option: false), context: h.context)
    #expect(h.policy.state == .idle)
    #expect(h.policy.recovery?.text == "older words")
}

@MainActor @Test func releasePendingClosesLateAdapter() {
    let h = Harness()
    h.policy.key(.flags(fn: true, control: false, option: false), context: h.context)
    let id = h.policy.activeGeneration!
    h.policy.key(.flags(fn: false, control: false, option: false), context: h.context)
    h.policy.send(.startupCompleted(id, h.ready, acquiredAdapter: true))
    let a = h.policy.drainActions()
    #expect(captures(a) == 0)
    #expect(closes(a, id))
    #expect(!a.contains(.finalizeRequested(id, timed: false)))
    #expect(h.policy.state == .idle)
}

@MainActor @Test func startupPromotionAndToggleChord() {
    let h = Harness()
    h.policy.key(.flags(fn: true, control: false, option: false), context: h.context)
    let id = h.policy.activeGeneration!
    #expect(h.policy.key(.spaceDown(repeated: false), context: h.context))
    #expect(h.policy.key(.spaceUp, context: h.context))
    h.policy.key(.flags(fn: false, control: false, option: false), context: h.context)
    #expect(h.policy.state == .startingToggle)
    #expect(h.policy.activeGeneration == id)
    h.policy.send(.startupCompleted(id, h.ready, acquiredAdapter: true))
    #expect(h.policy.state == .recordingToggle)
    h.policy.key(.flags(fn: true, control: false, option: false), context: h.context)
    #expect(!h.policy.key(.spaceDown(repeated: true), context: h.context))
    #expect(h.policy.key(.spaceDown(repeated: false), context: h.context))
    #expect(h.policy.key(.spaceUp, context: h.context))
    h.policy.key(.flags(fn: false, control: false, option: false), context: h.context)
    let a = h.policy.drainActions()
    #expect(captures(a) == 1)
    #expect(a.filter { if case .finalizeRequested = $0 { true } else { false } }.count == 1)
}

@MainActor @Test func consumedChordSpaceRepeatsStaySuppressedWithoutRepeatingTransition() {
    let h = Harness()
    h.policy.key(.flags(fn: true, control: false, option: false), context: h.context)
    #expect(h.policy.key(.spaceDown(repeated: false), context: h.context))
    #expect(h.policy.state == .startingToggle)
    #expect(h.policy.key(.spaceDown(repeated: true), context: h.context))
    #expect(h.policy.key(.spaceDown(repeated: true), context: h.context))
    #expect(h.policy.state == .startingToggle)
    #expect(h.policy.key(.spaceUp, context: h.context))
    #expect(!h.policy.key(.spaceDown(repeated: true), context: h.context))
}

@MainActor @Test func recordedPromotionKeepsBuffersAndGeneration() {
    let h = Harness()
    h.policy.key(.flags(fn: true, control: false, option: false), context: h.context)
    let id = h.policy.activeGeneration!
    h.policy.send(.startupCompleted(id, h.ready, acquiredAdapter: true))
    let buffer = h.policy.reserveAudio(bytes: 2048)!
    #expect(h.policy.key(.spaceDown(repeated: false), context: h.context))
    #expect(h.policy.activeGeneration == id)
    #expect(h.policy.queuedAudioBytes == 2048)
    h.policy.releaseAudio(buffer)
    #expect(h.policy.queuedAudioBytes == 0)
    #expect(captures(h.policy.drainActions()) == 1)
}

@MainActor @Test func alternateBindingAndRearm() {
    let h = Harness()
    h.policy.setBinding(.controlOption)
    h.policy.setListener(Listener(shortcutsEnabled: true, suppressingTapActive: true,
                                 competingBindingsAcknowledged: true))
    h.policy.key(.flags(fn: true, control: false, option: false), context: h.context)
    #expect(!h.policy.isActive)
    h.policy.key(.flags(fn: false, control: true, option: false), context: h.context)
    #expect(!h.policy.isActive)
    h.policy.key(.flags(fn: false, control: true, option: true), context: h.context)
    let first = h.policy.activeGeneration!
    h.policy.send(.startupCompleted(first, h.ready, acquiredAdapter: true))
    h.clock.now = Policy.minimumHeld
    h.policy.key(.flags(fn: false, control: false, option: true), context: h.context)
    #expect(h.policy.state == .finalizing)
    h.policy.cancel()
    h.policy.key(.flags(fn: false, control: true, option: true), context: h.context)
    #expect(!h.policy.isActive)
    h.policy.key(.flags(fn: false, control: false, option: false), context: h.context)
    h.policy.key(.flags(fn: false, control: true, option: true), context: h.context)
    let second = h.policy.activeGeneration!
    #expect(second != first)
    #expect(h.policy.key(.spaceDown(repeated: false), context: h.context))
    h.policy.key(.spaceUp, context: h.context)
    h.policy.send(.startupCompleted(second, h.ready, acquiredAdapter: true))
    #expect(h.policy.key(.spaceDown(repeated: false), context: h.context))
    #expect(h.policy.state == .finalizing)
    #expect(Policy.validateBinding("controlOption"))
    #expect(!Policy.validateBinding("command-Q"))
}

@MainActor @Test func busyStartAndChordPassThrough() {
    let h = Harness()
    let id = h.begin()
    h.policy.stop()
    #expect(!h.policy.start(context: h.context))
    h.policy.key(.flags(fn: true, control: false, option: false), context: h.context)
    #expect(!h.policy.key(.spaceDown(repeated: false), context: h.context))
    #expect(!h.policy.key(.spaceUp, context: h.context))
    #expect(h.policy.activeGeneration == id)
    h.policy.send(.final(id, "words"))
    #expect(!h.policy.start(context: h.context))
    #expect(captures(h.policy.drainActions()) == 1)
}

@MainActor @Test func lateFinalCancelAndNewSession() {
    let h = Harness()
    let a = h.begin()
    h.policy.stop(); h.policy.cancel()
    let b = h.begin()
    h.policy.send(.final(a, "stale"))
    #expect(h.policy.recovery == nil)
    h.policy.stop(); h.policy.send(.final(b, "current"))
    #expect(h.policy.recovery?.text == "current")
    #expect(effects(h.policy.drainActions()).isEmpty)
}

@MainActor @Test func cancelBeforeAndBetweenCommits() {
    let h = Harness()
    h.final()
    let copy = h.token()!
    h.policy.cancel()
    var calls = 0
    h.policy.commit(copy, context: h.context) { _ in calls += 1; return .copied(attributableCounter: 11) }
    #expect(calls == 0)
    #expect(h.policy.recovery == nil)
    h.final()
    let nextCopy = h.token()!
    #expect(h.commit(nextCopy, result: .copied(attributableCounter: 11)) != nil)
    let insert = h.token()!
    h.policy.cancel()
    #expect(h.commit(insert, result: .axConfirmed) == nil)
    let a = h.policy.drainActions()
    #expect(effects(a).isEmpty)
    #expect(a.contains { if case let .decision(_, values) = $0 { values.contains(.copied) } else { false } })
    #expect(h.policy.recovery == nil)
}

@MainActor @Test func stopPendingPreservesOlderRecoveryCancelClearsIt() {
    let h = Harness()
    h.final("older")
    h.policy.commit(h.token()!, context: h.context) { _ in .copied(attributableCounter: nil) }
    h.commit(h.token()!, result: .axConfirmed)
    for mode in [Mode.held, .toggle] {
        h.policy.start(mode: mode, context: h.context)
        let id = h.policy.activeGeneration!
        h.policy.stop()
        h.policy.send(.startupCompleted(id, h.ready, acquiredAdapter: true))
        let a = h.policy.drainActions()
        #expect(captures(a) == 0)
        #expect(closes(a, id))
        #expect(h.policy.recovery?.text == "older")
    }
    h.policy.start(context: h.context)
    h.policy.cancel()
    #expect(h.policy.recovery == nil)
}

@MainActor @Test func secondChordStopsPendingToggle() {
    let h = Harness()
    h.policy.key(.flags(fn: true, control: false, option: false), context: h.context)
    let id = h.policy.activeGeneration!
    #expect(h.policy.key(.spaceDown(repeated: false), context: h.context))
    h.policy.key(.spaceUp, context: h.context)
    #expect(h.policy.key(.spaceDown(repeated: false), context: h.context))
    h.policy.send(.startupCompleted(id, h.ready, acquiredAdapter: true))
    let a = h.policy.drainActions()
    #expect(captures(a) == 0)
    #expect(!a.contains(.finalizeRequested(id, timed: false)))
}

@MainActor @Test func silentOversizedPartialAndRecoveryReplacement() {
    let h = Harness()
    h.final("old")
    h.commit(h.token()!, result: .copied(attributableCounter: nil))
    h.commit(h.token()!, result: .axConfirmed)
    _ = h.policy.drainActions()
    let empty = h.begin()
    h.policy.send(.partial(empty, "partial must not deliver"))
    h.policy.stop(); h.policy.send(.final(empty, " \n\t"))
    #expect(h.policy.recovery?.text == "old")
    #expect(effects(h.policy.drainActions()).isEmpty)
    #expect(h.policy.partialText.isEmpty)
    let oversized = h.begin()
    h.policy.stop()
    h.policy.send(.final(oversized, String(repeating: "é", count: Policy.textLimit / 2 + 1)))
    #expect(h.policy.state == .recoverableError)
    #expect(h.policy.recovery?.text == "old")
    #expect(effects(h.policy.drainActions()).isEmpty)
    h.final("new")
    #expect(h.policy.recovery?.text == "new")
}

@MainActor @Test func durationBoundAndHeldRearm() {
    let h = Harness()
    h.policy.key(.flags(fn: true, control: false, option: false), context: h.context)
    let id = h.policy.activeGeneration!
    h.policy.send(.startupCompleted(id, h.ready, acquiredAdapter: true))
    h.clock.now = 60; h.policy.send(.tick); h.policy.send(.tick)
    h.policy.send(.final(id, "complete bounded segment"))
    h.commit(h.token()!, result: .copied(attributableCounter: nil))
    h.commit(h.token()!, result: .axConfirmed)
    #expect(!h.policy.key(.spaceDown(repeated: false), context: h.context))
    h.policy.key(.flags(fn: true, control: false, option: false), context: h.context)
    #expect(!h.policy.isActive)
    h.policy.key(.flags(fn: false, control: false, option: false), context: h.context)
    h.policy.key(.flags(fn: true, control: false, option: false), context: h.context)
    #expect(h.policy.state == .startingHeld)
}

@MainActor @Test func timedStopActionAndWatchdog() {
    let h = Harness()
    let id = h.begin()
    h.clock.now = 60; h.policy.send(.tick)
    #expect(h.policy.drainActions().contains(.finalizeRequested(id, timed: true)))
    h.clock.now = 75; h.policy.send(.tick)
    h.policy.send(.final(id, "late"))
    #expect(h.policy.state == .recoverableError)
    #expect(h.policy.recovery == nil)
    #expect(closes(h.policy.drainActions(), id))
    #expect(h.policy.start(context: h.context))
}

@MainActor @Test func delayedWatchdogTickCannotAdmitLateFinal() {
    let h = Harness()
    let id = h.begin(); h.policy.stop()
    h.clock.now = 15
    h.policy.send(.final(id, "late without tick"))
    #expect(h.policy.state == .recoverableError)
    #expect(h.policy.recovery == nil)
}

@MainActor @Test func aggregateBufferCapAndRelease() {
    let h = Harness()
    let id = h.begin()
    let capture = h.policy.reserveAudio(bytes: Policy.audioLimit / 2)!
    let conversion = h.policy.reserveAudio(bytes: Policy.audioLimit / 2)!
    #expect(h.policy.audioHighWater == Policy.audioLimit)
    #expect(h.policy.reserveAudio(bytes: 1) == nil)
    #expect(h.policy.state == .recoverableError)
    #expect(h.policy.queuedAudioBytes == 0)
    h.policy.releaseAudio(capture); h.policy.releaseAudio(conversion)
    h.policy.send(.final(id, "truncated success forbidden"))
    #expect(h.policy.recovery == nil)
    #expect(closes(h.policy.drainActions(), id))
}

// Sam 2026-10-12: text goes into whatever field is focused when it is ready.
@MainActor @Test func focusSwitchDeliversIntoTheFieldFocusedAtDelivery() {
    let h = Harness()
    let id = h.begin()
    var other = h.normal; other.element = "field-B"
    h.policy.send(.observed(Context(destination: other)))
    h.policy.stop(); h.policy.send(.final(id, "moved words"))
    let now = Context(destination: other, clipboardCounter: 10)
    #expect(h.commit(h.token()!, context: now, result: .copied(attributableCounter: 11)) != nil)
    let insert = h.token()!
    #expect(h.commit(insert, context: now, result: .axConfirmed) == .axInsert(insert, other, "moved words"))
    #expect(h.policy.lastOutcomes == [.recognized, .copied, .insertedConfirmed])
}

@MainActor @Test func ineligibleFocusStillCopiesSoTheUserCanPaste() {
    let h = Harness()
    var finder = h.normal; finder.classification = .custom
    h.final("keep me", destination: finder)
    let ctx = Context(destination: finder, clipboardCounter: 10)
    let copy = h.token()!
    #expect(h.commit(copy, context: ctx, result: .copied(attributableCounter: 11))
            == .clipboardWrite(copy, "keep me", expectedCounter: 10))
    #expect(h.commit(h.token()!, context: ctx, result: .axConfirmed) == nil)
    #expect(h.policy.lastOutcomes == [.recognized, .copied, .deliveryBlocked])
}

@MainActor @Test func clipboardChangedDuringRecordingStillCopiesAgainstTheCurrentCounter() {
    let h = Harness()
    h.final()
    let copy = h.token()!
    #expect(h.policy.needsClipboardCounter(for: copy))
    let changed = Context(destination: h.normal, clipboardCounter: 42)
    #expect(h.commit(copy, context: changed, result: .copied(attributableCounter: 43))
            == .clipboardWrite(copy, "original words", expectedCounter: 42))
}

@MainActor @Test func secureStartAndEveryActivePhase() {
    let h = Harness()
    let secure = Context(destination: h.normal, secureEventInput: true)
    #expect(!h.policy.start(context: secure))
    #expect(!h.policy.drainActions().contains { if case .startupRequested = $0 { true } else { false } })
    for phase in 0...3 {
        h.final("older")
        h.commit(h.token()!, result: .copied(attributableCounter: nil))
        h.commit(h.token()!, result: .axConfirmed)
        _ = h.policy.drainActions()
        h.policy.start(context: h.context)
        let id = h.policy.activeGeneration!
        if phase > 0 { h.policy.send(.startupCompleted(id, h.ready, acquiredAdapter: true)) }
        if phase > 1 { h.policy.stop() }
        if phase > 2 { h.policy.send(.final(id, "pending delivery")) }
        h.policy.send(.observed(secure))
        h.policy.send(.observed(h.context))
        h.policy.send(.startupCompleted(id, h.ready, acquiredAdapter: true))
        h.policy.send(.final(id, "late"))
        #expect(h.policy.recovery == nil)
        #expect(!h.policy.isActive)
        #expect(h.policy.partialText.isEmpty)
        #expect(effects(h.policy.drainActions()).isEmpty)
    }
}

@MainActor @Test func unknownAndDisallowedDestinations() {
    for kind in [Classification.unknown, .terminal, .remote, .elevated, .custom] {
        let h = Harness()
        var target = h.normal; target.classification = kind
        h.final("line one\ncommand text", destination: target)
        let ctx = Context(destination: target, clipboardCounter: 10)
        #expect(h.commit(h.token()!, context: ctx, result: .copied(attributableCounter: 11)) != nil)
        #expect(h.commit(h.token()!, context: ctx, result: .axConfirmed) == nil)
        #expect(h.policy.recovery != nil)
        let paste = h.policy.request(.paste, context: ctx)!
        #expect(h.commit(paste, context: ctx, result: .axConfirmed) == nil)
        let copy = h.policy.request(.copy, context: ctx)!
        #expect(h.commit(copy, context: ctx, result: .copied(attributableCounter: nil)) != nil)
    }
}

@MainActor @Test func readOnlyTargetAndUnknownExplicitCopy() {
    let h = Harness()
    var target = h.normal; target.editable = false
    h.final(destination: target)
    let ctx = Context(destination: target, clipboardCounter: 10)
    #expect(h.commit(h.token()!, context: ctx, result: .copied(attributableCounter: 11)) != nil)
    #expect(h.commit(h.token()!, context: ctx, result: .axConfirmed) == nil)
    let unknown = Context(destination: nil)
    let copy = h.policy.request(.copy, context: unknown)!
    #expect(h.commit(copy, context: unknown, result: .copied(attributableCounter: nil)) != nil)
    #expect(h.policy.drainActions().contains(.status("Explicit Copy: destination classification unavailable")))
    h.policy.setCopyEnabled(false)
    #expect(h.policy.request(.copy, context: unknown) == nil)
}

@MainActor @Test func copyEnabledConfirmedAXAndSingleDecision() {
    let h = Harness()
    let id = h.final()
    let copy = h.token()!
    #expect(h.commit(copy, result: .copied(attributableCounter: 11)) == .clipboardWrite(copy, "original words", expectedCounter: 10))
    #expect(h.commit(copy, result: .copied(attributableCounter: 12)) == nil)
    let insert = h.token()!
    #expect(h.commit(insert, result: .axConfirmed) == .axInsert(insert, h.normal, "original words"))
    #expect(h.policy.lastOutcomes == [.recognized, .copied, .insertedConfirmed])
    let a = h.policy.drainActions()
    #expect(a.filter { if case .decision = $0 { true } else { false } }.count == 1)
    h.policy.send(.final(id, "duplicate final"))
    #expect(h.policy.drainActions().isEmpty)
}

@MainActor @Test func copyOffZeroCounterRequestsAndAXAllowed() {
    let h = Harness()
    h.policy.setCopyEnabled(false)
    h.final()
    let a = h.policy.drainActions()
    #expect(!a.contains { if case .sampleStartClipboard = $0 { true } else { false } })
    let copy = a.compactMap { if case let .commitReady(t) = $0 { t } else { nil } }.last!
    #expect(!h.policy.needsClipboardCounter(for: copy))
    #expect(h.commit(copy, result: .copied(attributableCounter: 11)) == nil)
    let insert = h.token()!
    #expect(!h.policy.needsClipboardCounter(for: insert))
    #expect(h.commit(insert, result: .axConfirmed) != nil)
    #expect(h.policy.request(.copy, context: h.context) == nil)
    let paste = h.policy.request(.paste, context: h.context)!
    #expect(h.commit(paste, result: .axConfirmed) != nil)
}

@MainActor @Test func copySettingTransitions() {
    let h = Harness()
    h.policy.setCopyEnabled(false)
    let id = h.begin()
    h.policy.setCopyEnabled(true)
    h.policy.stop(); h.policy.send(.final(id, "words"))
    let copy = h.token()!
    #expect(h.policy.needsClipboardCounter(for: copy))
    #expect(h.commit(copy, result: .copied(attributableCounter: 11)) != nil)
    h.commit(h.token()!, result: .axConfirmed)
    h.final()
    let next = h.token()!
    h.policy.setCopyEnabled(false)
    #expect(h.commit(next, result: .copied(attributableCounter: 11)) == nil)
    h.commit(h.token()!, result: .axConfirmed)
    h.policy.setCopyEnabled(true)
    h.final()
    h.commit(h.token()!, result: .copied(attributableCounter: 11))
    let insert = h.token()!
    h.policy.setCopyEnabled(false)
    #expect(h.commit(insert, result: .axConfirmed) != nil)
    #expect(h.policy.lastOutcomes.contains(.copied))
}

@MainActor @Test func clipboardRaceOwnershipAndAmbiguousPaste() {
    let h = Harness()
    var browser = h.normal; browser.route = .qualifiedClipboard
    h.final(destination: browser)
    let changed = Context(destination: browser, clipboardCounter: 99)
    #expect(h.commit(h.token()!, context: changed, result: .copied(attributableCounter: 100)) != nil)
    let ownedNow = Context(destination: browser, clipboardCounter: 100)
    let autoPaste = h.token()!
    #expect(h.commit(autoPaste, context: ownedNow, result: .pasteSent) == .pasteKey(autoPaste, browser))
    h.final(destination: browser)
    let original = Context(destination: browser, clipboardCounter: 10)
    h.commit(h.token()!, context: original, result: .copied(attributableCounter: nil))
    #expect(h.commit(h.token()!, context: changed, result: .pasteSent) == nil)
    #expect(h.policy.recovery?.ownedClipboardCounter == nil)
    h.final(destination: browser)
    h.commit(h.token()!, context: original, result: .copied(attributableCounter: 11))
    #expect(h.commit(h.token()!, context: changed, result: .pasteSent) == nil)
    let copy = h.policy.request(.copy, context: changed)!
    h.commit(copy, context: changed, result: .copied(attributableCounter: 100))
    let owned = Context(destination: browser, clipboardCounter: 100)
    let paste = h.policy.request(.paste, context: owned)!
    #expect(h.commit(paste, context: owned, result: .pasteSent) == .pasteKey(paste, browser))
    let a = h.policy.drainActions()
    #expect(a.contains { if case .outcome(_, .pasteSentUnconfirmed) = $0 { true } else { false } })
    #expect(!a.contains { if case .outcome(_, .insertedConfirmed) = $0 { true } else { false } })
    #expect(h.commit(paste, context: owned, result: .pasteSent) == nil)
}

@MainActor @Test func manualPasteFreshTokenAndExpiry() {
    let h = Harness()
    h.policy.setCopyEnabled(false)
    h.final()
    h.commit(h.token()!, result: .failed("unused"))
    h.commit(h.token()!, result: .axConfirmed)
    let first = h.policy.request(.paste, context: h.context)!
    let second = h.policy.request(.paste, context: h.context)!
    #expect(first != second)
    #expect(h.commit(first, result: .axConfirmed) != nil)
    #expect(h.commit(first, result: .axConfirmed) == nil)
    #expect(h.commit(second, result: .axConfirmed) != nil)
    let delayed = h.policy.request(.paste, context: h.context)!
    h.clock.now = 600
    #expect(h.commit(delayed, result: .axConfirmed) == nil)
    #expect(h.policy.recovery == nil)
}

@MainActor @Test func clearSleepLockQuitAndSecureRecovery() {
    for reason in ["sleep", "session lock", "quit", "microphone disconnected", "permission revoked"] {
        let h = Harness()
        let id = h.final()
        let token = h.token()!
        h.policy.send(.interrupted(reason))
        #expect(h.commit(token, result: .copied(attributableCounter: 11)) == nil)
        h.policy.send(.final(id, "late"))
        #expect(h.policy.recovery == nil)
        #expect(closes(h.policy.drainActions(), id))
    }
    let h = Harness()
    h.final(); h.commit(h.token()!, result: .copied(attributableCounter: nil))
    h.commit(h.token()!, result: .axConfirmed)
    let secure = Context(destination: nil, secureEventInput: true)
    #expect(h.policy.request(.copy, context: secure) == nil)
    #expect(h.policy.request(.paste, context: secure) == nil)
    #expect(h.policy.recovery == nil)
    h.policy.send(.observed(h.context))
    #expect(h.policy.recovery == nil)
    h.final(); h.policy.clear()
    #expect(h.policy.recovery == nil)
}

@MainActor @Test func missingBackendAndDeniedPermissions() {
    let h = Harness()
    let values = [
        Availability(frameworkAvailable: false, localeSupported: true, assetsInstalled: true, microphone: .authorized, speech: .authorized),
        Availability(frameworkAvailable: true, localeSupported: false, assetsInstalled: true, microphone: .authorized, speech: .authorized),
        Availability(frameworkAvailable: true, localeSupported: true, assetsInstalled: false, microphone: .authorized, speech: .authorized),
        Availability(frameworkAvailable: true, localeSupported: true, assetsInstalled: true, microphone: .denied, speech: .authorized),
        Availability(frameworkAvailable: true, localeSupported: true, assetsInstalled: true, microphone: .authorized, speech: .denied)
    ]
    for value in values {
        h.policy.start(context: h.context)
        let id = h.policy.activeGeneration!
        h.policy.send(.startupCompleted(id, value, acquiredAdapter: true))
        #expect(h.policy.state == .recoverableError)
        #expect(h.policy.availability == value)
        let a = h.policy.drainActions()
        #expect(captures(a) == 0)
        #expect(closes(a, id))
    }
}

@MainActor @Test func failedAndListenOnlyTapMouseStillWorks() {
    let h = Harness()
    h.policy.setListener(Listener(shortcutsEnabled: true, suppressingTapActive: false,
                                  competingBindingsAcknowledged: true))
    h.policy.key(.flags(fn: true, control: false, option: false), context: h.context)
    #expect(!h.policy.key(.spaceDown(repeated: false), context: h.context))
    #expect(!h.policy.isActive)
    #expect(h.policy.start(context: h.context))
    let id = h.policy.activeGeneration!
    h.policy.send(.startupCompleted(id, h.ready, acquiredAdapter: true))
    h.policy.setListener(Listener())
    #expect(!h.policy.isActive)
    #expect(closes(h.policy.drainActions(), id))
    #expect(h.policy.start(context: h.context))
    h.policy.stop()
    #expect(!h.policy.isActive)
}

@MainActor @Test func escapeEveryPhaseAndRepeatIgnored() {
    for phase in 0...4 {
        let h = Harness()
        h.policy.start(mode: phase == 2 ? .held : .toggle, context: h.context)
        let id = h.policy.activeGeneration!
        if phase > 0 { h.policy.send(.startupCompleted(id, h.ready, acquiredAdapter: true)) }
        if phase > 2 { h.policy.stop() }
        if phase > 3 { h.policy.send(.final(id, "pending")) }
        #expect(!h.policy.key(.escape(repeated: true), context: h.context))
        #expect(h.policy.key(.escape(repeated: false), context: h.context))
        h.policy.send(.final(id, "late"))
        #expect(!h.policy.isActive)
        #expect(h.policy.recovery == nil)
        #expect(closes(h.policy.drainActions(), id))
    }
}

@MainActor @Test func adapterFailureNeverConfirmedAndNoRetry() {
    let h = Harness()
    h.final()
    h.commit(h.token()!, result: .failed("clipboard unavailable"))
    let insert = h.token()!
    h.commit(insert, result: .failed("AX rejected"))
    #expect(h.policy.lastOutcomes == [.recognized, .deliveryBlocked])
    #expect(h.policy.recovery != nil)
    #expect(!h.policy.drainActions().contains { if case .commitReady = $0 { true } else { false } })
    #expect(h.commit(insert, result: .axConfirmed) == nil)
}

@Test func originalQualityScoringIncludesFailures() {
    let references = Quality.referencePhrases.map { Optional($0) }
    let exact = Quality.score(references)
    #expect(exact.referenceWords >= 100)
    #expect(exact.editCount == 0)
    #expect(exact.meetsTarget)
    let missing = Quality.score([])
    #expect(missing.editCount == missing.referenceWords)
    #expect(missing.wer == 1)
    #expect(!missing.meetsTarget)
    #expect(Quality.words("CAFÉ—hello\nworld!") == ["café", "hello", "world"])
    #expect(Quality.words("cafe\u{301}") == ["café"])
    #expect(Quality.edits(reference: ["one", "two"], hypothesis: ["one", "three", "four"]) == 2)
}

@MainActor @Test func clearingPendingDeliveryReleasesTheSession() {
    let h = Harness()
    _ = h.final()
    let oldToken = h.token()!
    #expect(h.policy.state == .delivering)
    h.policy.clear()
    #expect(h.policy.state == .idle)
    #expect(h.policy.activeGeneration == nil)
    #expect(h.policy.recovery == nil)
    #expect(h.commit(oldToken, result: .copied(attributableCounter: 11)) == nil)
    _ = h.begin()
    #expect(h.policy.state == .recordingToggle)
}

@MainActor @Test func expiringPendingDeliveryReleasesTheSession() {
    let h = Harness()
    _ = h.final()
    let oldToken = h.token()!
    h.clock.now = Policy.recoveryLifetime
    h.policy.send(.tick)
    #expect(h.policy.state == .idle)
    #expect(h.policy.activeGeneration == nil)
    #expect(h.policy.recovery == nil)
    #expect(h.commit(oldToken, result: .copied(attributableCounter: 11)) == nil)
}

@MainActor @Test func captureLimitFinalizesOnceAndIgnoresStaleGenerations() {
    let h = Harness()
    let id = h.begin()
    _ = h.policy.drainActions()
    h.policy.send(.captureLimitReached(id &+ 1))
    #expect(h.policy.state == .recordingToggle)
    h.policy.send(.captureLimitReached(id))
    h.policy.send(.captureLimitReached(id))
    #expect(h.policy.state == .finalizing)
    #expect(h.policy.drainActions().filter { $0 == .finalizeRequested(id, timed: true) }.count == 1)
}

@MainActor @Test func stalledStartupTimesOutAndClosesLateAdapter() {
    let h = Harness()
    #expect(h.policy.start(context: h.context))
    let id = h.policy.activeGeneration!
    _ = h.policy.drainActions()
    h.clock.now = 15
    h.policy.send(.tick)
    #expect(h.policy.state == .recoverableError)
    #expect(h.policy.activeGeneration == nil)
    #expect(closes(h.policy.drainActions(), id))
    h.policy.send(.startupCompleted(id, h.ready, acquiredAdapter: true))
    let late = h.policy.drainActions()
    #expect(closes(late, id))
    #expect(captures(late) == 0)
}

@MainActor @Test func delayedStartupCompletionCannotBypassTheDeadline() {
    let h = Harness()
    #expect(h.policy.start(context: h.context))
    let id = h.policy.activeGeneration!
    _ = h.policy.drainActions()
    h.clock.now = Policy.startupLifetime
    h.policy.send(.startupCompleted(id, h.ready, acquiredAdapter: true))
    let actions = h.policy.drainActions()
    #expect(h.policy.state == .recoverableError)
    #expect(captures(actions) == 0)
    #expect(closes(actions, id))
}

@MainActor @Test func changingSelectionInsideTheSameFieldStillDeliversAtTheNewCaret() {
    let h = Harness()
    h.policy.setCopyEnabled(false)
    _ = h.policy.drainActions()
    _ = h.final()
    var moved = h.normal
    moved.selection = SelectionAnchor(location: 5, length: 3)
    let changed = Context(destination: moved)
    #expect(h.commit(h.token()!, context: changed, result: .failed("Copy Off")) == nil)
    let insertion = h.token()!
    var submitted = false
    let effect = h.policy.commit(insertion, context: changed) { _ in
        submitted = true; return .axConfirmed
    }
    #expect(effect == .axInsert(insertion, moved, "original words"))
    #expect(submitted)
}

private actor DeliveryGate {
    private var entered = false
    private var released = false
    func submit() async -> EffectResult {
        entered = true
        while !released { await Task.yield() }
        return .copied(attributableCounter: 11)
    }
    func waitForSubmission() async { while !entered { await Task.yield() } }
    func release() { released = true }
}

@MainActor @Test func canceledAsyncDeliveryCannotRestoreRecoveryOrQueueInsertion() async {
    let h = Harness()
    _ = h.final()
    let token = h.token()!
    let gate = DeliveryGate()
    let task = Task { await h.policy.commitAsync(token, context: h.context) { _ in await gate.submit() } }
    await gate.waitForSubmission()
    h.policy.cancel()
    _ = h.policy.drainActions()
    await gate.release()
    _ = await task.value
    #expect(h.policy.recovery == nil)
    #expect(!h.policy.drainActions().contains { if case .commitReady = $0 { true } else { false } })
    #expect(h.policy.commit(token, context: h.context) { _ in .copied(attributableCounter: 12) } == nil)
}

@MainActor @Test func heldNavigationChordCannotCaptureAfterLateStartup() {
    for binding in [Binding.fn, .controlOption] {
        let h = Harness()
        h.policy.setBinding(binding)
        h.policy.setListener(Listener(shortcutsEnabled: true, suppressingTapActive: true,
                                     competingBindingsAcknowledged: true))
        h.policy.key(.flags(fn: binding == .fn, control: binding == .controlOption,
                            option: binding == .controlOption), context: h.context)
        let id = h.policy.activeGeneration!
        h.policy.key(.otherKeyDown, context: h.context)
        #expect(h.policy.activeGeneration == nil)
        _ = h.policy.drainActions()
        h.policy.send(.startupCompleted(id, h.ready, acquiredAdapter: true))
        let actions = h.policy.drainActions()
        #expect(captures(actions) == 0)
        #expect(closes(actions, id))
    }
}

@MainActor @Test func typingDuringToggleDoesNotCancelDictation() {
    let h = Harness()
    let id = h.begin()
    h.policy.key(.flags(fn: true, control: false, option: false), context: h.context)
    h.policy.key(.otherKeyDown, context: h.context)
    #expect(h.policy.activeGeneration == id)
    #expect(h.policy.state == .recordingToggle)
}

@MainActor @Test func navigationAfterCaptureDiscardsHeldAudioButPendingNavigationPreservesOlderRecovery() {
    let recording = Harness()
    recording.policy.key(.flags(fn: true, control: false, option: false), context: recording.context)
    let capturedID = recording.policy.activeGeneration!
    recording.policy.send(.startupCompleted(capturedID, recording.ready, acquiredAdapter: true))
    _ = recording.policy.drainActions()
    recording.policy.key(.otherKeyDown, context: recording.context)
    #expect(recording.policy.activeGeneration == nil)
    #expect(closes(recording.policy.drainActions(), capturedID))
    recording.policy.send(.final(capturedID, "discard this held capture"))
    #expect(recording.policy.recovery == nil)

    let pending = Harness()
    _ = pending.final("keep older recovery")
    _ = pending.commit(pending.token()!, result: .copied(attributableCounter: 11))
    _ = pending.commit(pending.token()!, result: .axConfirmed)
    pending.policy.key(.flags(fn: true, control: false, option: false), context: pending.context)
    pending.policy.key(.otherKeyDown, context: pending.context)
    #expect(pending.policy.activeGeneration == nil)
    #expect(pending.policy.recovery?.text == "keep older recovery")
}

@MainActor @Test func toggleTypingKeepsItsStopChordAvailable() {
    let h = Harness()
    _ = h.begin()
    h.policy.key(.flags(fn: true, control: false, option: false), context: h.context)
    h.policy.key(.otherKeyDown, context: h.context)
    #expect(h.policy.state == .recordingToggle)
    #expect(h.policy.key(.spaceDown(repeated: false), context: h.context))
    #expect(h.policy.state == .finalizing)
}

@MainActor @Test func canceledSubmittedDeliveryStillRecordsItsActualOutcome() async {
    let h = Harness()
    let id = h.final()
    let token = h.token()!
    let gate = DeliveryGate()
    let task = Task { await h.policy.commitAsync(token, context: h.context) { _ in await gate.submit() } }
    await gate.waitForSubmission()
    h.policy.cancel()
    _ = h.policy.drainActions()
    await gate.release()
    _ = await task.value
    let actions = h.policy.drainActions()
    #expect(actions.contains(.outcome(id, .copied)))
    #expect(!actions.contains { if case .commitReady = $0 { true } else { false } })
    #expect(h.policy.recovery == nil)
    #expect(h.policy.state == .idle)
}

@MainActor @Test func explicitCopyRetainsUnknownDestinationWarningAfterSuccess() {
    let h = Harness()
    _ = h.final()
    _ = h.commit(h.token()!, result: .copied(attributableCounter: 11))
    _ = h.commit(h.token()!, result: .axConfirmed)
    let context = Context(destination: nil)
    let token = h.policy.request(.copy, context: context)!
    _ = h.policy.commit(token, context: context) { _ in .copied(attributableCounter: 12) }
    #expect(h.policy.message.contains("classification unavailable"))
    #expect(h.policy.message.contains("Copied"))
}

@MainActor @Test func changingBindingRequiresFreshAcknowledgementAndListenerAdmission() {
    let h = Harness()
    h.policy.setBinding(.controlOption)
    #expect(!h.policy.listener.selected)
    #expect(!h.policy.listener.competingBindingsAcknowledged)
    h.policy.key(.flags(fn: false, control: true, option: true), context: h.context)
    #expect(!h.policy.isActive)
    h.policy.key(.flags(fn: false, control: false, option: false), context: h.context)
    h.policy.setListener(Listener(shortcutsEnabled: true, suppressingTapActive: true,
                                 competingBindingsAcknowledged: true))
    h.policy.key(.flags(fn: false, control: true, option: true), context: h.context)
    #expect(h.policy.state == .startingHeld)
}

@MainActor @Test func transcriptionHealthCanUseOnlyAnAdmittedRecognizedOutcome() {
    func recognized(_ actions: [Action]) -> Int {
        actions.filter { if case .outcome(_, .recognized) = $0 { true } else { false } }.count
    }
    let good = Harness(); let id = good.begin(); _ = good.policy.drainActions()
    good.policy.send(.final(id, "unsolicited while recording"))
    #expect(recognized(good.policy.drainActions()) == 0)
    good.policy.stop(); good.policy.send(.final(id, "accepted words"))
    #expect(recognized(good.policy.drainActions()) == 1)
    good.policy.send(.final(id, "duplicate final"))
    #expect(recognized(good.policy.drainActions()) == 0)
    for scenario in ["cancelled", "late", "empty", "oversize", "protected"] {
        let h = Harness(); let generation = h.begin(); h.policy.stop(); _ = h.policy.drainActions()
        if scenario == "cancelled" { h.policy.cancel() }
        if scenario == "late" { h.clock.now = 16 }
        if scenario == "protected" { h.policy.send(.observed(Context(destination: nil, secureEventInput: true))) }
        let text = scenario == "empty" ? " " : scenario == "oversize" ? String(repeating: "x", count: Policy.textLimit + 1) : "rejected words"
        h.policy.send(.final(generation, text))
        #expect(recognized(h.policy.drainActions()) == 0)
    }
}

// A Cmd-V paste is sent blind, so it starts unconfirmed; when the field is then read and
// holds the text, the paste is recorded as confirmed. Nothing else can claim a confirmed paste.
@MainActor @Test func aPasteTheFieldConfirmsIsRecordedAsConfirmed() {
    let h = Harness()
    var browser = h.normal; browser.route = .qualifiedClipboard
    h.final(destination: browser)
    let owned = Context(destination: browser, clipboardCounter: 100)
    #expect(h.commit(h.token()!, context: Context(destination: browser, clipboardCounter: 99),
                     result: .copied(attributableCounter: 100)) != nil)
    let paste = h.token()!
    #expect(h.commit(paste, context: owned, result: .pasteSent) == .pasteKey(paste, browser))
    #expect(h.policy.lastOutcomes.contains(.pasteSentUnconfirmed))
    _ = h.policy.drainActions()
    h.policy.confirmPaste(paste.generation)
    #expect(h.policy.drainActions().contains { if case .outcome(paste.generation, .pasteConfirmed) = $0 { true } else { false } })
    #expect(h.policy.lastOutcomes.last == .pasteConfirmed)
    // A generation with no unconfirmed paste is not upgraded.
    h.policy.confirmPaste(paste.generation &+ 99)
    #expect(!h.policy.drainActions().contains { if case .outcome(_, .pasteConfirmed) = $0 { true } else { false } })
}

// A readback that returns after the recovery was cleared confirms nothing.
@MainActor @Test func aClearedPasteIsNotConfirmedLater() {
    let h = Harness()
    var browser = h.normal; browser.route = .qualifiedClipboard
    h.final(destination: browser)
    #expect(h.commit(h.token()!, context: Context(destination: browser, clipboardCounter: 99),
                     result: .copied(attributableCounter: 100)) != nil)
    let paste = h.token()!
    #expect(h.commit(paste, context: Context(destination: browser, clipboardCounter: 100), result: .pasteSent) == .pasteKey(paste, browser))
    h.policy.clear()
    _ = h.policy.drainActions()
    h.policy.confirmPaste(paste.generation)
    #expect(!h.policy.drainActions().contains { if case .outcome(_, .pasteConfirmed) = $0 { true } else { false } })
    #expect(h.policy.lastOutcomes.last != .pasteConfirmed)
}
