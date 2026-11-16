import Foundation
import Testing
import CursusCore
@testable import CursusVox

// Answers every chat request with the content set for the test; counts requests.
private final class ChatFixture: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var replies: [String] = []
    nonisolated(unsafe) static var delay: TimeInterval = 0
    nonisolated(unsafe) static var requests = 0
    nonisolated(unsafe) static var finish = "stop"
    nonisolated(unsafe) static var costs: [Double?] = []   // usage.cost per reply; none when nil or absent
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let index = Self.requests; Self.requests += 1
        let content = index < Self.replies.count ? Self.replies[index] : ""
        var reply: [String: Any] = ["choices": [["message": ["content": content], "finish_reason": Self.finish]]]
        if index < Self.costs.count, let cost = Self.costs[index] { reply["usage"] = ["cost": cost] }
        let body = try! JSONSerialization.data(withJSONObject: reply)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay) { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

// Authored dictionary for cleanup cases; independent of new-user defaults.
private let vocabulary = Vocabulary(terms: ["CursusVox", "Grok", "OpenRouter", "Supabase", "GitHub"], replacements: ["superbase": "Supabase", "super base": "Supabase", "cursor's box": "CursusVox", "cursus vox": "CursusVox", "open router": "OpenRouter", "git hub": "GitHub"])
private let raw = "Can you open Cursor's box and check the Grok transcription accuracy on open router?"
private let rules = "Can you open CursusVox and check the Grok transcription accuracy on OpenRouter?"

@Suite(.serialized) @MainActor struct CleanupTests {
    @Test func smartOffCorrectionFallsBackToRulesThroughTheAIPath() async {
        let spoken = "We should go Friday, actually, Saturday."
        ChatFixture.replies = ["We should go Saturday.", "We should go Saturday."]
        ChatFixture.delay = 0; ChatFixture.requests = 0; ChatFixture.finish = "stop"
        let outcome = await AICleanup(protocolClasses: [ChatFixture.self]).clean(spoken, rules: spoken,
            context: CleanupContext(style: .smart), vocabulary: Vocabulary(terms: []), key: "fixture", smart: true)
        #expect(outcome.text == spoken)
        #expect(outcome.model == nil)
        #expect(ChatFixture.requests == 2)
        #expect(outcome.note?.contains("dropped words") == true)
    }
    @Test func explicitStrictStyleRejectsAMergeDespiteSmartGlobalDefault() async {
        let spoken = "Can you book Friday? No, I mean Saturday."
        ChatFixture.replies = ["Can you book it for Saturday?", "Can you book it for Saturday?"]
        ChatFixture.delay = 0; ChatFixture.requests = 0; ChatFixture.finish = "stop"
        let cleanup = AICleanup(protocolClasses: [ChatFixture.self])
        let outcome = await cleanup.clean(spoken, rules: spoken, context: CleanupContext(app: "Terminal"),
            vocabulary: Vocabulary(terms: [], takeBacks: TakeBack.defaults), key: "fixture", smart: false)
        #expect(outcome.text == spoken)
        #expect(outcome.model == nil)
        #expect(ChatFixture.requests == 2)
        #expect(cleanup.smart)
    }
    // A rejected answer is billed to its own model; the accepted one to its model.
    @Test func eachCleanupModelKeepsItsOwnCharge() async {
        ChatFixture.replies = ["Something else entirely, nothing like what was said.", rules]
        ChatFixture.costs = [0.0002, 0.0001]
        ChatFixture.delay = 0; ChatFixture.requests = 0; ChatFixture.finish = "stop"
        defer { ChatFixture.costs = [] }
        let outcome = await AICleanup(protocolClasses: [ChatFixture.self])
            .clean(raw, rules: rules, context: CleanupContext(app: "Slack"), vocabulary: vocabulary, key: "fixture")
        let first = AICleanup.models[0].id, second = AICleanup.models[1].id
        #expect(outcome.model == second)
        #expect(outcome.charges == [.init(model: first, usd: 0.0002), .init(model: second, usd: 0.0001)])
        #expect(abs((outcome.cost ?? 0) - 0.0003) < 1e-12)
        let facts = LocalSpeech.Facts(generation: 1, raw: raw, engine: .cloud, speechMillis: 1000, fallback: nil,
                                      cleanup: outcome, at: 0, speechCost: 0.001, speechModel: CloudSpeech.model)
        #expect(Application.spends(facts).map(\.model) == [CloudSpeech.model, first, second])
        let badge = Application.costLine(facts)
        #expect(badge.contains("\(ModelCosts.shortName(first)) $0.00020") && badge.contains("\(ModelCosts.shortName(second)) $0.00010"))
    }
    // When every answer is rejected, each model still shows what it charged (or that it's unknown).
    @Test func rejectedCleanupStillNamesEveryModel() async {
        ChatFixture.replies = ["Something else entirely.", "Also something else entirely."]
        ChatFixture.costs = [0.0002, nil]
        ChatFixture.delay = 0; ChatFixture.requests = 0; ChatFixture.finish = "stop"
        defer { ChatFixture.costs = [] }
        let outcome = await AICleanup(protocolClasses: [ChatFixture.self])
            .clean(raw, rules: rules, context: CleanupContext(app: "Slack"), vocabulary: vocabulary, key: "fixture")
        #expect(outcome.model == nil)
        #expect(outcome.charges == [.init(model: AICleanup.models[0].id, usd: 0.0002), .init(model: AICleanup.models[1].id, usd: nil)])
        #expect(ModelCosts.describe(outcome.charges)?.contains("cost unknown") == true)
    }
    // A reply cut off by the token limit is unusable but billed: the charge stays with its model.
    @Test func cutOffReplyKeepsItsCharge() async {
        ChatFixture.replies = [rules, rules]; ChatFixture.costs = [0.0003, 0.0001]
        ChatFixture.delay = 0; ChatFixture.requests = 0; ChatFixture.finish = "length"
        defer { ChatFixture.costs = []; ChatFixture.finish = "stop" }
        let outcome = await AICleanup(protocolClasses: [ChatFixture.self])
            .clean(raw, rules: rules, context: CleanupContext(app: "Slack"), vocabulary: vocabulary, key: "fixture")
        #expect(outcome.model == nil)
        // JSON can round 0.0003 to 0.00029999…, so costs compare within a hair.
        #expect(outcome.charges.map(\.model) == [AICleanup.models[0].id, AICleanup.models[1].id])
        #expect(zip(outcome.charges.compactMap(\.usd), [0.0003, 0.0001]).allSatisfy { abs($0 - $1) < 1e-12 })
        #expect(abs((outcome.cost ?? 0) - 0.0004) < 1e-12)
        #expect(outcome.note?.contains("cut off") == true)
    }
    // A reply larger than the usable limit is refused, but the charge OpenRouter reported for it
    // must survive: it used to be discarded and the model reported as a plain failure.
    @Test func oversizedReplyStillKeepsItsReportedCharge() async {
        let huge = String(repeating: "x", count: AICleanup.responseLimit + 4096)
        ChatFixture.replies = [huge, huge]; ChatFixture.costs = [0.0003, 0.0001]
        ChatFixture.delay = 0; ChatFixture.requests = 0; ChatFixture.finish = "stop"
        defer { ChatFixture.costs = [] }
        let outcome = await AICleanup(protocolClasses: [ChatFixture.self])
            .clean(raw, rules: rules, context: CleanupContext(app: "Slack"), vocabulary: vocabulary, key: "fixture")
        #expect(outcome.model == nil)
        #expect(outcome.charges.map(\.model) == [AICleanup.models[0].id, AICleanup.models[1].id])
        // Every charge must be present (not dropped to "unknown") and match what the reply reported.
        #expect(outcome.charges.allSatisfy { $0.usd != nil })
        #expect(zip(outcome.charges.compactMap(\.usd), [0.0003, 0.0001]).allSatisfy { abs($0 - $1) < 1e-12 })
    }
    @Test func acceptedRewriteIsUsedWithItsModel() async {
        ChatFixture.replies = [rules]; ChatFixture.delay = 0; ChatFixture.requests = 0; ChatFixture.finish = "stop"
        let outcome = await AICleanup(protocolClasses: [ChatFixture.self])
            .clean(raw, rules: rules, context: CleanupContext(app: "Slack"), vocabulary: vocabulary, key: "fixture")
        #expect(outcome.text == rules)
        #expect(outcome.model == AICleanup.models[0].id)
        #expect(ChatFixture.requests == 1)
    }
    @Test func truncatedReplyIsNeverUsed() async {
        ChatFixture.replies = [rules, rules]; ChatFixture.delay = 0; ChatFixture.requests = 0; ChatFixture.finish = "length"
        let outcome = await AICleanup(protocolClasses: [ChatFixture.self])
            .clean(raw, rules: rules, context: CleanupContext(), vocabulary: vocabulary, key: "fixture")
        ChatFixture.finish = "stop"
        #expect(outcome.model == nil)
        #expect(ChatFixture.requests == 2)
    }
    @Test func modelChangingAnIdentifiersCaseIsNotUsed() async {
        let spoken = "So, fooBar runs on iOS."
        ChatFixture.replies = ["Foobar runs on Ios.", "Foobar runs on Ios."]; ChatFixture.delay = 0
        ChatFixture.requests = 0; ChatFixture.finish = "stop"
        let outcome = await AICleanup(protocolClasses: [ChatFixture.self])
            .clean(spoken, rules: spoken, context: CleanupContext(), vocabulary: vocabulary, key: "fixture")
        #expect(outcome.model == nil)
        #expect(outcome.text == spoken)
    }
    @Test func shortBudgetSkipsTheModelEntirely() async {
        ChatFixture.replies = [rules]; ChatFixture.delay = 0; ChatFixture.requests = 0; ChatFixture.finish = "stop"
        let outcome = await AICleanup(protocolClasses: [ChatFixture.self])
            .clean(raw, rules: rules, context: CleanupContext(), vocabulary: vocabulary, key: "fixture", budget: 0.05)
        #expect(outcome.model == nil)
        #expect(ChatFixture.requests == 0)
    }
    @Test func rejectedRewriteTriesBackupThenFallsBackToRules() async {
        ChatFixture.replies = ["Sure! I opened it for you.", "Yes."]; ChatFixture.delay = 0; ChatFixture.requests = 0; ChatFixture.finish = "stop"
        let outcome = await AICleanup(protocolClasses: [ChatFixture.self])
            .clean(raw, rules: rules, context: CleanupContext(), vocabulary: vocabulary, key: "fixture")
        #expect(outcome.text == rules)
        #expect(outcome.model == nil)
        #expect(ChatFixture.requests == 2)
        #expect(outcome.note?.contains("rejected") == true)
    }
    @Test func slowModelFallsBackToRulesWithinBudget() async {
        ChatFixture.replies = [rules, rules]; ChatFixture.delay = AICleanup.budget + 1; ChatFixture.requests = 0; ChatFixture.finish = "stop"
        let began = Date()
        let outcome = await AICleanup(protocolClasses: [ChatFixture.self])
            .clean(raw, rules: rules, context: CleanupContext(), vocabulary: vocabulary, key: "fixture")
        #expect(outcome.model == nil)
        #expect(outcome.text == rules)
        #expect(Date().timeIntervalSince(began) < AICleanup.budget + 0.5)
    }
    @Test func modelDroppingAMinusIsNotUsed() async {
        let spoken = "Calculate x - y."
        ChatFixture.replies = ["Calculate x y.", "Calculate x y."]; ChatFixture.delay = 0; ChatFixture.requests = 0
        ChatFixture.finish = "stop"
        let outcome = await AICleanup(protocolClasses: [ChatFixture.self])
            .clean(spoken, rules: spoken, context: CleanupContext(), vocabulary: vocabulary, key: "fixture")
        #expect(outcome.model == nil)
        #expect(outcome.text == spoken)
    }
    // Strict mode only: Smart may merge clauses, which is the trade-off Sam chose (2026-10-13).
    @Test func modelWideningANegationIsNotUsed() async {
        let spoken = "Do not\u{2014}ever go, go away."
        ChatFixture.replies = ["Do not\u{2014}ever go away.", "Do not\u{2014}ever go away."]; ChatFixture.delay = 0
        ChatFixture.requests = 0; ChatFixture.finish = "stop"
        let outcome = await strictCleanup()
            .clean(spoken, rules: spoken, context: CleanupContext(), vocabulary: vocabulary, key: "fixture")
        #expect(outcome.model == nil)
        #expect(outcome.text == spoken)
    }
    @Test func technicalTextIsNeverSent() async {
        ChatFixture.replies = ["echo hello"]; ChatFixture.delay = 0; ChatFixture.requests = 0; ChatFixture.finish = "stop"
        let command = "echo \"hello um world\" | tee out.txt"
        let outcome = await AICleanup(protocolClasses: [ChatFixture.self])
            .clean(command, rules: command, context: CleanupContext(app: "Terminal"), vocabulary: vocabulary, key: "fixture")
        #expect(outcome.text == command)
        #expect(outcome.model == nil)
        #expect(outcome.note == "technical text")
        #expect(ChatFixture.requests == 0)
        #expect(AICleanup.terminals.contains("com.apple.Terminal"))
    }
    @Test func requestCarriesOnlyAppNameAndDictionaryAndDeniesDataCollection() throws {
        let body = AICleanup.requestBody(AICleanup.models[0], raw: raw, context: CleanupContext(app: "Mail"),
                                         vocabulary: vocabulary)
        let provider = try #require(body["provider"] as? [String: Any])
        #expect(provider["data_collection"] as? String == "deny")
        #expect(provider["order"] as? [String] == ["Groq", "Cerebras"])
        let messages = try #require(body["messages"] as? [[String: String]])
        let user = try #require(messages.last?["content"])
        #expect(user.contains("App: Mail"))
        #expect(user.contains("CursusVox"))
        #expect(!user.contains("before cursor"))
        #expect(user.contains("<transcript>\n\(raw)\n</transcript>"))
    }
}

@Test func smartPromptKeepsCorrectionsWhenTakeBacksAreOff() {
    let off = AICleanup.smartInstructions(takeBacks: [])
    #expect(off.contains("Keep self-corrections as spoken"))
    #expect(!off.contains("keep only the final version"))
    #expect(!off.contains("merge it into one natural sentence"))
    let on = AICleanup.smartInstructions(takeBacks: TakeBack.defaults)
    #expect(on.contains("merge it into one natural sentence"))
    #expect(on.contains(TakeBack.defaults[0]))
}

@Test func strictRequestUsesStrictInstructions() throws {
    let words = Vocabulary(terms: [], takeBacks: TakeBack.defaults)
    let body = AICleanup.requestBody(AICleanup.models[0], raw: "hello", context: CleanupContext(app: "Cursor"),
        vocabulary: words, smart: false)
    let messages = try #require(body["messages"] as? [[String: String]])
    #expect(messages.first?["content"] == AICleanup.instructions(takeBacks: words.takeBacks))
    #expect(messages.first?["content"] != AICleanup.smartInstructions(takeBacks: words.takeBacks))
}

// Opt-in live check of the shipped cleanup path against OpenRouter:
// CURSUS_LIVE_CLEANUP=<input.json> CURSUS_LIVE_OUT=<out.md> with OPENROUTER_API_KEY set.
// Input: [{"app": "...", "heard": "..."}]. Writes heard / rules / AI rows, model and timing.
@MainActor @Test func liveCleanupForReview() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let input = env["CURSUS_LIVE_CLEANUP"], let output = env["CURSUS_LIVE_OUT"],
          let key = env["OPENROUTER_API_KEY"], !key.isEmpty else { return }
    let cases = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: input)))
        as? [[String: String]])
    let cleanup = AICleanup()
    var report = "| app | heard (Grok) | after rules | after AI | model · ms |\n|---|---|---|---|---|\n"
    for item in cases {
        let heard = item["heard"] ?? ""
        let rules = TranscriptCleanup.rules(heard, vocabulary: vocabulary)
        let outcome = await cleanup.clean(rules, rules: rules, context: CleanupContext(app: item["app"]),
                                          vocabulary: vocabulary, key: key)
        let cell = { (s: String) in s.replacingOccurrences(of: "|", with: "\\|") }
        report += "| \(item["app"] ?? "") | \(cell(heard)) | \(cell(rules)) | \(cell(outcome.text)) | "
            + "\(outcome.model ?? "rules (\(outcome.note ?? ""))") · \(outcome.millis) |\n"
    }
    try report.write(toFile: output, atomically: true, encoding: .utf8)
}

@Test func recordingFactsExpireWithTheRecoveryWindow() {
    let facts = LocalSpeech.Facts(generation: 1, raw: "heard", engine: .cloud, speechMillis: 1, fallback: nil,
                                  cleanup: nil, at: 100)
    #expect(!facts.expired(now: 100 + Policy.recoveryLifetime - 1))
    #expect(facts.expired(now: 100 + Policy.recoveryLifetime))
}

// Model bench helper (opt-in). CURSUS_BENCH_PREPARE=<out.json>: writes the exact system
// prompt and user message the app sends for each case in CURSUS_LIVE_CLEANUP.
// CURSUS_BENCH_JUDGE=<results.json> CURSUS_BENCH_VERDICTS=<out.json>: runs the app's guard
// on each model reply. No network; the calls themselves are made by the bench script.
@MainActor @Test func cleanupBenchHelper() throws {
    let env = ProcessInfo.processInfo.environment
    let vocabulary = Vocabulary(terms: Vocabulary.seed, replacements: Vocabulary.seedReplacements,
                                takeBacks: TakeBack.defaults)
    if let out = env["CURSUS_BENCH_PREPARE"], let input = env["CURSUS_LIVE_CLEANUP"] {
        let cases = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: input)))
            as? [[String: String]])
        let prepared = cases.map { item -> [String: String] in
            let rules = TranscriptCleanup.rules(item["heard"] ?? "", vocabulary: vocabulary)
            return ["heard": item["heard"] ?? "", "rules": rules,
                    "system": AICleanup.instructions(takeBacks: vocabulary.takeBacks),
                    "user": AICleanup.message(rules, context: CleanupContext(app: item["app"]), vocabulary: vocabulary)]
        }
        try JSONSerialization.data(withJSONObject: prepared, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: out))
    }
    if let input = env["CURSUS_BENCH_JUDGE"], let out = env["CURSUS_BENCH_VERDICTS"] {
        let rows = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: input)))
            as? [[String: Any]])
        let verdicts = rows.map { row -> [String: Any] in
            var result = row
            let output = row["output"] as? String ?? ""
            switch TranscriptCleanup.judge(raw: row["rules"] as? String ?? "", output: output, vocabulary: vocabulary) {
            case .accepted: result["verdict"] = "accepted"
            case let .rejected(reason): result["verdict"] = reason
            }
            result["changed"] = output.trimmingCharacters(in: .whitespacesAndNewlines) != (row["rules"] as? String ?? "")
            return result
        }
        try JSONSerialization.data(withJSONObject: verdicts, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: out))
    }
}

@Test func chosenCleanupModelGoesFirstWithTheRecommendedBackup() {
    #expect(AICleanup.order(choosing: nil) == AICleanup.models)
    #expect(AICleanup.order(choosing: "openai/gpt-oss-120b") == AICleanup.models)
    let free = AICleanup.freeModels[0]
    #expect(AICleanup.order(choosing: free.id) == [free, AICleanup.catalog[0]])
    // Only a model whose sole endpoints train on prompts may send text to them, and the picker says so.
    let body = AICleanup.requestBody(free, raw: "hi", context: CleanupContext(app: nil), vocabulary: Vocabulary(terms: []))
    #expect((body["provider"] as? [String: Any])?["data_collection"] as? String == "allow")
    #expect(free.name.contains("trains"))
    let paid = AICleanup.requestBody(AICleanup.catalog[0], raw: "hi", context: CleanupContext(app: nil),
                                     vocabulary: Vocabulary(terms: []))
    #expect((paid["provider"] as? [String: Any])?["data_collection"] as? String == "deny")
    #expect(AICleanup.catalog.filter { !$0.trains }.allSatisfy { !$0.name.contains("trains") })
}

@Test func miniMaxFlashIsAvailableAndCustomModelsJoinTheCatalog() {
    let minimax = AICleanup.freeModels[0]
    #expect(minimax.id == "minimax/minimax-m3.1-flash:free")
    #expect(minimax.reasoning == "low")
    #expect(minimax.trains)
    #expect(AICleanup.customModel("minimax/minimax-m3.1-flash") == minimax)
    let custom = AICleanup.customModel("openrouter/custom-fast:free")
    #expect(custom?.id == "openrouter/custom-fast:free")
    #expect(custom?.trains == true)
    let ordered = AICleanup.order(choosing: "openrouter/custom-fast:free", custom: "openrouter/custom-fast:free")
    #expect(ordered.map(\.id) == ["openrouter/custom-fast:free", AICleanup.catalog[0].id])
}

@Test func captureGateRecoversAfterStaleLeaseExpiry() {
    let gate = CaptureGate()
    let t1 = gate.begin(now: 100.0)
    #expect(t1 != nil)
    #expect(gate.begin(now: 100.5) == nil)
    let t2 = gate.begin(now: 102.5)
    #expect(t2 != nil)
    gate.end(t1)
    gate.end(t2)
    #expect(gate.tryBegin())
    gate.end()
}

@MainActor @Test func topBarDictionaryTabAndQuickAddWorkDirectly() {
    let panel = HomePanel()
    var stored: (terms: [String], replacements: [String: String]) = (terms: [], replacements: [:])
    panel.savedDictionary = { stored }
    panel.saveDictionary = { stored = $0 }
    panel.select(.dictionary)
    panel.quickWordField.stringValue = "my widget -> MyWidget"
    panel.quickAddWord()
    #expect(stored.terms.contains("MyWidget"))
    #expect(stored.replacements["my widget"] == "MyWidget")
    #expect(panel.quickWordField.stringValue.isEmpty)
}

@MainActor func strictCleanup() -> AICleanup {
    let cleanup = AICleanup(protocolClasses: [ChatFixture.self]); cleanup.smart = false; return cleanup
}

@Test func duplicateClipboardCompletionCannotReleaseAnotherExpiredRead() throws {
    let gate = CaptureGate()
    let first = try #require(gate.begin(now: 0))
    let second = try #require(gate.begin(now: 3))
    let third = try #require(gate.begin(now: 6))
    #expect(gate.begin(now: 9) == nil)
    gate.end(first)
    gate.end(first)
    let fourth = try #require(gate.begin(now: 9))
    #expect(gate.begin(now: 12) == nil)
    gate.end(second); gate.end(third); gate.end(fourth)
}
