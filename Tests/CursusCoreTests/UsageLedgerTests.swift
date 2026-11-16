import Foundation
import Testing
@testable import CursusCore

struct UsageLedgerTests {
    @Test func oneAttemptUpdatesButSeparateAttemptsAreBilled() throws {
        let now = Date(); var ledger = UsageLedger(startedAt: now)
        var first = UsageEvent(provider: "fixture", model: "fixture", operation: .speech, timestamp: now)
        ledger.record(first); first.charge = 0.04; first.outcome = .rejected
        ledger.record(first); ledger.record(first)
        ledger.record(.init(provider: "fixture", model: "fixture", operation: .cleanup, timestamp: now, charge: 0.02))
        #expect(ledger.events.count == 2)
        let totals = ledger.totals(in: DateInterval(start: now, duration: 1))
        #expect(abs(totals.reported - 0.06) < 0.00001); #expect(totals.unknown == 0)
        #expect(try JSONDecoder().decode(UsageLedger.self, from: JSONEncoder().encode(ledger)) == ledger)
    }
    @Test func halfOpenMonthKeepsUnknownAndCreditsSeparate() {
        let start = Date(timeIntervalSince1970: 1000); var ledger = UsageLedger()
        ledger.record(.init(provider: "fixture", model: "a", operation: .speech, timestamp: start, charge: 0))
        ledger.record(.init(provider: "fixture", model: "a", operation: .speech, timestamp: start))
        ledger.record(.init(provider: "fixture", model: "b", operation: .retry, timestamp: start, unit: .credits))
        ledger.record(.init(provider: "fixture", model: "c", operation: .speech, timestamp: start.addingTimeInterval(10), charge: 99))
        let totals = ledger.totals(in: DateInterval(start: start,duration: 10))
        #expect(totals.reported == 0); #expect(totals.unknown == 1)
        #expect(ledger.totals(in: DateInterval(start: start,duration: 10),unit: .credits).unknown == 1)
    }
    @Test func invalidChargesCannotPretendToBeFree() {
        #expect(UsageEvent(provider: "x",model: "x",operation: .speech,charge: -.infinity).charge == nil)
        #expect(UsageLedger.budgetThreshold(total: 8,budget: 10) == 80)
        #expect(UsageLedger.budgetThreshold(total: 11,budget: 10) == 100)
        #expect(UsageLedger.budgetThreshold(total: 11,budget: nil) == nil)
    }
}

@Test func decodedUsageNormalizesChargesAndRepeatedAttemptIDs() throws {
    let now = Date(); let id = UUID()
    let a = UsageEvent(id: id, provider: "fixture", model: "fixture", operation: .speech, timestamp: now, charge: 1)
    var ledger = UsageLedger(); ledger.record(a)
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as! [String:Any]
    var event = (object["events"] as! [[String:Any]])[0]
    event["charge"] = -4
    object["events"] = [event,event]
    let decoded = try JSONDecoder().decode(UsageLedger.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.events.count == 1)
    #expect(decoded.events[0].charge == nil)
    let total = decoded.totals(in: DateInterval(start: now.addingTimeInterval(-1), duration: 2))
    #expect(total.reported == 0); #expect(total.unknown == 1)
}
@Test func overflowingUsageRemainsFiniteAndExplicitlyIncomplete() {
    let now = Date(); var ledger = UsageLedger()
    for _ in 0..<2 { ledger.record(.init(provider: "fixture", model: "fixture", operation: .speech,
        timestamp: now, charge: Double.greatestFiniteMagnitude)) }
    let total = ledger.totals(in: DateInterval(start: now, duration: 1))
    #expect(total.reported.isFinite); #expect(total.unknown == 1)
}
// The ledger had no retention at all and is one file rewritten in full on every event.
@Test func theLedgerKeepsOnlyItsRetentionWindow() throws {
    let newest = Date(timeIntervalSince1970: 10_000_000)
    var ledger = UsageLedger(startedAt: newest.addingTimeInterval(-UsageLedger.retention * 2))
    ledger.record(.init(provider: "fixture", model: "ancient", operation: .speech,
                        timestamp: newest.addingTimeInterval(-UsageLedger.retention - 1)))
    ledger.record(.init(provider: "fixture", model: "edge", operation: .speech,
                        timestamp: newest.addingTimeInterval(-UsageLedger.retention)))
    ledger.record(.init(provider: "fixture", model: "fresh", operation: .speech, timestamp: newest))
    #expect(ledger.events.map(\.model) == ["edge", "fresh"])
    // Coverage must follow the retained window, not the ledger's original date.
    #expect(ledger.startedAt == newest.addingTimeInterval(-UsageLedger.retention))
    // The window follows the ledger's own newest event, never the wall clock.
    var old = UsageLedger()
    let ancient = Date(timeIntervalSince1970: 500)
    old.record(.init(provider: "fixture", model: "a", operation: .speech, timestamp: ancient))
    old.record(.init(provider: "fixture", model: "b", operation: .speech, timestamp: ancient.addingTimeInterval(60)))
    #expect(old.events.count == 2)
}
