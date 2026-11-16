import Foundation
import CursusCore

@MainActor final class UsageStore {
    private(set) var ledger: UsageLedger
    private(set) var problem: String?
    private var unreadable = false
    let url: URL
    var changed: (() -> Void)?
    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Mercurius/usage.json")) {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let decoded = try JSONDecoder().decode(UsageLedger.self, from: data)
                guard decoded.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
                ledger = decoded
            } catch { ledger = UsageLedger(); unreadable = true; problem = "Usage file could not be read. Existing file preserved; usage recording paused." }
        } else { ledger = UsageLedger() }
    }
    func migrateToday(defaults: UserDefaults, now: Date = Date()) {
        guard ledger.events.isEmpty, problem == nil else { return }
        let format = DateFormatter(); format.dateFormat = "yyyy-MM-dd"
        guard defaults.string(forKey: "costDay") == format.string(from: now),
              let total = defaults.object(forKey: "costToday") as? Double, total.isFinite, total >= 0 else { return }
        record(UsageEvent(provider: "legacy-reported", model: "earlier-today-aggregate", operation: .migration,
            timestamp: now, outcome: .succeeded, charge: total))
        // This aggregate does not prove which earlier requests had missing charges.
        record(UsageEvent(provider: "legacy-unknown", model: "earlier-coverage-incomplete", operation: .migration,
            timestamp: now, outcome: .interrupted))
    }
    @discardableResult func record(_ event: UsageEvent) -> Bool {
        ledger.record(event)
        defer { changed?() }
        guard !unreadable else { return false }
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(ledger).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            problem = nil
            return true
        } catch { problem = "Usage could not be saved; totals may be incomplete."; return false }
    }
    // No transport may begin without a durable attempt. A refusal has no provider charge.
    func admit(_ event: UsageEvent) -> Bool {
        guard record(event) else {
            var refused = event; refused.outcome = .failed; refused.charge = 0
            ledger.record(refused); changed?(); return false
        }
        return true
    }
    // The account's real credit use, from ElevenLabs. It includes other apps on the same account.
    var elevenLabsCredits: (used: Int, limit: Int)?
    nonisolated static func creditsText(_ credits: (used: Int, limit: Int)) -> String {
        func short(_ value: Int) -> String {
            value >= 1000 ? String(format: value >= 100_000 ? "%.0fk" : "%.1fk", Double(value) / 1000) : String(value)
        }
        return "\(short(credits.used)) of \(short(credits.limit)) ElevenLabs credits"
    }
    func costLine(recordingID: UUID?) -> String? {
        guard let recordingID else { return nil }
        let events = ledger.events.filter { $0.recordingID == recordingID }
        guard !events.isEmpty else { return nil }
        return events.map { event in
            let amount = event.charge.map { event.unit == .usd ? ModelCosts.money($0) + " USD" : "\($0) credits" } ?? (event.unit == .credits ? "ElevenLabs credits" : "not priced")
            return ModelCosts.shortName(event.model) + " " + amount
        }.joined(separator: " · ")
    }
    func dailyOverview(now: Date = Date()) -> (String?,String?) {
        if problem != nil { return ("Usage tracking unavailable", "Costs unknown; open Usage & budget") }
        guard let day = Calendar.current.dateInterval(of: .day,for: now) else { return (nil,nil) }
        let events = ledger.events.filter { $0.timestamp >= day.start && $0.timestamp < day.end }
        guard !events.isEmpty else { return ("No recorded usage today",nil) }
        let totals = ledger.totals(in: day)
        let credits = ledger.totals(in: day,unit: .credits)
        // Never "unknown": an unpriced call makes the dollars approximate, and credits come from the provider's own balance.
        let headline = (totals.unknown > 0 ? "≈ " : "") + ModelCosts.money(totals.reported) + " USD"
            + (elevenLabsCredits.map { " · " + Self.creditsText($0) } ?? (credits.reported > 0 ? " · \(credits.reported) ElevenLabs credits" : ""))
        let models = Set(events.map(\.model)).sorted().map { model in
            let group = events.filter { $0.model == model }
            let usd = ledger.totals(in: day, model: model), credits = ledger.totals(in: day, unit: .credits, model: model)
            if group.allSatisfy({ $0.unit == .credits }) {
                return ModelCosts.shortName(model) + " · ElevenLabs credits"
            }
            return ModelCosts.shortName(model) + " " + (usd.unknown > 0 ? "≈ " : "") + ModelCosts.money(usd.reported)
        }.joined(separator: " · ")
        return (headline,models)
    }
    func summary(now: Date = Date(), calendar: Calendar = .current) -> String {
        let host = ProcessInfo.processInfo.hostName
        guard let day = calendar.dateInterval(of: .day, for: now), let month = calendar.dateInterval(of: .month, for: now) else { return "Usage date unavailable" }
        func line(_ title: String, _ interval: DateInterval) -> String {
            let usd = ledger.totals(in: interval), credits = ledger.totals(in: interval, unit: .credits)
            return "\(title): \(ModelCosts.money(usd.reported)) USD\(usd.unknown > 0 ? " (\(usd.unknown) calls not priced, so this is approximate)" : "")"
                + (credits.reported > 0 ? " · \(credits.reported) ElevenLabs credits" : "")
                + (credits.unknown > 0 ? " · \(credits.unknown) ElevenLabs calls, billed in credits" : "")
        }
        var lines = [host, line("Today", day), line("This month", month),
            "Complete ledger starts \(ledger.startedAt.formatted()). Earlier coverage is incomplete."]
        let events = ledger.events.filter { $0.timestamp >= month.start && $0.timestamp < month.end }
        for model in Set(events.map(\.model)).sorted() {
            let group = events.filter { $0.model == model }
            let usd = ledger.totals(in: month, model: model), credits = ledger.totals(in: month, unit: .credits, model: model)
            let amount = group.allSatisfy({ $0.unit == .credits }) ? "\(credits.reported) credits" : ModelCosts.money(usd.reported) + " USD"
            let unknown = usd.unknown + credits.unknown
            lines.append("\(ModelCosts.shortName(model)): \(amount) · \(group.count) attempts\(unknown > 0 ? " · \(unknown) unknown" : "")")
        }
        lines.append("Recent attempts")
        for event in ledger.events.suffix(20).reversed() {
            let charge = event.charge.map { event.unit == .usd ? ModelCosts.money($0) + " USD" : "\($0) credits" } ?? "charge unknown"
            lines.append("\(event.timestamp.formatted(date: .omitted, time: .shortened)) · \(event.operation.rawValue) · \(ModelCosts.shortName(event.model)) · \(event.outcome.rawValue) · \(charge)")
        }
        if let problem { lines.append(problem) }
        return lines.joined(separator: "\n\n")
    }
}
