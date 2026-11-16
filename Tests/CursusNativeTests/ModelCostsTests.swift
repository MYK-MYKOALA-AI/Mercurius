import AppKit
import Foundation
import Synchronization
import Testing
@testable import CursusVox

// Shaped like OpenRouter's /api/v1/models?output_modalities=all (prices are strings, US$ per token
// or, for transcription models, per second of audio).
private let catalog = Data("""
{"data":[
 {"id":"x-ai/grok-stt-1.0","pricing":{"prompt":"0.0000277777777778","completion":"0"},
  "architecture":{"output_modalities":["transcription"]}},
 {"id":"openai/gpt-oss-120b","pricing":{"prompt":"0.00000015","completion":"0.0000006"},
  "architecture":{"output_modalities":["text"]}},
 {"id":"nvidia/nemotron-3-super-120b-a12b:free","pricing":{"prompt":"0","completion":"0"}},
 {"id":"broken/no-pricing"},
 {"id":"broken/negative","pricing":{"prompt":"-1","completion":"0"}}
]}
""".utf8)

@Test func catalogPricesParseAndLabelForThePickers() {
    let prices = ModelCosts.parse(catalog)
    #expect(prices.count == 3)
    #expect(prices["x-ai/grok-stt-1.0"]?.transcription == true)
    #expect(ModelCosts.label(prices["x-ai/grok-stt-1.0"]) == "$0.10/hour")
    #expect(ModelCosts.label(prices["openai/gpt-oss-120b"]) == "$0.15 / $0.60 per M tokens")
    #expect(ModelCosts.label(prices["nvidia/nemotron-3-super-120b-a12b:free"]) == "free")
    #expect(ModelCosts.label(nil) == nil)
    #expect(ModelCosts.parse(Data("not json".utf8)).isEmpty)
}

@Test func catalogModelsDriveThePickers() {
    let models = ModelCosts.parseCatalog(catalog)
    // The no-pricing entry stays listed (price unknown), the image-only would not.
    #expect(models.map(\.id) == ["broken/negative", "broken/no-pricing", "nvidia/nemotron-3-super-120b-a12b:free",
                                  "openai/gpt-oss-120b", "x-ai/grok-stt-1.0"])
    #expect(models.first { $0.id == "x-ai/grok-stt-1.0" }?.transcription == true)
    #expect(models.first { $0.id.hasSuffix(":free") }?.free == true)
    // Cleanup picker: measured catalog first, then catalogue extras, never a
    // transcription or known model twice.
    let picker = AICleanup.pickerModels(from: models)
    #expect(picker.first?.id == AICleanup.catalog[0].id)
    #expect(Set(picker.map(\.id)).count == picker.count)
    #expect(!picker.contains { $0.id == "x-ai/grok-stt-1.0" })
    #expect(picker.contains { $0.id == "nvidia/nemotron-3-super-120b-a12b:free" })
    // New catalog entries are in the built-in catalog now.
    #expect(AICleanup.catalog.contains { $0.id == "minimax/minimax-m3.1-flash:free" })
    #expect(AICleanup.catalog.contains { $0.id == "deepseek/deepseek-v4-flash" })
    #expect(AICleanup.order(choosing: "deepseek/deepseek-v4-flash", from: picker).first?.id == "deepseek/deepseek-v4-flash")
    // Speech picker: seeded models first, then every transcription model listed.
    let speech = CloudSpeech.pickerSpeechModels(from: models)
    #expect(speech.first == CloudSpeech.model)
    #expect(speech.contains("x-ai/grok-stt-1.0"))
    #expect(Set(speech).count == speech.count)
    // An entry with no architecture block is a text model and reaches the picker
    // even when it is not in the built-in catalog.
    let bare = ModelCosts.parseCatalog(Data(#"{"data":[{"id":"zz/new-model","pricing":{"prompt":"0","completion":"0"}}]}"#.utf8))
    #expect(bare.first?.outputsText == true)
    #expect(AICleanup.pickerModels(from: bare).contains { $0.id == "zz/new-model" })
    // Only a ":free" suffix marks a model as training; a $0 price alone does not.
    let promo = ModelCosts.parseCatalog(Data(#"{"data":[{"id":"zz/promo","pricing":{"prompt":"0","completion":"0"},"architecture":{"output_modalities":["text"]}}]}"#.utf8))
    #expect(promo.first?.free == false)
    #expect(AICleanup.pickerModels(from: promo).first { $0.id == "zz/promo" }?.trains == false)
}

@Test func moneyKeepsTwoSignificantDigitsOfSmallCharges() {
    #expect(ModelCosts.money(4) == "$4.00")
    #expect(ModelCosts.money(0.15) == "$0.15")
    #expect(ModelCosts.money(0.0123) == "$0.012")
    #expect(ModelCosts.money(0.000123) == "$0.00012")
    #expect(ModelCosts.money(0) == "$0")
    #expect(ModelCosts.money(.nan) == "$0")
}

@Test func spendIsDescribedPerModelAndTotalledPerDay() {
    let spends = [ModelCosts.Spend(model: "x-ai/grok-stt-1.0", usd: 0.0011),
                  ModelCosts.Spend(model: "openai/gpt-oss-120b", usd: nil)]
    #expect(ModelCosts.describe(spends) == "grok-stt-1.0 $0.0011 · gpt-oss-120b cost unknown")
    #expect(ModelCosts.describe([]) == nil)
    #expect(ModelCosts.shortName("cohere/north-mini-code:free") == "north-mini-code")

    var totals = ModelCosts.add(spends, to: [:], day: nil, today: "2026-10-18")
    totals = ModelCosts.add([.init(model: "x-ai/grok-stt-1.0", usd: 0.0009)], to: totals, day: "2026-10-18", today: "2026-10-18")
    #expect(abs((totals["x-ai/grok-stt-1.0"] ?? 0) - 0.002) < 1e-12)
    #expect(totals["openai/gpt-oss-120b"] == 0)
    // gpt-oss answered without a cost: its total must not read as a confirmed $0.
    let unknown = ModelCosts.addUnknown(spends, to: [], day: nil, today: "2026-10-18")
    #expect(unknown == ["openai/gpt-oss-120b"])
    #expect(ModelCosts.summary(totals, unknown: unknown) == "grok-stt-1.0 $0.0020 · gpt-oss-120b cost unknown")
    let partly = ModelCosts.add([.init(model: "openai/gpt-oss-120b", usd: 0.0001)], to: totals, day: "2026-10-18", today: "2026-10-18")
    #expect(ModelCosts.summary(partly, unknown: unknown) == "grok-stt-1.0 $0.0020 · gpt-oss-120b $0.00010 + unknown")
    #expect(ModelCosts.addUnknown([], to: unknown, day: "2026-10-18", today: "2026-10-19").isEmpty)
    // A new day starts from zero.
    let tomorrow = ModelCosts.add([.init(model: "openai/gpt-oss-120b", usd: 0.0001)], to: totals,
                                  day: "2026-10-18", today: "2026-10-19")
    #expect(tomorrow == ["openai/gpt-oss-120b": 0.0001])
    #expect(ModelCosts.summary([:]) == nil)
}

@Test func dictationBadgeNamesEveryModelAndItsCost() {
    var facts = LocalSpeech.Facts(generation: 1, raw: "heard", engine: .cloud, speechMillis: 1900, fallback: nil,
                                  cleanup: CleanupOutcome(text: "heard", model: "openai/gpt-oss-120b", millis: 400,
                                                          note: nil, cost: 0.00006),
                                  at: 0, speechCost: 0.0011, speechModel: "x-ai/grok-stt-1.0")
    #expect(Application.badge(facts) == "Grok · 1.9 s · cleaned 0.4 s")
    #expect(Application.costLine(facts) == "grok-stt-1.0 $0.0011 · gpt-oss-120b $0.000060")
    // Per-attempt charges win over the single model/cost pair.
    facts.cleanup = CleanupOutcome(text: "heard", model: nil, millis: 900, note: "rejected", cost: 0.0002,
                                   charges: [.init(model: "openai/gpt-oss-120b", usd: 0.0002)])
    #expect(Application.spends(facts) == [.init(model: "x-ai/grok-stt-1.0", usd: 0.0011), .init(model: "openai/gpt-oss-120b", usd: 0.0002)])
    let local = LocalSpeech.Facts(generation: 2, raw: "heard", engine: .apple, speechMillis: 800, fallback: nil,
                                  cleanup: nil, at: 0)
    #expect(Application.badge(local) == "On-device · 0.8 s")
    #expect(Application.costLine(local) == "free, on this Mac")
}

// The feed caches what it fetched and never sends the OpenRouter key.
@MainActor @Test func priceFeedFetchesWithoutAKeyAndCaches() async throws {
    let suite = "cursus-price-feed-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    CatalogFixture.requests.withLock { $0.removeAll() }
    let feed = ModelPriceFeed(defaults: defaults, protocolClasses: [CatalogFixture.self])
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        feed.updated = { done.resume() }
        feed.refresh()
    }
    #expect(feed.price("openai/gpt-oss-120b")?.completion == 0.0000006)
    let requests = CatalogFixture.requests.withLock { $0 }
    #expect(requests.count == 1)
    #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    // A fresh feed reads the cache and does not fetch again within 12 hours.
    let cached = ModelPriceFeed(defaults: defaults, protocolClasses: [CatalogFixture.self])
    #expect(cached.price("x-ai/grok-stt-1.0")?.transcription == true)
    cached.refresh()
    try await Task.sleep(for: .milliseconds(200))
    #expect(CatalogFixture.requests.withLock { $0.count } == 1)
}

private final class CatalogFixture: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[URLRequest]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: catalog)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor @Test func selectedCleanupModelAndBackupFollowTheActiveEngine() throws {
    let home = HomePanel()
    home.select(.settings)
    let view = try #require(home.popover.contentViewController?.view)
    func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
    let note = try #require(all(view).compactMap { $0 as? NSTextField }.first {
        $0.accessibilityLabel() == "Cleanup model details"
    })
    let nemotron = try #require(home.cleanupModel.itemArray.firstIndex {
        $0.representedObject as? String == "nvidia/nemotron-3-super-120b-a12b:free"
    })
    home.cleanupModel.selectItem(at: nemotron)
    home.engine.selectItem(at: 3)
    home.aiCleanup.state = .on
    home.refreshPrices()
    #expect(note.stringValue == "Cleanup sends the transcript, app name and dictionary terms. Free endpoint may train on this data.")
    #expect(home.cleanupModel.isEnabled)
    #expect(note.toolTip?.contains("gpt-oss-120b on Groq") == true)
    home.cleanupModel.selectItem(at: 0)
    home.refreshPrices()
    #expect(note.stringValue == "Cleanup sends the transcript, app name and dictionary terms.")
    home.engine.selectItem(at: 2)
    home.refreshPrices()
    #expect(note.stringValue == "On-device only. This model is not used.")
    #expect(!home.cleanupModel.isEnabled)
    home.engine.selectItem(at: 1)
    home.refreshPrices()
    #expect(note.stringValue == "For take-back phrases. Cleanup sends the transcript, app name and dictionary terms.")
    #expect(home.cleanupModel.isEnabled)
    home.engine.selectItem(at: 3)
    home.aiCleanup.state = .off
    home.refreshPrices()
    #expect(note.stringValue == "AI cleanup is off. This model is not used.")
    #expect(!home.cleanupModel.isEnabled)
    home.aiCleanup.state = .on
    home.refreshPrices()
    #expect(home.cleanupModel.isEnabled)
}
