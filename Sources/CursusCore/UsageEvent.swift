import Foundation

public struct UsageEvent: Codable, Equatable, Sendable, Identifiable {
    public enum Operation: String, Codable, Sendable { case speech, cleanup, retry, reClean, migration }
    public enum Outcome: String, Codable, Sendable { case succeeded, rejected, failed, cancelled, interrupted }
    public enum Unit: String, Codable, Sendable { case usd, credits }
    public let id: UUID
    public var recordingID: UUID?
    public let provider: String
    public let model: String
    public let operation: Operation
    public var writingAction: String? = nil
    public var operationLabel: String { writingAction ?? operation.rawValue }
    public let timestamp: Date
    public var outcome: Outcome
    public var charge: Double?
    public let unit: Unit
    public init(id: UUID = UUID(), recordingID: UUID? = nil, provider: String, model: String,
                operation: Operation, timestamp: Date = Date(), outcome: Outcome = .interrupted,
                charge: Double? = nil, unit: Unit = .usd) {
        self.id = id; self.recordingID = recordingID; self.provider = provider; self.model = model
        self.operation = operation; self.timestamp = timestamp; self.outcome = outcome
        self.charge = charge.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }; self.unit = unit
    }
}

public struct UsageLedger: Codable, Equatable, Sendable {
    public var version = 1
    public var startedAt: Date
    public private(set) var events: [UsageEvent] = []
    public init(startedAt: Date = Date()) { self.startedAt = startedAt }
    private enum CodingKeys: String, CodingKey { case version, startedAt, events }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        for event in try values.decode([UsageEvent].self, forKey: .events) { record(event) }
    }
    // An attempt starts before transport. Its completion updates that same entry.
    public mutating func record(_ input: UsageEvent) {
        var event = input
        event.charge = event.charge.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if let i = events.firstIndex(where: { $0.id == event.id }) { events[i] = event }
        else { events.append(event) }
        prune()
    }
    // The ledger only ever grew: at least one entry per dictation, cleanup, retry, re-clean and
    // writing action, all held forever in one JSON file rewritten in full on every event. Nothing
    // in the app shows more than the current month, so keep a bounded window. The window is
    // measured from the newest event, not the wall clock, so a ledger is pruned by its own content.
    public static let retention: TimeInterval = 90 * 86400
    public mutating func prune() {
        guard let newest = events.map(\.timestamp).max() else { return }
        events.removeAll { newest.timeIntervalSince($0.timestamp) > Self.retention }
        // Coverage starts where the retained events start. Without this the summary kept claiming
        // the ledger began at its original date long after that history had been dropped.
        if let oldest = events.map(\.timestamp).min(), oldest > startedAt { startedAt = oldest }
    }
    public func totals(in interval: DateInterval, unit: UsageEvent.Unit = .usd, model: String? = nil) -> (reported: Double, unknown: Int) {
        let matches = events.filter { (model == nil || $0.model == model) && $0.unit == unit && $0.timestamp >= interval.start && $0.timestamp < interval.end }
        var reported = 0.0, unknown = 0
        for event in matches {
            guard let charge = event.charge, charge.isFinite, charge >= 0,
                  (reported + charge).isFinite else { unknown += 1; continue }
            reported += charge
        }
        return (reported, unknown)
    }
    public static func budgetThreshold(total: Double, budget: Double?) -> Int? {
        guard let budget, budget.isFinite, budget > 0 else { return nil }
        return total >= budget ? 100 : total >= budget * 0.8 ? 80 : nil
    }
}
