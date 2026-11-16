import AVFoundation
import Foundation
import Speech
import Testing
import CursusCore
@testable import CursusVox

private final class RedirectResponseFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://fixture.invalid/redirect",
                           "Content-Length": "22"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"text\":\"must reject\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class RedirectDecision: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = false
    private var followed = false
    func record(_ request: URLRequest?) { lock.withLock { observed = true; followed = request != nil } }
    var refused: Bool { lock.withLock { observed && !followed } }
}

@MainActor @Test func cloudRejectsRedirectResponseThroughOwnedHTTPFixture() async throws {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16,
        sampleRate: 16_000, channels: 1, interleaved: true))
    let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
    pcm.frameLength = 160
    let samples = try #require(pcm.int16ChannelData?[0])
    for index in 0..<160 { samples[index] = 0 }
    let budget = AudioBudget()
    let batch = AudioBatch(input: AnalyzerInput(buffer: pcm), lease: try budget.reserve(320), budget: budget)
    let cloud = CloudSpeech(protocolClasses: [RedirectResponseFixture.self])
    var attempts: [UsageEvent] = []; cloud.usage = { attempts.append($0) }
    do {
        _ = try await cloud.transcribe(batch, key: "synthetic-fixture-key")
        Issue.record("A redirect response must never become a transcript")
    } catch CloudFailure.status(302) { /* Expected: status checked before text parsing. */ }
    #expect(attempts.count == 2)
    #expect(attempts.first?.id == attempts.last?.id)
    #expect(attempts.last?.outcome == .failed)
    #expect(attempts.last?.charge == nil)
    #expect(budget.allocatedBytes == 320)
}

@Test func cloudRedirectDelegateNeverForwardsRequestOrCredential() {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let origin = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!
    var redirected = URLRequest(url: URL(string: "https://fixture.invalid/redirect")!)
    redirected.setValue("Bearer synthetic-fixture-key", forHTTPHeaderField: "Authorization")
    let response = HTTPURLResponse(url: origin, statusCode: 302, httpVersion: "HTTP/1.1",
        headerFields: ["Location": redirected.url!.absoluteString])!
    let decision = RedirectDecision()
    NoCredentialRedirects().urlSession(session, task: session.dataTask(with: URLRequest(url: origin)),
        willPerformHTTPRedirection: response, newRequest: redirected) { decision.record($0) }
    #expect(decision.refused)
}

@Test func largerDictionaryKeepsCleanupContextWhileGrokHintsStayBounded() throws {
    let terms = (1...Vocabulary.maxTerms).map { "Project\($0)x" }
    let vocabulary = Vocabulary(terms: terms)
    let body = CloudSpeech.requestBody(audioBase64: "AAAA", keyterms: [" ", terms[0]] + terms)
    let provider = try #require(body["provider"] as? [String: Any])
    let options = try #require((provider["options"] as? [String: Any])?["xai"] as? [String: Any])
    let hints = try #require(options["keyterm"] as? [String])
    #expect(hints == Array(terms.prefix(100)))
    #expect(vocabulary.terms.count == 500)
    #expect(CloudSpeech.oneStepInstructions(keyterms: vocabulary.terms).contains("Project500x"))
    #expect(AICleanup.message("Use Project500x", context: CleanupContext(), vocabulary: vocabulary).contains("Project500x"))
}

@Test func cloudRequestSendsKeyTermsAndRemovesFillersThroughXAIOptions() throws {
    let body = CloudSpeech.requestBody(audioBase64: "AAAA", keyterms: ["CursusVox", "Supabase"])
    #expect(body["model"] as? String == "x-ai/grok-stt-1.0")
    #expect(body["language"] as? String == "en")
    let provider = try #require(body["provider"] as? [String: Any])
    #expect(provider["data_collection"] as? String == "deny")
    let xai = try #require((provider["options"] as? [String: Any])?["xai"] as? [String: Any])
    #expect(xai["filler_words"] as? Bool == false)
    #expect(xai["format"] as? Bool == true)
    #expect(xai["keyterm"] as? [String] == ["CursusVox", "Supabase"])
    let none = CloudSpeech.requestBody(audioBase64: "AAAA", keyterms: [])
    let noTerms = ((none["provider"] as? [String: Any])?["options"] as? [String: Any])?["xai"] as? [String: Any]
    #expect(noTerms?["keyterm"] == nil)
    #expect(JSONSerialization.isValidJSONObject(body))
    // A picked non-Grok engine: its id goes through, privacy stays deny, and the
    // xAI-only key terms are absent by design (the UI says so).
    let other = CloudSpeech.requestBody(audioBase64: "AAAA", keyterms: ["CursusVox"],
                                        model: "openai/whisper-large-v3-turbo")
    #expect(other["model"] as? String == "openai/whisper-large-v3-turbo")
    let otherProvider = try #require(other["provider"] as? [String: Any])
    #expect(otherProvider["data_collection"] as? String == "deny")
    #expect(otherProvider["options"] == nil)
    #expect(otherProvider["order"] as? [String] == ["Groq"])
    let mistral = CloudSpeech.requestBody(audioBase64: "AAAA", keyterms: [], model: "mistralai/voxtral-mini-3b-2507")
    #expect((mistral["provider"] as? [String: Any])?["order"] == nil)
}

private final class BilledSpeechFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"text":"hello","usage":{"cost":0.012}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class BilledBlankSpeechFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"text":"  ","choices":[{"finish_reason":"stop","message":{"content":"  "}}],"usage":{"cost":0.012}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor @Test func blankRetryKeepsItsChargeAndSavedAudio() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("blank-retry-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let outbox = AudioOutbox(directory: directory)
    let speech = LocalSpeech(credentialRead: { "synthetic-fixture-key" })
    defer { speech.shutdown() }
    speech.select(.cloud)
    for _ in 0..<100 where !speech.cloudCredentialReady { try await Task.sleep(for: .milliseconds(10)) }
    #expect(speech.cloudCredentialReady)
    for oneStep in [false, true] {
        let item = try #require(outbox.save(Data(repeating: 0, count: 364)))
        let result = try #require(await speech.retry(item, oneStep: oneStep, outbox: outbox,
            protocolClasses: [BilledBlankSpeechFixture.self]))
        #expect(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(result.costUSD == 0.012)
        #expect(outbox.list().contains(item))
        let charged = DeliveryRecord.addToDay(speech: result.costUSD, cleanup: nil, count: false,
            day: nil, total: 0, dictations: 0, now: Date())
        #expect(charged.cost == 0.012)
        #expect(charged.total == 0.012)
        #expect(charged.dictations == 0)
    }
}

@MainActor @Test func cloudAndRetryKeepTheProvidersReportedCost() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("retry-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let outbox = AudioOutbox(directory: directory)
    let wav = Data(repeating: 0, count: 364)
    let cloud = CloudSpeech(protocolClasses: [BilledSpeechFixture.self])
    let response = try await cloud.transcribe(wav: wav, key: "synthetic-fixture-key")
    #expect(response.costUSD == 0.012)
    let speech = LocalSpeech(credentialRead: { "synthetic-fixture-key" })
    defer { speech.shutdown() }
    speech.select(.cloud)
    for _ in 0..<100 where !speech.cloudCredentialReady { try await Task.sleep(for: .milliseconds(10)) }
    #expect(speech.cloudCredentialReady)
    let item = try #require(outbox.save(wav))
    let result = try #require(await speech.retry(item, oneStep: false, outbox: outbox,
        protocolClasses: [BilledSpeechFixture.self]))
    #expect(result.text == "hello")
    #expect(result.costUSD == 0.012)
    #expect(outbox.list() == [item])
    outbox.discard(item) // The orchestration owns consumption after cleanup.
    #expect(outbox.list().isEmpty)
    // A stale row or repeated click cannot transcribe and count a consumed recording again.
    #expect(await speech.retry(item, oneStep: false, outbox: outbox,
        protocolClasses: [BilledSpeechFixture.self]) == nil)
    let failedItem = try #require(outbox.save(wav))
    #expect(await speech.retry(failedItem, oneStep: false, outbox: outbox,
        protocolClasses: [RedirectResponseFixture.self]) == nil)
    #expect(outbox.list() == [failedItem])
}

private final class ChargedErrorFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!,statusCode: 402,httpVersion: "HTTP/1.1",headerFields: nil)!
        client?.urlProtocol(self,didReceive: response,cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self,didLoad: Data(#"{"usage":{"cost":0.025},"error":"owned-fixture"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor @Test func reportedChargeOnHTTPFailureRemainsInUsageLedger() async {
    let cloud = CloudSpeech(protocolClasses: [ChargedErrorFixture.self]); var events: [UsageEvent] = []
    cloud.usage = { events.append($0) }
    do { _ = try await cloud.transcribe(wav: Data(repeating: 0,count: 364),key: "owned-fixture") }
    catch { }
    #expect(events.count == 2); #expect(events.last?.outcome == .failed); #expect(events.last?.charge == 0.025)
}
