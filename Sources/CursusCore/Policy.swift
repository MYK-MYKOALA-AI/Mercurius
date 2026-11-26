import Foundation

// Policy and commit admission are serialized on the main actor. Synchronous
// adapters use commit; worker adapters use commitAsync and must revalidate a
// revocable submission permit immediately before their irreversible operation.
@MainActor public final class Policy {
    public nonisolated static let audioLimit = 8 * 1024 * 1024
    public nonisolated static let textLimit = 256 * 1024
    public nonisolated static let recoveryLifetime: TimeInterval = 600
    // Shorter held taps are discarded: Fn was used for something else.
    public nonisolated static let minimumHeld: TimeInterval = 0.25
    public nonisolated static let startupLifetime: TimeInterval = 15
    public private(set) var state: State = .idle
    public private(set) var generation: UInt64 = 0
    public private(set) var partialText = ""
    public private(set) var message = "Ready"
    public private(set) var copyEnabled = true
    public private(set) var binding: Binding = .fn
    public private(set) var listener = Listener()
    public private(set) var queuedAudioBytes = 0
    public private(set) var audioHighWater = 0
    public private(set) var availability: Availability?
    public private(set) var lastOutcomes: [Outcome] = []
    public private(set) var lastSubmittedOutcome: Outcome?
    private var lastDecisionGeneration: UInt64?
    private let clock: any PolicyClock
    private var actions: [Action] = []
    private var serial: UInt64 = 0
    private var fn = false
    private var control = false
    private var option = false
    private var gestureBlocked = false
    private var consumedSpace = false
    private var context = Context(destination: nil)
    private var storedRecovery: Recovery?
    private var buffers: [BufferToken: Int] = [:]
    private var jobs: [CommitToken: Job] = [:]
    private struct Session {
        let id: UInt64
        let startupAt: TimeInterval
        var mode: Mode
        let copyAtStart: Bool
        var startCounter: Int?
        var captured = false
        var captureAt: TimeInterval?
        var stopAt: TimeInterval?
        var outcomes: [Outcome] = []
    }
    private enum Intent { case autoCopy, autoInsert, manualCopy, manualPaste }
    private struct Job { let intent: Intent; let recovery: Recovery; var warning: String? = nil; var expectedDestination: Destination? = nil }
    private var session: Session?
    public init(clock: any PolicyClock) { self.clock = clock }
    public var activeGeneration: UInt64? { session?.id }
    public var isActive: Bool { session != nil }
    public var recovery: Recovery? {
        expireRecovery()
        return storedRecovery
    }
    public func drainActions() -> [Action] {
        defer { actions.removeAll(keepingCapacity: true) }
        return actions
    }
    private func status(_ text: String) {
        message = text
        actions.append(.status(text))
    }
    private func refuseQueuedRecoveryActions() {
        let generations = Set(jobs.compactMap { token, job -> UInt64? in
            switch job.intent {
            case .manualCopy, .manualPaste: token.generation
            default: nil
            }
        })
        for id in generations.sorted() { addOutcome(.deliveryBlocked, id: id) }
    }
    private func clearRecovery() {
        refuseQueuedRecoveryActions()
        storedRecovery = nil
        jobs.removeAll()
        actions.append(.recoveryCleared)
        if state == .delivering, session != nil {
            finishDelivery(blocked: true)
            status("Delivery cleared")
        }
    }
    private func expireRecovery() {
        if let r = storedRecovery, clock.now - r.receivedAt >= Self.recoveryLifetime {
            clearRecovery()
        }
    }
    // An owned retry offers text; only a subsequent explicit action can deliver it.
    @discardableResult public func offerRecovery(_ text: String, expectedGeneration: UInt64, age: TimeInterval = 0) -> Bool {
        guard age.isFinite, age >= 0, age < Self.recoveryLifetime,
              !isActive, jobs.isEmpty, generation == expectedGeneration,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= Self.textLimit else { return false }
        generation += 1
        lastOutcomes = [.recognized]; lastSubmittedOutcome = nil; lastDecisionGeneration = generation
        storedRecovery = Recovery(generation: generation, text: text, receivedAt: clock.now - age)
        state = .idle; status("Recovered text ready; choose Copy or Paste")
        return true
    }
    public func clear() { clearRecovery() }
    public func setCopyEnabled(_ enabled: Bool) {
        copyEnabled = enabled
        status(enabled ? "Copy On: clipboard history and system sync may retain text"
                       : "Copy Off: no subsequent clipboard access")
    }
    public func setBinding(_ value: Binding) {
        guard binding != value else { return }
        if isActive { cancel(reason: "Binding changed") }
        binding = value
        gestureBlocked = !rearmed
        setListener(Listener())
    }
    public func setListener(_ value: Listener) {
        listener = value
        if !value.selected {
            if isActive { cancel(reason: "Global listener unavailable") }
            status("Shortcuts off")
        }
    }
    public static func validateBinding(_ value: String) -> Bool {
        value == Binding.fn.rawValue || value == Binding.controlOption.rawValue
    }
    private var physicalHeld: Bool {
        binding == .fn ? fn : control && option
    }
    private var rearmed: Bool {
        binding == .fn ? !fn : !control && !option
    }
    private func latchHeldGesture(_ mode: Mode) {
        if mode == .held && !rearmed { gestureBlocked = true }
    }
    @discardableResult public func key(_ event: KeyEvent, context newContext: Context) -> Bool {
        observe(newContext)
        switch event {
        case let .flags(f, c, o):
            let wasHeld = physicalHeld
            fn = f; control = c; option = o
            if rearmed { gestureBlocked = false }
            guard listener.selected else { return false }
            if !wasHeld && physicalHeld && !gestureBlocked {
                if session?.mode == .toggle { return false }
                _ = start(mode: .held, context: newContext)
            } else if wasHeld && !physicalHeld && session?.mode == .held {
                stop()
            }
            return false
        case let .spaceDown(repeated):
            if repeated { return consumedSpace }
            guard !repeated, listener.selected, physicalHeld, !gestureBlocked else { return false }
            switch state {
            case .startingHeld:
                session?.mode = .toggle
                state = .startingToggle
            case .recordingHeld:
                session?.mode = .toggle
                state = .recordingToggle
            case .startingToggle, .recordingToggle:
                stop()
            default:
                status(isActive ? "Busy: start refused" : "Chord refused; release modifiers to rearm")
                return false
            }
            consumedSpace = true
            return true
        case .spaceUp:
            let consumed = consumedSpace
            consumedSpace = false
            return consumed
        case .otherKeyDown:
            guard listener.selected, physicalHeld else { return false }
            if session?.mode == .toggle { return false }
            if session?.mode == .held {
                if state == .startingHeld { stop() }
                else { cancel(reason: "Held chord used by another shortcut") }
            }
            gestureBlocked = true
            return false
        case let .escape(repeated):
            guard !repeated, listener.selected, isActive else { return false }
            cancel(reason: "Cancelled")
            return true
        }
    }
    @discardableResult public func start(mode: Mode = .toggle, context newContext: Context) -> Bool {
        observe(newContext)
        guard !isActive else { status("Busy: start refused"); return false }
        guard !newContext.secure else {
            clearRecovery(); status("Recording blocked by secure input"); return false
        }
        expireRecovery()
        generation += 1
        session = Session(id: generation, startupAt: clock.now, mode: mode,
                          copyAtStart: copyEnabled)
        state = mode == .held ? .startingHeld : .startingToggle
        partialText = ""
        lastOutcomes = []; lastSubmittedOutcome = nil; lastDecisionGeneration = nil
        audioHighWater = 0
        availability = nil
        actions.append(.startupRequested(generation))
        if copyEnabled { actions.append(.sampleStartClipboard(generation)) }
        status("Starting local dictation")
        return true
    }
    public func stop(timed: Bool = false) {
        guard let s = session else { return }
        latchHeldGesture(s.mode)
        switch state {
        case .startingHeld, .startingToggle:
            invalidate(clear: false, error: false, reason: "Stopped before capture began")
        case .recordingHeld where s.mode == .held && clock.now - s.startupAt < Self.minimumHeld:
            // Like a stop before capture: the tap is dropped, the last recovery kept.
            invalidate(clear: false, error: false, reason: "Too short; hold Fn while you talk")
        case .recordingHeld, .recordingToggle:
            session?.stopAt = clock.now
            state = .finalizing
            actions.append(.finalizeRequested(s.id, timed: timed))
            status(timed ? "Timed stop at sixty seconds; finalizing" : "Finalizing")
        default: break
        }
    }
    public func cancel(reason: String = "Cancelled") {
        invalidate(clear: true, error: false, reason: reason)
    }
    private func invalidate(clear: Bool, error: Bool, reason: String) {
        refuseQueuedRecoveryActions()
        if let s = session {
            latchHeldGesture(s.mode)
            actions.append(.closeAdapters(s.id))
            if state == .delivering { publishDecision(s) }
        }
        generation += 1
        session = nil
        partialText = ""
        jobs.removeAll()
        buffers.removeAll()
        queuedAudioBytes = 0
        if clear { clearRecovery() }
        state = error ? .recoverableError : .idle
        status(reason)
    }
    private func publishDecision(_ s: Session) {
        lastDecisionGeneration = s.id
        lastOutcomes = s.outcomes
        actions.append(.decision(s.id, s.outcomes))
    }
    private func finishDelivery(blocked: Bool) {
        guard var s = session else { return }
        if blocked && !s.outcomes.contains(.deliveryBlocked) {
            s.outcomes.append(.deliveryBlocked)
            actions.append(.outcome(s.id, .deliveryBlocked))
        }
        publishDecision(s)
        session = nil
        state = .idle
        partialText = ""
        status(blocked ? "Delivery blocked; recovery actions available" : "Delivery finished")
    }
    // A blind Cmd-V paste whose field was read back afterwards and holds the text. Only a
    // generation whose last outcome is an unconfirmed paste can be upgraded.
    public func confirmPaste(_ id: UInt64) {
        // Cleared or replaced recovery (secure input, Clear, a newer result) means this paste is no
        // longer the one on record; it stays unconfirmed.
        expireRecovery()
        guard storedRecovery?.generation == id else { return }
        let outcomes = session?.id == id ? session?.outcomes : (lastDecisionGeneration == id ? lastOutcomes : nil)
        guard outcomes?.last == .pasteSentUnconfirmed else { return }
        addOutcome(.pasteConfirmed, id: id)
    }
    private func addOutcome(_ outcome: Outcome, id: UInt64) {
        if session?.id == id { session?.outcomes.append(outcome) }
        else if lastDecisionGeneration == id {
            lastOutcomes.append(outcome)
            actions.append(.decision(id, lastOutcomes))
        }
        if outcome != .recognized && outcome != .deliveryBlocked,
           session?.id == id || (session == nil && lastDecisionGeneration == id) { lastSubmittedOutcome = outcome }
        actions.append(.outcome(id, outcome))
    }
    private func observe(_ value: Context) {
        context = value
        if value.secure {
            if isActive { invalidate(clear: true, error: false, reason: "Secure input cancelled session") }
            else { clearRecovery() }
            return
        }
    }
    public func send(_ event: Event) {
        switch event {
        case let .captureLimitReached(id):
            guard session?.id == id else { return }
            if state == .recordingHeld || state == .recordingToggle { stop(timed: true) }
            else if state == .finalizing { status("Timed stop at sixty seconds; finalizing") }
        case let .observed(value): observe(value)
        case let .interrupted(reason): invalidate(clear: true, error: true, reason: reason)
        case .tick:
            expireRecovery()
            guard let s = session else { return }
            if (state == .startingHeld || state == .startingToggle), clock.now - s.startupAt >= Self.startupLifetime {
                invalidate(clear: false, error: true, reason: "Recording setup timed out; check permissions and try again")
            } else if let stop = s.stopAt, state == .finalizing, clock.now - stop >= 15 {
                invalidate(clear: false, error: true, reason: "Finalization timed out; incomplete text cleared")
            } else if let start = s.captureAt,
                      (state == .recordingHeld || state == .recordingToggle), clock.now - start >= 60 {
                stop(timed: true)
            }
        case let .startClipboardSample(id, counter):
            guard copyEnabled, session?.id == id, session?.copyAtStart == true,
                  session?.startCounter == nil,
                  state == .startingHeld || state == .startingToggle else { return }
            session?.startCounter = counter
        case let .startupCompleted(id, value, acquired):
            guard session?.id == id, state == .startingHeld || state == .startingToggle else {
                if acquired { actions.append(.closeAdapters(id)) }
                return
            }
            guard let startupAt = session?.startupAt, clock.now - startupAt < Self.startupLifetime else {
                invalidate(clear: false, error: true, reason: "Recording setup timed out; check permissions and try again")
                return
            }
            availability = value
            guard value.ready else {
                invalidate(clear: false, error: true, reason: value.explanation)
                return
            }
            session?.captured = true
            session?.captureAt = clock.now
            state = session?.mode == .held ? .recordingHeld : .recordingToggle
            actions.append(.captureStarted(id))
            status("Recording locally")
        case let .partial(id, text):
            guard session?.id == id,
                  state == .recordingHeld || state == .recordingToggle || state == .finalizing else { return }
            if text.utf8.count <= Self.textLimit { partialText = text }
        case let .recognitionFailed(id, reason):
            guard session?.id == id else { return }
            invalidate(clear: false, error: true, reason: reason)
        case let .final(id, text): receiveFinal(id, text)
        }
    }
    private func receiveFinal(_ id: UInt64, _ text: String) {
        guard session?.id == id, session?.captured == true, state == .finalizing else { return }
        // A watchdog also applies when its tick callback was delayed.
        if let stop = session?.stopAt, clock.now - stop >= 15 {
            invalidate(clear: false, error: true, reason: "Finalization timed out")
            return
        }
        actions.append(.closeAdapters(id))
        buffers.removeAll(); queuedAudioBytes = 0; partialText = ""
        if text.utf8.count > Self.textLimit {
            invalidate(clear: false, error: true, reason: "Result exceeds 256 KiB")
            return
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session = nil; state = .idle; status("No speech text received")
            return
        }
        refuseQueuedRecoveryActions()
        jobs.removeAll()
        let r = Recovery(generation: id, text: text, receivedAt: clock.now,
                         ownedClipboardCounter: nil)
        storedRecovery = r
        state = .delivering
        addOutcome(.recognized, id: id)
        enqueue(.autoCopy, r)
    }
    @discardableResult public func reserveAudio(bytes: Int) -> BufferToken? {
        guard let id = session?.id, bytes > 0,
              state == .startingHeld || state == .startingToggle || state == .recordingHeld
              || state == .recordingToggle || state == .finalizing else { return nil }
        guard bytes <= Self.audioLimit - queuedAudioBytes else {
            invalidate(clear: true, error: true, reason: "Aggregate queued audio exceeds 8 MiB")
            return nil
        }
        serial += 1
        let token = BufferToken(serial: serial, generation: id)
        buffers[token] = bytes
        queuedAudioBytes += bytes
        audioHighWater = max(audioHighWater, queuedAudioBytes)
        actions.append(.bufferGranted(token, bytes: bytes))
        return token
    }
    public func releaseAudio(_ token: BufferToken) {
        if let bytes = buffers.removeValue(forKey: token) { queuedAudioBytes -= bytes }
    }
    private func enqueue(_ intent: Intent, _ r: Recovery) {
        serial += 1
        let token = CommitToken(serial: serial, generation: r.generation)
        jobs[token] = Job(intent: intent, recovery: r)
        actions.append(.commitReady(token))
    }
    public func refuseRecovery(expectedGeneration: UInt64, context value: Context) {
        guard storedRecovery?.generation == expectedGeneration else { return }
        observe(value)
        addOutcome(.deliveryBlocked, id: expectedGeneration)
        status("Recovery destination unavailable")
    }
    @discardableResult public func request(_ action: RecoveryAction, context value: Context, expectedDestination: Destination? = nil) -> CommitToken? {
        let recoveringGeneration = storedRecovery?.generation
        observe(value)
        expireRecovery()
        if value.secure {
            if let recoveringGeneration { addOutcome(.deliveryBlocked, id: recoveringGeneration) }
            status("Protected destination: recovery action refused"); return nil
        }
        guard let r = storedRecovery else { status("No valid recovery text"); return nil }
        guard !isActive else { addOutcome(.deliveryBlocked, id: r.generation); status("Busy: recovery action refused"); return nil }
        if action == .copy && !copyEnabled { addOutcome(.deliveryBlocked, id: r.generation); status("Copy is Off"); return nil }
        serial += 1
        let token = CommitToken(serial: serial, generation: r.generation)
        jobs[token] = Job(intent: action == .copy ? .manualCopy : .manualPaste, recovery: r, expectedDestination: expectedDestination)
        actions.append(.commitReady(token))
        return token
    }
    // The native caller uses this before obtaining a counter. Copy Off always returns false.
    // The supplied Context must then be freshly obtained immediately before commit.
    public func needsClipboardCounter(for token: CommitToken) -> Bool {
        guard copyEnabled, let job = jobs[token] else { return false }
        switch job.intent {
        case .autoCopy: return true
        case .autoInsert, .manualPaste: return context.destination?.route == .qualifiedClipboard
        case .manualCopy: return false
        }
    }
    // Sam 2026-10-12: deliver into whatever eligible field is focused when the
    // text is ready, as Wispr Flow does. Focus or caret moves no longer block it.
    private func automaticEligible(_ value: Context) -> Bool {
        guard session != nil, let current = value.destination, current.qualified,
              !value.secure else { return false }
        return true
    }
    private func admitCommit(_ token: CommitToken, context value: Context) -> (Job, Effect?)? {
        observe(value)
        expireRecovery()
        guard var job = jobs.removeValue(forKey: token) else { return nil }
        let automatic = job.intent == .autoCopy || job.intent == .autoInsert
        guard let r = storedRecovery, r.generation == token.generation,
              r.receivedAt == job.recovery.receivedAt,
              clock.now - r.receivedAt < Self.recoveryLifetime, !value.secure else {
            if !automatic { addOutcome(.deliveryBlocked, id: token.generation) }
            return nil
        }
        if automatic && (session?.id != token.generation || state != .delivering) { return nil }
        if !automatic && isActive {
            addOutcome(.deliveryBlocked, id: token.generation)
            status("Busy: recovery commit refused"); return nil
        }
        var effect: Effect?
        switch job.intent {
        case .autoCopy:
            // Copy even when paste is ineligible, so the text is ready for Cmd-V.
            // The commit-time counter still refuses a board changed after sampling.
            if copyEnabled {
                effect = .clipboardWrite(token, r.text, expectedCounter: value.clipboardCounter)
            }
        case .manualCopy:
            if copyEnabled {
                if value.destination == nil || value.destination?.classification == .unknown {
                    job.warning = "destination classification unavailable"
                    status("Explicit Copy: destination classification unavailable")
                }
                effect = .clipboardWrite(token, r.text, expectedCounter: nil)
            }
        case .autoInsert, .manualPaste:
            if !automatic, let expected = job.expectedDestination, value.destination != expected {
                status("Recovery destination changed; choose Paste again"); return (job, nil)
            }
            let eligible = automatic ? automaticEligible(value) : value.destination?.qualified == true
            if eligible, let target = value.destination {
                if target.route == .qualifiedAX { effect = .axInsert(token, target, r.text) }
                else if target.route == .qualifiedClipboard, copyEnabled,
                        let owned = r.ownedClipboardCounter, value.clipboardCounter == owned {
                    effect = .pasteKey(token, target)
                }
            }
        }
        return (job, effect)
    }
    private func completeCommit(_ token: CommitToken, job: Job, effect: Effect?, result: EffectResult?) {
        var successful = false
        if let effect, let result {
            // A synchronous adapter may notify cancellation while submitting an effect.
            // Submitted effects remain recorded, but cannot restore recovery or queue work.
            switch (effect, result) {
            case let (.clipboardWrite, .copied(counter)):
                successful = true
                addOutcome(.copied, id: token.generation)
                if storedRecovery?.generation == token.generation {
                    storedRecovery?.ownedClipboardCounter = counter
                }
            case (.axInsert, .axConfirmed):
                successful = true
                addOutcome(.insertedConfirmed, id: token.generation)
            case (.axInsert, .axSent):
                successful = true
                addOutcome(.insertedUnconfirmed, id: token.generation)
            case (.pasteKey, .pasteSent):
                successful = true
                addOutcome(.pasteSentUnconfirmed, id: token.generation)
            default: status("Delivery adapter failed or returned an incompatible outcome")
            }
        }
        let automatic = job.intent == .autoCopy || job.intent == .autoInsert
        if automatic && session?.id == token.generation && state == .delivering {
            if job.intent == .autoCopy, let current = storedRecovery { enqueue(.autoInsert, current) }
            else { finishDelivery(blocked: !successful) }
        } else if !automatic {
            if !successful { addOutcome(.deliveryBlocked, id: token.generation) }
            let result = successful ? (lastSubmittedOutcome?.label ?? "Recovery action submitted")
                : "Recovery action blocked; explicit Copy may be required"
            status(job.warning.map { result + " — " + $0 } ?? result)
        }
    }
    private func recordLateSubmission(_ token: CommitToken, effect: Effect?, result: EffectResult?) {
        switch (effect, result) {
        case (.clipboardWrite?, .copied?): addOutcome(.copied, id: token.generation)
        case (.axInsert?, .axConfirmed?): addOutcome(.insertedConfirmed, id: token.generation)
        case (.axInsert?, .axSent?): addOutcome(.insertedUnconfirmed, id: token.generation)
        case (.pasteKey?, .pasteSent?): addOutcome(.pasteSentUnconfirmed, id: token.generation)
        default: addOutcome(.deliveryBlocked, id: token.generation)
        }
    }
    // A token is removed at admission and cannot be replayed by either adapter.
    @discardableResult public func commit(_ token: CommitToken, context value: Context,
                                         perform: (Effect) -> EffectResult) -> Effect? {
        guard let (job, effect) = admitCommit(token, context: value) else { return nil }
        var result: EffectResult?
        if let effect { actions.append(.effect(effect)); result = perform(effect) }
        completeCommit(token, job: job, effect: effect, result: result)
        return effect
    }
    @discardableResult public func commitAsync(_ token: CommitToken, context value: Context,
            perform: @Sendable (Effect) async -> EffectResult) async -> Effect? {
        guard let (job, effect) = admitCommit(token, context: value) else { return nil }
        var result: EffectResult?
        if let effect {
            actions.append(.effect(effect))
            result = await perform(effect)
        }
        // An SDK return is not permission to restore canceled or expired recovery,
        // affect a new session, or queue its next delivery operation.
        expireRecovery()
        guard let recovery = storedRecovery, recovery.generation == token.generation,
              recovery.receivedAt == job.recovery.receivedAt, !context.secure else {
            recordLateSubmission(token, effect: effect, result: result); return effect
        }
        let automatic = job.intent == .autoCopy || job.intent == .autoInsert
        if automatic && (session?.id != token.generation || state != .delivering) {
            recordLateSubmission(token, effect: effect, result: result); return effect
        }
        if !automatic && isActive {
            recordLateSubmission(token, effect: effect, result: result); return effect
        }
        completeCommit(token, job: job, effect: effect, result: result)
        return effect
    }
}
