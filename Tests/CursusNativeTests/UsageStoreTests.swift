import Foundation
import Testing
import CursusCore
@testable import CursusVox

@MainActor struct UsageStoreTests {
    @Test func survivesRestartAndRefusesToOverwriteCorruption() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("usage.json")
        let first = UsageStore(url: url)
        first.record(.init(provider: "fixture",model: "fixture",operation: .speech,charge: 0))
        #expect(UsageStore(url: url).ledger.events.count == 1)
        try Data("broken".utf8).write(to: url)
        let broken = UsageStore(url: url)
        broken.record(.init(provider: "fixture",model: "fixture",operation: .speech))
        #expect(broken.problem != nil); #expect(try String(contentsOf: url,encoding: .utf8) == "broken")
    }
    @Test func safeProviderProjectionNeverReturnsExtraFields() {
        let data = Data(#"{"data":{"limit_remaining":12,"key":"sensitive-fixture"}}"#.utf8)
        let text = ProviderBalance.summary(data,elevenLabs: false)
        #expect(text.contains("12")); #expect(!text.contains("sensitive"))
        #expect(ProviderBalance.summary(Data("{}".utf8),elevenLabs: true).contains("unknown"))
        let credits = ProviderBalance.credits(Data(#"{"character_count":6385,"character_limit":160889,"tier":"creator"}"#.utf8))
        #expect(credits?.used == 6385); #expect(credits?.limit == 160889)
        #expect(ProviderBalance.credits(Data("{}".utf8)) == nil)
    }
}

@MainActor @Test func usageHistoryGroupingKeepsUnknownCreditChargesSeparate() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = UsageStore(url: folder.appendingPathComponent("usage.json"))
    let a = UUID(), b = UUID()
    store.record(.init(recordingID: a,provider: "fixture",model: "speech-a",operation: .speech,charge: 0.025))
    store.record(.init(recordingID: b,provider: "fixture",model: "speech-b",operation: .speech,charge: 0.1))
    let line = try #require(store.costLine(recordingID: a))
    #expect(line.contains("speech-a")); #expect(!line.contains("speech-b"))
    store.record(.init(recordingID: a,provider: "elevenlabs",model: "scribe",operation: .retry,unit: .credits))
    #expect(store.costLine(recordingID: a)?.contains("ElevenLabs credits") == true)
    #expect(store.dailyOverview().0?.contains("unknown") == false)
    store.record(.init(recordingID: a,provider: "fixture",model: "speech-a",operation: .cleanup))
    #expect(store.dailyOverview().0?.hasPrefix("≈ ") == true)
    #expect(store.dailyOverview().0?.contains("unknown") == false)
    #expect(store.dailyOverview().1?.contains("unknown") == false)
    store.elevenLabsCredits = (6385, 160889)
    #expect(store.dailyOverview().0?.contains("6.4k of 161k ElevenLabs credits") == true)
}

@MainActor @Test func usageWriteFailureRetainsAttemptsAndRecoversDurability() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data("blocking file".utf8).write(to: folder)
    let store = UsageStore(url: folder.appendingPathComponent("usage.json"))
    let first = UsageEvent(provider: "fixture", model: "fixture", operation: .speech)
    store.record(first)
    #expect(store.problem != nil); #expect(store.ledger.events.count == 1)
    store.record(.init(provider: "fixture", model: "fixture", operation: .cleanup, charge: 0.04))
    #expect(store.ledger.events.count == 2)
    try FileManager.default.removeItem(at: folder)
    var completed = first; completed.charge = 0.02; completed.outcome = .succeeded
    store.record(completed)
    #expect(store.problem == nil)
    let restarted = UsageStore(url: folder.appendingPathComponent("usage.json"))
    #expect(restarted.ledger.events.count == 2)
    #expect(restarted.ledger.events.first?.charge == 0.02)
}

@MainActor @Test func usageAdmissionPersistsInterruptedAttemptBeforeCompletion() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("usage.json"), store = UsageStore(url: folder.appendingPathComponent("usage.json"))
    let event = UsageEvent(provider: "fixture", model: "fixture", operation: .speech)
    #expect(store.admit(event))
    #expect(UsageStore(url: url).ledger.events.first?.charge == nil)
    #expect(UsageStore(url: url).ledger.events.first?.outcome == .interrupted)
    store.record(.init(provider: "elevenlabs", model: "scribe", operation: .speech, charge: 12, unit: .credits))
    #expect(store.summary().contains("12.0 credits"))
    #expect(store.dailyOverview().0?.contains("12.0 ElevenLabs credits") == true)
}
