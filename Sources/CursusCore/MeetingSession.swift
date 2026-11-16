import Foundation

public actor MeetingSession {
    public enum Mode: Sendable, Equatable { case privateMode, cloud }
    public enum Phase: Sendable, Equatable { case idle, starting, active, interrupted }
    public enum Source: String, Sendable, Hashable, CaseIterable { case me = "Me", others = "Others" }
    public enum Health: Sendable, Equatable { case unknown, ready, permissionDenied, disconnected, silent, routingFailed, timeout }
    public enum Surface: Sendable, CaseIterable { case character, transcript, answer, status, automaticWindow, accessibility }
    public enum Interruption: Sendable, Equatable { case source(Source, Health), diskFull, diskBackpressure, timeout, maximumDuration }
    public enum Failure: Error, Sendable, Equatable {
        case userActionRequired, consentRequired, sourcesUnavailable(Sources), invalidHealth
        case notActive, staleCallback, invalidTime, emptyText, segmentTooLarge, expiredSegment, answerTooLarge, noContext
        case localEngineUnavailable, credentialUnavailable, noEligibleModel, generationExhausted
        case interrupted(Interruption, cancelling: RequestID?), unverifiedCapture
    }
    public struct Sources: Sendable, Equatable {
        public let me: Health, others: Health
        public init(me: Health, others: Health) { self.me = me; self.others = others }
        fileprivate var missing: Set<Source> { Set(Source.allCases.filter { ($0 == .me ? me : others) != .ready }) }
    }
    public struct CaptureToken: Sendable, Equatable { public let sessionID: UUID; public let revision: UUID }
    public struct RequestID: Sendable, Equatable { public let sessionID: UUID; public let generation: UInt64 }
    public struct ModeChange: Sendable, Equatable {
        public let cancelling: RequestID?, capture: CaptureToken?
    }
    public struct Segment: Sendable, Equatable {
        public let time: Double, source: Source, text: String, provisional: Bool
        public let utteranceID: UUID, revision: UInt64
    }
    public struct Evaluation: Sendable {
        public let cases: Int, relevant: Int, allSafetyPassed: Bool, p95Seconds: Double
        public init(cases: Int, relevant: Int, allSafetyPassed: Bool, p95Seconds: Double) {
            self.cases = cases; self.relevant = relevant; self.allSafetyPassed = allSafetyPassed; self.p95Seconds = p95Seconds
        }
        fileprivate var passes: Bool {
            cases >= 12 && relevant <= cases && Double(relevant) / Double(cases) >= 10.0 / 12.0 &&
            allSafetyPassed && p95Seconds.isFinite && p95Seconds >= 0 && p95Seconds <= 8
        }
    }
    public struct Model: Sendable {
        public let id: String, mode: Mode, allowed: Bool, live: Bool, pricingRecorded: Bool
        // Measured total evaluation cost divided by successful answers, including failed attempts.
        public let costPerSuccessfulAnswer: Double?, evaluation: Evaluation
        public init(id: String, mode: Mode, allowed: Bool, live: Bool, pricingRecorded: Bool,
                    costPerSuccessfulAnswer: Double?, evaluation: Evaluation) {
            self.id = id; self.mode = mode; self.allowed = allowed; self.live = live
            self.pricingRecorded = pricingRecorded; self.costPerSuccessfulAnswer = costPerSuccessfulAnswer; self.evaluation = evaluation
        }
        fileprivate var eligible: Bool {
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, allowed, live, pricingRecorded,
                  let costPerSuccessfulAnswer, costPerSuccessfulAnswer.isFinite, costPerSuccessfulAnswer >= 0 else { return false }
            return evaluation.passes
        }
    }
    public struct Readiness: Sendable {
        public let localEngineReady: Bool, credentialApproved: Bool, models: [Model]
        public init(localEngineReady: Bool, credentialApproved: Bool, models: [Model]) {
            self.localEngineReady = localEngineReady; self.credentialApproved = credentialApproved; self.models = models
        }
    }
    public struct Request: Sendable, Equatable {
        public let id: RequestID, mode: Mode, modelID: String, segments: [Segment]
    }
    public enum ReplyDecision: Sendable, Equatable {
        case ignoredRepeat, prepare(Request, cancelling: RequestID?), unavailable(Failure, cancelling: RequestID?)
    }
    public enum KeyDecision: Sendable, Equatable { case ignoredRepeat, starting(CaptureToken), stopped(RequestID?) }
    public private(set) var phase: Phase = .idle
    public private(set) var mode: Mode
    public private(set) var sessionID: UUID?, capture: CaptureToken?, pending: RequestID?, answer: String?
    public private(set) var sources = Sources(me: .unknown, others: .unknown)
    public private(set) var warning = false, retainedUTF8Bytes = 0
    public private(set) var lastInterruption: Interruption?
    private var segments: [Segment] = []
    private var startTime = 0.0, lastTime = 0.0
    private var contentEpoch = 0.0
    private var evictedThrough: Double?
    private var generation: UInt64 = 0
    public init(mode: Mode = .privateMode) { self.mode = mode }
    public func presentationDenial(for surface: Surface) -> Failure { .unverifiedCapture }

    public func meetingKey(repeated: Bool = false, userInitiated: Bool, consent: Bool, now: Double,
                           sources: Sources, acceptingMissing: Set<Source> = []) throws(Failure) -> KeyDecision {
        if repeated { return .ignoredRepeat }
        // Stop is always permitted; consent and user initiation are start-admission requirements.
        if phase == .starting || phase == .active { return .stopped(stop()) }
        guard userInitiated else { throw .userActionRequired }
        guard consent else { throw .consentRequired }
        guard now.isFinite, now >= 0 else { throw .invalidTime }
        guard sources.missing.count < 2, sources.missing == acceptingMissing else { throw .sourcesUnavailable(sources) }
        self.sources = sources
        let id = UUID(), tokenRevision = UUID()
        sessionID = id; capture = CaptureToken(sessionID: id, revision: tokenRevision)
        phase = .starting; startTime = now; lastTime = now; generation = 0
        contentEpoch = now; evictedThrough = nil
        warning = false; lastInterruption = nil
        return .starting(CaptureToken(sessionID: id, revision: tokenRevision))
    }
    private func invalidateAnswer() -> RequestID? {
        let old = pending; pending = nil; answer = nil; return old
    }
    @discardableResult public func cancelAnswer(_ id: RequestID) throws(Failure) -> RequestID {
        guard pending == id else { throw .staleCallback }
        _ = invalidateAnswer(); return id
    }
    public func fail(_ id: RequestID) throws(Failure) { _ = try cancelAnswer(id) }
    @discardableResult public func stop() -> RequestID? {
        let old = invalidateAnswer(); phase = .idle; sessionID = nil; capture = nil
        segments.removeAll(); retainedUTF8Bytes = 0; warning = false; lastInterruption = nil
        evictedThrough = nil
        sources = Sources(me: .unknown, others: .unknown); return old
    }
    @discardableResult public func deleteSession() -> RequestID? { stop() }
    // The host must discard buffered pre-boundary audio and restart transcript admission with this token.
    @discardableResult public func setMode(_ newMode: Mode, now: Double) throws(Failure) -> ModeChange {
        guard now.isFinite, now >= 0,
              (phase != .starting && phase != .active) || now >= lastTime else { throw .invalidTime }
        guard mode != newMode else { return ModeChange(cancelling: nil, capture: capture) }
        let old = invalidateAnswer(); mode = newMode
        segments.removeAll(); retainedUTF8Bytes = 0
        contentEpoch = now; lastTime = now; evictedThrough = nil
        if let token = capture { capture = CaptureToken(sessionID: token.sessionID, revision: UUID()) }
        return ModeChange(cancelling: old, capture: capture)
    }
    @discardableResult public func interrupt(_ token: CaptureToken, reason: Interruption) throws(Failure) -> RequestID? {
        // Source/disk failures from this meeting still stop safely after a transcript revision changes.
        guard capture != nil, sessionID == token.sessionID else { throw .staleCallback }
        if case .source(let source, let health) = reason {
            guard health != .ready else { throw .invalidHealth }
            sources = Sources(me: source == .me ? health : sources.me, others: source == .others ? health : sources.others)
        }
        return end(reason)
    }
    private func end(_ reason: Interruption) -> RequestID? {
        let id = sessionID, health = sources
        let old = stop(); sessionID = id; sources = health; phase = .interrupted; lastInterruption = reason
        return old
    }
    // The host supplies monotonic seconds and calls advance even during silence.
    public func advance(now: Double) throws(Failure) {
        guard phase == .starting || phase == .active else { throw .notActive }
        guard now.isFinite, now >= 0, now >= lastTime else { throw .invalidTime }
        lastTime = now; warning = now - startTime >= 9_900
        if now - startTime >= 10_800 {
            let cancelled = end(.maximumDuration)
            throw .interrupted(.maximumDuration, cancelling: cancelled)
        }
        let expired = segments.prefix { $0.time < now - 300 }
        if let last = expired.last { evictedThrough = max(evictedThrough ?? last.time, last.time) }
        retainedUTF8Bytes -= expired.reduce(0) { $0 + $1.text.utf8.count }
        segments.removeFirst(expired.count)
    }
    public func captureReady(_ token: CaptureToken, now: Double) throws(Failure) {
        guard phase == .starting, capture == token else { throw .staleCallback }
        try advance(now: now); phase = .active
    }
    public func append(_ token: CaptureToken, time: Double, now: Double, source: Source,
                       text: String, provisional: Bool, utteranceID: UUID = UUID(), revision: UInt64 = 0) throws(Failure) {
        guard phase == .active, capture == token else { throw .staleCallback }
        try advance(now: now)
        guard !sources.missing.contains(source) else { throw .invalidHealth }
        // time is the earliest audio timestamp in the utterance, never its recognition-completion time.
        guard time.isFinite, time >= 0, time >= contentEpoch, time <= now else { throw .invalidTime }
        guard time >= now - 300 else { throw .expiredSegment }
        // Equal timestamps at the eviction frontier are refused, including unknown utterance IDs.
        guard evictedThrough.map({ time > $0 }) ?? true else { throw .expiredSegment }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .emptyText }
        let bytes = text.utf8.count
        guard bytes <= 4_000 else { throw .segmentTooLarge }
        if let previous = segments.firstIndex(where: { $0.utteranceID == utteranceID }) {
            guard segments[previous].source == source, revision > segments[previous].revision,
                  segments[previous].provisional || !provisional else { throw .staleCallback }
            retainedUTF8Bytes -= segments.remove(at: previous).text.utf8.count
        }
        let index = segments.firstIndex { $0.time > time } ?? segments.endIndex
        segments.insert(Segment(time: time, source: source, text: text, provisional: provisional,
                                utteranceID: utteranceID, revision: revision), at: index)
        retainedUTF8Bytes += bytes
        while retainedUTF8Bytes > 256 * 1_024 || segments.count > 1_024 {
            let evicted = segments.removeFirst()
            retainedUTF8Bytes -= evicted.text.utf8.count
            evictedThrough = max(evictedThrough ?? evicted.time, evicted.time)
        }
    }
    public func snapshot(now: Double) throws(Failure) -> [Segment] {
        guard phase == .active else { throw .notActive }
        try advance(now: now)
        // Keep a contiguous newest suffix: do not skip a large intervening utterance for older text.
        var result: [Segment] = [], bytes = 0
        for segment in segments.reversed() {
            guard segment.time >= now - 300 else { break }
            guard segment.time <= now else { continue }
            let count = segment.text.utf8.count
            guard bytes + count <= 4_000 else { break }
            result.append(segment); bytes += count
        }
        return result.reversed()
    }
    public func requestAnswer(now: Double, readiness: Readiness, repeated: Bool = false) -> ReplyDecision {
        if repeated { return .ignoredRepeat }
        let old = invalidateAnswer()
        do throws(Failure) {
            let request = try prepare(now: now, readiness: readiness)
            pending = request.id; return .prepare(request, cancelling: old)
        } catch { return .unavailable(error, cancelling: old) }
    }
    private func prepare(now: Double, readiness: Readiness) throws(Failure) -> Request {
        guard phase == .active, let sessionID else { throw .notActive }
        let context = try snapshot(now: now)
        guard generation < UInt64.max else { throw .generationExhausted }
        generation += 1
        guard !context.isEmpty else { throw .noContext }
        if mode == .privateMode && !readiness.localEngineReady { throw .localEngineUnavailable }
        if mode == .cloud && !readiness.credentialApproved { throw .credentialUnavailable }
        let ranked = readiness.models.filter { $0.mode == mode && $0.eligible }.sorted {
            ($0.costPerSuccessfulAnswer ?? .infinity, $0.evaluation.p95Seconds, $0.id) <
            ($1.costPerSuccessfulAnswer ?? .infinity, $1.evaluation.p95Seconds, $1.id)
        }
        guard let model = ranked.first else { throw .noEligibleModel }
        return Request(id: RequestID(sessionID: sessionID, generation: generation), mode: mode, modelID: model.id, segments: context)
    }
    public func complete(_ id: RequestID, answer text: String, now: Double) throws(Failure) {
        guard phase == .active, pending == id else { throw .staleCallback }
        try advance(now: now)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .emptyText }
        guard text.utf8.count <= 4_000 else { throw .answerTooLarge }
        pending = nil; answer = text
    }
}
