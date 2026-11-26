import Foundation

// What each model costs. List prices come from OpenRouter's public model catalogue (no key, no
// text sent) for the Settings pickers; what a dictation actually spent comes from each response's
// usage.cost and is shown per model in History and as today's total per model.
struct ModelPrice: Codable, Equatable, Sendable {
    var prompt: Double            // US$ per input token; per second of audio for transcription models
    var completion: Double        // US$ per output token
    var transcription = false     // a speech-to-text model: per second of audio when it has no output price, else per token
}

// One catalogue entry with what the pickers need: price, whether it writes text or
// transcribes audio, and whether it is a `:free` endpoint. Only `:free` endpoints
// are treated as training on prompts in AICleanup; a model that merely costs $0
// today keeps `data_collection: deny` and is labelled by its price, not as training.
struct CatalogModel: Codable, Equatable, Sendable {
    var id: String
    var price: ModelPrice?
    var outputsText: Bool
    var transcription: Bool
    var free: Bool { id.hasSuffix(":free") }
}

enum ModelCosts {
    // `output_modalities=all` also lists the transcription models, which the default list leaves out.
    static let catalogURL = URL(string: "https://openrouter.ai/api/v1/models?output_modalities=all")!
    static let catalogLimit = 8 << 20

    static func parseCatalog(_ data: Data) -> [CatalogModel] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else { return [] }
        let prices = parse(data)
        return list.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let outputs = (item["architecture"] as? [String: Any])?["output_modalities"] as? [String] ?? []
            // Image/speech-only models can never clean up or transcribe dictation.
            // An entry with no architecture is kept as a text model (older payloads).
            guard outputs.isEmpty || outputs.contains("text") || outputs.contains("transcription") else { return nil }
            return CatalogModel(id: id, price: prices[id],
                                outputsText: outputs.isEmpty || outputs.contains("text"),
                                transcription: outputs.contains("transcription"))
        }.sorted { $0.id < $1.id }
    }

    static func parse(_ data: Data) -> [String: ModelPrice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else { return [:] }
        var prices: [String: ModelPrice] = [:]
        for item in list {
            guard let id = item["id"] as? String, let pricing = item["pricing"] as? [String: Any],
                  let prompt = number(pricing["prompt"]), let completion = number(pricing["completion"]),
                  prompt >= 0, completion >= 0 else { continue }
            let outputs = (item["architecture"] as? [String: Any])?["output_modalities"] as? [String] ?? []
            prices[id] = ModelPrice(prompt: prompt, completion: completion,
                                    transcription: outputs.contains("transcription"))
        }
        return prices
    }
    private static func number(_ value: Any?) -> Double? {
        if let text = value as? String { return Double(text) }
        return (value as? NSNumber)?.doubleValue
    }

    // The dearest per-second speech rate believed (US$ per hour of audio); the catalogue's
    // most expensive real per-second model is under $1/hour.
    static let maxHourlySpeechRate = 36.0

    // Short enough for a picker: "$0.10/hour", "$0.15 / $0.60 per M tokens", "free", "rate unclear".
    static func label(_ price: ModelPrice?) -> String? {
        guard let price else { return nil }
        if price.prompt == 0 && price.completion == 0 { return "free" }
        // A transcription model is priced per second of audio only when it has no output price
        // and a plausible rate; token-priced audio reads like a text model, and a figure that
        // would mean more than $36/hour is in some other unit the catalogue does not state.
        if price.transcription && price.completion == 0 {
            return price.prompt * 3600 > maxHourlySpeechRate ? "rate unclear" : "\(money(price.prompt * 3600))/hour"
        }
        return "\(money(price.prompt * 1_000_000)) / \(money(price.completion * 1_000_000)) per M tokens"
    }

    // Enough decimals to show the first two significant digits of a small charge.
    static func money(_ usd: Double) -> String {
        guard usd > 0, usd.isFinite else { return "$0" }
        let decimals = min(6, max(2, Int(-floor(log10(usd))) + 1))
        return String(format: "$%.\(decimals)f", usd)
    }

    // "x-ai/grok-stt-1.0" → "grok-stt-1.0"; ":free" is a price, not part of the name.
    static func shortName(_ id: String) -> String {
        let name = id.split(separator: "/").last.map(String.init) ?? id
        return name.hasSuffix(":free") ? String(name.dropLast(5)) : name
    }

    // One model's part of a dictation. usd nil: the provider reported no cost.
    struct Spend: Equatable, Sendable {
        var model: String
        var usd: Double?
    }

    // "grok-stt-1.0 $0.0011 · gpt-oss-120b $0.00006"; nil when nothing ran online.
    static func describe(_ spends: [Spend]) -> String? {
        guard !spends.isEmpty else { return nil }
        return spends.map { "\(shortName($0.model)) \($0.usd.map(money) ?? "cost unknown")" }.joined(separator: " · ")
    }

    // Today's spend per model; a new day starts from zero.
    static func add(_ spends: [Spend], to totals: [String: Double], day: String?, today: String) -> [String: Double] {
        var totals = day == today ? totals : [:]
        for spend in spends { totals[spend.model, default: 0] += spend.usd ?? 0 }
        return totals
    }

    // Today's models that answered without a usage.cost, so their total is a floor, not a fact.
    static func addUnknown(_ spends: [Spend], to unknown: [String], day: String?, today: String) -> [String] {
        var models = Set(day == today ? unknown : [])
        for spend in spends where spend.usd == nil && !ScribeSpeech.isDirect(spend.model) { models.insert(spend.model) }
        return models.sorted()
    }

    // "grok-stt-1.0 $0.012 · gpt-oss-120b $0.0009 + unknown", most expensive first; nil before any
    // spend. A model with uncounted charges never reads as a confirmed $0.
    static func summary(_ totals: [String: Double], unknown: [String] = []) -> String? {
        let used = totals.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        guard !used.isEmpty else { return nil }
        return used.map { entry in
            let name = shortName(entry.key)
            if ScribeSpeech.isDirect(entry.key) { return "ElevenLabs credits" }
            guard unknown.contains(entry.key) else { return "\(name) \(money(entry.value))" }
            return entry.value > 0 ? "\(name) \(money(entry.value)) + unknown" : "\(name) cost unknown"
        }.joined(separator: " · ")
    }
}

// Keeps the price list, cached for 12 hours. Prices are fetched without the OpenRouter key.
@MainActor final class ModelPriceFeed {
    static let refreshAfter: TimeInterval = 12 * 3600
    private(set) var prices: [String: ModelPrice]
    private(set) var models: [CatalogModel] = []
    private(set) var fetchedAt: Date?
    var updated: (() -> Void)?
    private let defaults: UserDefaults
    private let session: URLSession
    private var task: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, protocolClasses: [AnyClass]? = nil) {
        self.defaults = defaults
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration)
        prices = (defaults.data(forKey: "modelPrices"))
            .flatMap { try? JSONDecoder().decode([String: ModelPrice].self, from: $0) } ?? [:]
        models = (defaults.data(forKey: "modelCatalog"))
            .flatMap { try? JSONDecoder().decode([CatalogModel].self, from: $0) } ?? []
        fetchedAt = defaults.object(forKey: "modelPricesAt") as? Date
    }

    func price(_ id: String) -> ModelPrice? { prices[id] }

    func refresh(force: Bool = false, now: Date = Date()) {
        guard task == nil else { return }
        // A cache from before the catalogue existed has prices but no models;
        // that alone must not hold the pickers back for 12 hours.
        if !force, let fetchedAt, now.timeIntervalSince(fetchedAt) < Self.refreshAfter, !prices.isEmpty, !models.isEmpty { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            guard let (data, response) = try? await MetadataResponse.data(for: URLRequest(url: ModelCosts.catalogURL), session: session, limit: ModelCosts.catalogLimit),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count <= ModelCosts.catalogLimit else { return }
            let parsed = ModelCosts.parse(data)
            guard !parsed.isEmpty else { return }
            prices = parsed; fetchedAt = now
            let catalog = ModelCosts.parseCatalog(data)
            if !catalog.isEmpty { models = catalog }
            defaults.set(try? JSONEncoder().encode(models), forKey: "modelCatalog")
            defaults.set(try? JSONEncoder().encode(parsed), forKey: "modelPrices")
            defaults.set(now, forKey: "modelPricesAt")
            updated?()
        }
    }
}
