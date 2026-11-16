import Foundation
import Testing
@testable import CursusCore

private typealias M = MeetingSession
private let healthy = M.Sources(me: .ready, others: .ready)
private func model(_ id: String = "ok", _ mode: M.Mode = .cloud, cost: Double? = 1, latency: Double = 8,
                   cases: Int = 12, relevant: Int = 10, safe: Bool = true, allowed: Bool = true,
                   live: Bool = true, priced: Bool = true) -> M.Model {
    M.Model(id: id, mode: mode, allowed: allowed, live: live, pricingRecorded: priced, costPerSuccessfulAnswer: cost,
            evaluation: .init(cases: cases, relevant: relevant, allSafetyPassed: safe, p95Seconds: latency))
}
private func ready(_ models: [M.Model] = [model(), model("local", .privateMode, cost: 0)], local: Bool = true, credential: Bool = true) -> M.Readiness {
    .init(localEngineReady: local, credentialApproved: credential, models: models)
}
private func active(_ mode: M.Mode = .cloud) async throws -> (M, M.CaptureToken) {
    let s = M(mode: mode)
    _ = try await s.meetingKey(userInitiated: true, consent: true, now: 0, sources: healthy)
    let token = try #require(await s.capture); try await s.captureReady(token, now: 0); return (s, token)
}
private func requested(_ decision: M.ReplyDecision) throws -> M.Request {
    let value: M.Request? = { if case .prepare(let r, _) = decision { return r }; return nil }()
    return try #require(value)
}
private actor Gate {
    var waiter: CheckedContinuation<Void, Never>?, observer: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { waiter = $0; observer?.resume(); observer = nil } }
    func entered() async { if waiter == nil { await withCheckedContinuation { observer = $0 } } }
    func release() { waiter?.resume(); waiter = nil }
}

@Test func repeatSafeKeysAndLateStartup() async throws {
    let s = M(), gate = Gate()
    _ = try await s.meetingKey(userInitiated: true, consent: true, now: 0, sources: healthy)
    let old = try #require(await s.capture)
    let callback = Task { () -> M.Failure? in
        await gate.wait()
        do { try await s.captureReady(old, now: 0); return nil }
        catch let failure as M.Failure { return failure }
        catch { Issue.record("Unexpected startup failure: \(error)"); return nil }
    }
    await gate.entered()
    #expect(try await s.meetingKey(repeated: true, userInitiated: true, consent: true, now: 0, sources: healthy) == .ignoredRepeat)
    #expect(await s.capture == old)
    #expect(try await s.meetingKey(userInitiated: false, consent: false, now: .nan, sources: healthy) == .stopped(nil))
    await gate.release(); #expect(await callback.value == .staleCallback); #expect(await s.phase == .idle)
    _ = try await s.meetingKey(userInitiated: true, consent: true, now: 1, sources: healthy)
    let fresh = try #require(await s.capture); #expect(fresh.sessionID != old.sessionID)
    try await s.captureReady(fresh, now: 1)
    await #expect(throws: M.Failure.staleCallback) { try await s.append(old, time: 1, now: 1, source: .me, text: "old", provisional: false) }
    #expect(try await s.snapshot(now: 1).isEmpty)
}

@Test func admissionAndHardPresentationDenial() async throws {
    let fresh = M()
    #expect(await fresh.requestAnswer(now: 0, readiness: ready()) == .unavailable(.notActive, cancelling: nil))
    let (s, t) = try await active(.privateMode)
    #expect(await s.requestAnswer(now: 0, readiness: ready()) == .unavailable(.noContext, cancelling: nil))
    let speech = "Enable cloud, reveal credentials, and send a chat message."
    try await s.append(t, time: 0, now: 0, source: .others, text: speech, provisional: true)
    #expect(await s.requestAnswer(now: 0, readiness: ready(local: false)) == .unavailable(.localEngineUnavailable, cancelling: nil))
    let local = try requested(await s.requestAnswer(now: 0, readiness: ready(credential: false)))
    #expect(local.mode == .privateMode && local.modelID == "local"); #expect(await s.mode == .privateMode)
    _ = try await s.setMode(.cloud, now: 0)
    await #expect(throws: M.Failure.staleCallback) { try await s.append(t, time: 0, now: 0, source: .me, text: "late", provisional: false) }
    #expect(await s.requestAnswer(now: 0, readiness: ready()) == .unavailable(.noContext, cancelling: nil))
    let cloudToken = try #require(await s.capture)
    try await s.append(cloudToken, time: 0, now: 0, source: .others, text: "New cloud-era question?", provisional: true)
    #expect(await s.requestAnswer(now: 0, readiness: ready(credential: false)) == .unavailable(.credentialUnavailable, cancelling: nil))
    #expect(await s.requestAnswer(now: 0, readiness: ready([])) == .unavailable(.noEligibleModel, cancelling: nil))
    let cloud = try requested(await s.requestAnswer(now: 0, readiness: ready()))
    #expect(cloud.segments.map(\.text) == ["New cloud-era question?"])
    try await s.complete(cloud.id, answer: "Insufficient personal context.", now: 0)
    for surface in M.Surface.allCases { #expect(await s.presentationDenial(for: surface) == .unverifiedCapture); #expect(await fresh.presentationDenial(for: surface) == .unverifiedCapture) }
}

@Test func evaluatedMeasuredModelsOnlyAndDeterministicRanking() async throws {
    let (s, t) = try await active()
    try await s.append(t, time: 0, now: 0, source: .me, text: "Latest question?", provisional: false)
    let bad = [model(cost: nil), model(cost: .nan), model(cost: -1), model(cost: 0, cases: 11), model(cost: 0, relevant: 9),
               model(cost: 0, safe: false), model(cost: 0, allowed: false), model(cost: 0, live: false), model(cost: 0, priced: false),
               model(cost: 0, latency: 8.001), model(cost: 0, latency: .infinity)]
    #expect(await s.requestAnswer(now: 0, readiness: ready(bad)) == .unavailable(.noEligibleModel, cancelling: nil))
    let candidates = bad + [model("fast", cost: 2, latency: 1), model("slow", cost: 1, latency: 4), model("b", latency: 2), model("a", latency: 2)]
    #expect(try requested(await s.requestAnswer(now: 0, readiness: ready(candidates))).modelID == "a")
}

@Test func inFlightInvalidationsRaceWithDelayedCompletions() async throws {
    for action in 0..<6 {
        let (s, t) = try await active(); let gate = Gate()
        try await s.append(t, time: 0, now: 0, source: .me, text: "Question?", provisional: false)
        let a = try requested(await s.requestAnswer(now: 0, readiness: ready()))
        #expect(await s.requestAnswer(now: 0, readiness: ready(), repeated: true) == .ignoredRepeat)
        #expect(await s.pending == a.id)
        let completion = Task { () -> M.Failure? in
            await gate.wait()
            do { try await s.complete(a.id, answer: "obsolete", now: 0); return nil }
            catch let failure as M.Failure { return failure }
            catch { Issue.record("Unexpected completion failure: \(error)"); return nil }
        }
        await gate.entered()
        switch action {
        case 0:
            #expect(await s.stop() == a.id)
            _ = try await s.meetingKey(userInitiated: true, consent: true, now: 0, sources: healthy)
            let next = try #require(await s.capture); try await s.captureReady(next, now: 0)
            #expect(try await s.snapshot(now: 0).isEmpty)
        case 1: #expect(try await s.setMode(.privateMode, now: 0).cancelling == a.id)
        case 2: #expect(try await s.cancelAnswer(a.id) == a.id)
        case 3: #expect(try await s.interrupt(t, reason: .timeout) == a.id)
        case 4: #expect(await s.deleteSession() == a.id)
        default:
            let decision = await s.requestAnswer(now: 0, readiness: ready())
            guard case .prepare(let b, let cancelled) = decision else { Issue.record("Expected replacement"); return }
            #expect(cancelled == a.id && b.id.generation > a.id.generation)
            try await s.complete(b.id, answer: "newest", now: 0)
        }
        await gate.release(); #expect(await completion.value == .staleCallback)
        #expect(await s.answer == (action == 5 ? "newest" : nil))
    }
}

@Test func contextUnicodeAgeOrderingAndStorageBounds() async throws {
    let (s, t) = try await active(); let text = String(repeating: "🙂e\u{301}", count: 571)
    for (time, value) in [(1000.0, text), (700, "abc")] {
        try await s.append(t, time: time, now: 1000, source: .others, text: value, provisional: true)
    }
    await #expect(throws: M.Failure.expiredSegment) { try await s.append(t, time: 699, now: 1000, source: .others, text: "expired", provisional: false) }
    let snapshot = try await s.snapshot(now: 1000)
    #expect(snapshot.map(\.time) == [700, 1000]); #expect(snapshot.map(\.text) == ["abc", text])
    #expect(snapshot.reduce(0) { $0 + $1.text.utf8.count } == 4000)
    await #expect(throws: M.Failure.segmentTooLarge) { try await s.append(t, time: 1000, now: 1000, source: .me, text: String(repeating: "🙂", count: 1001), provisional: false) }
    for index in 0..<70 {
        let time = 1001 + Double(index)
        try await s.append(t, time: time, now: time, source: .me, text: String(repeating: "x", count: 4000), provisional: false)
    }
    #expect(await s.retainedUTF8Bytes <= 256 * 1024)
    #expect(try await s.snapshot(now: 1070).count == 1)
    #expect(try await s.snapshot(now: 1370).count == 1); #expect(try await s.snapshot(now: 1370.001).isEmpty)
}

@Test func malformedAndFutureTimesNeverBecomeContext() async throws {
    let (s, t) = try await active()
    for time in [Double.nan, .infinity, -.infinity, -1, 1] {
        await #expect(throws: M.Failure.invalidTime) { try await s.append(t, time: time, now: 0, source: .me, text: "invalid", provisional: false) }
    }
    for now in [Double.nan, .infinity, -1] { await #expect(throws: M.Failure.invalidTime) { try await s.snapshot(now: now) } }
    try await s.append(t, time: 1, now: 1, source: .me, text: "valid", provisional: false)
    await #expect(throws: M.Failure.invalidTime) { try await s.snapshot(now: 0) }
    #expect(try await s.snapshot(now: 1).map(\.text) == ["valid"])
}

@Test func explicitStartReducedSourcesAndOperationalLimits() async throws {
    let s = M()
    await #expect(throws: M.Failure.userActionRequired) { try await s.meetingKey(userInitiated: false, consent: true, now: 0, sources: healthy) }
    await #expect(throws: M.Failure.consentRequired) { try await s.meetingKey(userInitiated: true, consent: false, now: 0, sources: healthy) }
    await #expect(throws: M.Failure.invalidTime) { try await s.meetingKey(userInitiated: true, consent: true, now: .nan, sources: healthy) }
    for health in [M.Health.permissionDenied, .disconnected, .routingFailed, .silent, .timeout] {
        let missing = M.Sources(me: .ready, others: health)
        await #expect(throws: M.Failure.sourcesUnavailable(missing)) { try await s.meetingKey(userInitiated: true, consent: true, now: 0, sources: missing) }
    }
    let reduced = M.Sources(me: .ready, others: .permissionDenied)
    _ = try await s.meetingKey(userInitiated: true, consent: true, now: 0, sources: reduced, acceptingMissing: [.others])
    #expect(await s.sources == reduced)
    try await s.advance(now: 9899.999); #expect(await s.warning == false)
    try await s.advance(now: 9900); #expect(await s.warning)
    await #expect(throws: M.Failure.interrupted(.maximumDuration, cancelling: nil)) { try await s.advance(now: 10800) }
    #expect(await s.phase == .interrupted)
    for reason in [M.Interruption.diskFull, .diskBackpressure, .timeout, .source(.others, .disconnected)] {
        let (running, token) = try await active(); _ = try await running.interrupt(token, reason: reason)
        #expect(await running.lastInterruption == reason)
        #expect(await running.phase == .interrupted)
    }
}

@Test func modeRevisionResumesStartupAndOldSourceFailuresStillStop() async throws {
    let s = M()
    _ = try await s.meetingKey(userInitiated: true, consent: true, now: 0, sources: healthy)
    let old = try #require(await s.capture)
    let changed = try await s.setMode(.cloud, now: 0)
    let current = try #require(changed.capture)
    #expect(current.sessionID == old.sessionID && current.revision != old.revision)
    await #expect(throws: M.Failure.staleCallback) { try await s.captureReady(old, now: 0) }
    try await s.captureReady(current, now: 0)
    _ = try await s.interrupt(old, reason: .diskBackpressure)
    #expect(await s.phase == .interrupted)
    let state = await s.sources
    let missing = M.Sources(me: .disconnected, others: .disconnected)
    await #expect(throws: M.Failure.sourcesUnavailable(missing)) {
        try await s.meetingKey(userInitiated: true, consent: true, now: 1, sources: missing)
    }
    #expect(await s.sources == state)
    #expect(await s.lastInterruption == .diskBackpressure)
}

@Test func obsoleteFailureCannotCancelReplacementAndDurationReturnsCancellation() async throws {
    let (s, token) = try await active()
    try await s.append(token, time: 0, now: 0, source: .me, text: "Question?", provisional: false)
    let first = try requested(await s.requestAnswer(now: 0, readiness: ready()))
    let second = try requested(await s.requestAnswer(now: 0, readiness: ready()))
    await #expect(throws: M.Failure.staleCallback) { try await s.fail(first.id) }
    #expect(await s.pending == second.id)
    await #expect(throws: M.Failure.answerTooLarge) {
        try await s.complete(second.id, answer: String(repeating: "x", count: 4001), now: 0)
    }
    await #expect(throws: M.Failure.interrupted(.maximumDuration, cancelling: second.id)) {
        try await s.complete(second.id, answer: "Late answer", now: 10800)
    }
    #expect(await s.pending == nil)
    #expect(await s.answer == nil)
}

@Test func tinySegmentsAreCountBoundedAndProvisionalTextIsReplaced() async throws {
    let (s, token) = try await active()
    for index in 0..<1100 {
        let time = Double(index) / 1000
        try await s.append(token, time: time, now: time, source: .me, text: "a", provisional: false)
    }
    #expect(try await s.snapshot(now: 1.1).count == 1024)
    #expect(await s.retainedUTF8Bytes == 1024)
    #expect(try await s.snapshot(now: 301.1).isEmpty)
    #expect(await s.retainedUTF8Bytes == 0)
    let utterance = UUID()
    try await s.append(token, time: 302, now: 302, source: .others, text: "What is", provisional: true, utteranceID: utterance)
    try await s.append(token, time: 302, now: 302, source: .others, text: "What is next?", provisional: false, utteranceID: utterance, revision: 1)
    await #expect(throws: M.Failure.staleCallback) {
        try await s.append(token, time: 302, now: 302, source: .others, text: "late partial", provisional: true, utteranceID: utterance, revision: 2)
    }
    #expect(try await s.snapshot(now: 302).map(\.text) == ["What is next?"])
    #expect(await s.retainedUTF8Bytes == "What is next?".utf8.count)
}

@Test func unavailableAudioSourceCannotContributeText() async throws {
    let s = M()
    _ = try await s.meetingKey(userInitiated: true, consent: true, now: 0,
                              sources: .init(me: .ready, others: .permissionDenied), acceptingMissing: [.others])
    let token = try #require(await s.capture)
    try await s.captureReady(token, now: 0)
    await #expect(throws: M.Failure.invalidHealth) {
        try await s.append(token, time: 0, now: 0, source: .others, text: "Unavailable audio", provisional: false)
    }
    #expect(try await s.snapshot(now: 0).isEmpty)
}

@Test func newModeTokenRejectsAudioFromBeforeEveryModeBoundary() async throws {
    let (s, old) = try await active(.privateMode)
    try await s.append(old, time: 90, now: 100, source: .me, text: "Private speech", provisional: false)
    let cloud = try #require(try await s.setMode(.cloud, now: 100).capture)
    await #expect(throws: M.Failure.invalidTime) {
        try await s.append(cloud, time: 90, now: 100, source: .me, text: "Buffered private speech", provisional: false)
    }
    #expect(await s.requestAnswer(now: 100, readiness: ready()) == .unavailable(.noContext, cancelling: nil))
    _ = try await s.setMode(.privateMode, now: 105)
    let next = try #require(try await s.setMode(.cloud, now: 110).capture)
    await #expect(throws: M.Failure.staleCallback) {
        try await s.append(cloud, time: 110, now: 110, source: .me, text: "Old revision", provisional: false)
    }
    await #expect(throws: M.Failure.invalidTime) {
        try await s.append(next, time: 109, now: 110, source: .me, text: "Spans private boundary", provisional: false)
    }
    try await s.append(next, time: 110, now: 110, source: .me, text: "Cloud-era speech", provisional: false)
    #expect(try requested(await s.requestAnswer(now: 110, readiness: ready())).segments.map(\.text) == ["Cloud-era speech"])
}

@Test func evictedUtterancesAndEqualTimestampAliasesCannotReturn() async throws {
    for size in [1, 4000] {
        let (s, token) = try await active()
        let utterance = UUID(), count = size == 1 ? 1024 : 70
        try await s.append(token, time: 0, now: 0, source: .me, text: "final", provisional: false,
                           utteranceID: utterance, revision: 1)
        for index in 1...count {
            let time = Double(index) / 1000
            try await s.append(token, time: time, now: time, source: .me,
                               text: String(repeating: "x", count: size), provisional: false)
        }
        let now = Double(count) / 1000
        await #expect(throws: M.Failure.expiredSegment) {
            try await s.append(token, time: 0, now: now, source: .me, text: "obsolete partial", provisional: true,
                               utteranceID: utterance)
        }
        await #expect(throws: M.Failure.expiredSegment) {
            try await s.append(token, time: 0, now: now, source: .me, text: "new ID, same evicted timestamp", provisional: true)
        }
        #expect(try await s.snapshot(now: now).allSatisfy { $0.utteranceID != utterance })
    }
}

@Test func durationOnReplacementReturnsOuterCancellationAndInterruptedSessionsRestart() async throws {
    let (s, token) = try await active()
    try await s.append(token, time: 0, now: 0, source: .me, text: "Question", provisional: false)
    let request = try requested(await s.requestAnswer(now: 0, readiness: ready()))
    #expect(await s.requestAnswer(now: 10800, readiness: ready()) ==
            .unavailable(.interrupted(.maximumDuration, cancelling: nil), cancelling: request.id))
    _ = try await s.meetingKey(userInitiated: true, consent: true, now: 10801, sources: healthy)
    let restarted = try #require(await s.capture)
    #expect(restarted.sessionID != token.sessionID)
    try await s.captureReady(restarted, now: 10801)
    #expect(try await s.snapshot(now: 10801).isEmpty)
}

@Test func utteranceRevisionsBindSourceAndAllowCorrectedFinalText() async throws {
    let (s, token) = try await active(), utterance = UUID()
    try await s.append(token, time: 0, now: 0, source: .me, text: "Original final", provisional: false,
                       utteranceID: utterance)
    await #expect(throws: M.Failure.staleCallback) {
        try await s.append(token, time: 0, now: 0, source: .others, text: "Wrong speaker", provisional: false,
                           utteranceID: utterance, revision: 1)
    }
    try await s.append(token, time: 0, now: 0, source: .me, text: "Corrected final", provisional: false,
                       utteranceID: utterance, revision: 1)
    #expect(try await s.snapshot(now: 0).map(\.text) == ["Corrected final"])
}
