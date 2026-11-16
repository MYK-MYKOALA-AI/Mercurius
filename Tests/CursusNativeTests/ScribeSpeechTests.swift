import Foundation
import Testing
@testable import CursusVox

private final class ScribeFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let valid = request.url?.host == "api.elevenlabs.io"
            && request.value(forHTTPHeaderField: "xi-api-key") == "synthetic-fixture-key"
            && request.value(forHTTPHeaderField: "Authorization") == nil
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: valid ? 200 : 401,
            httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"text":" hello from Scribe "}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func scribeMultipartKeepsAudioVerbatimAndDisablesEvents() throws {
    let wav = Data([0, 1, 255, 3])
    let body = ScribeSpeech.multipart(wav: wav, boundary: "fixture")
    #expect(body.range(of: wav) != nil)
    let text = String(decoding: body, as: UTF8.self)
    #expect(text.contains("name=\"model_id\"\r\n\r\nscribe_v2\r\n"))
    #expect(text.contains("name=\"tag_audio_events\"\r\n\r\nfalse\r\n"))
    #expect(text.hasSuffix("\r\n--fixture--\r\n"))
    #expect(ScribeSpeech.parseText(Data(#"{"text":7}"#.utf8)) == nil)
}

@MainActor @Test func scribeResponseAndRetryUseDirectCredentialWithoutDollarEstimate() async throws {
    let adapter = ScribeSpeech(protocolClasses: [ScribeFixture.self])
    #expect(try await adapter.transcribe(wav: Data([0]), key: "synthetic-fixture-key") == "hello from Scribe")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-retry-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let outbox = AudioOutbox(directory: directory)
    let speech = LocalSpeech(credentialRead: { nil }, scribeCredentialRead: { "synthetic-fixture-key" })
    defer { speech.shutdown() }
    speech.elevenLabsDirect = true
    speech.select(.cloud)
    for _ in 0..<100 where !speech.cloudCredentialReady { try await Task.sleep(for: .milliseconds(10)) }
    #expect(speech.cloudCredentialReady)
    #expect(speech.openRouterKey == nil)
    let item = try #require(outbox.save(Data(repeating: 0, count: 364)))
    let result = try #require(await speech.retry(item, oneStep: false, outbox: outbox, protocolClasses: [ScribeFixture.self]))
    #expect(result.text == "hello from Scribe")
    #expect(result.costUSD == nil)
    #expect(outbox.list() == [item]) // Caller discards only after cleanup and recovery presentation.
    speech.select(.apple)
    #expect(speech.elevenLabsKey == nil)
}

@Test func scribeHistorySeparatesCreditsFromCleanupCharges() {
    let facts = LocalSpeech.Facts(generation: 1, raw: "fixture", engine: .cloud, speechMillis: 100,
        fallback: nil, cleanup: CleanupOutcome(text: "fixture", model: "openai/gpt-oss-120b", millis: 10,
            note: nil, cost: 0.001), at: 0, speechModel: ScribeSpeech.modelID, speechCredits: true)
    #expect(Application.costLine(facts) == "ElevenLabs credits · gpt-oss-120b $0.0010")
    #expect(Application.badge(facts).hasPrefix("ElevenLabs Scribe"))
    let spends = Application.spends(facts)
    #expect(ModelCosts.addUnknown(spends, to: [], day: nil, today: "fixture").isEmpty)
    #expect(ModelCosts.summary([ScribeSpeech.modelID: 0]) == "ElevenLabs credits")
    let retry = DeliveryRecord.retry(oneStep: false, heardSpeech: true, cost: nil,
        model: ScribeSpeech.modelID, direct: true)
    #expect(retry.engine == "elevenlabs-direct")
    #expect(retry.speechModel == ScribeSpeech.modelID)
    #expect(retry.costUSD == nil)
}

@Test func dictionaryTermsReachScribeAsKeyterms() throws {
    let body = ScribeSpeech.multipart(wav: Data([0]), boundary: "fixture", keyterms: ["MyKoala", "T3 Code"])
    let text = String(decoding: body, as: UTF8.self)
    #expect(text.contains("name=\"keyterms\"\r\n\r\nMyKoala\r\n"))
    #expect(text.contains("name=\"keyterms\"\r\n\r\nT3 Code\r\n"))
    #expect(!String(decoding: ScribeSpeech.multipart(wav: Data([0]), boundary: "fixture"), as: UTF8.self).contains("keyterms"))
}
@Test func keytermsOutsideElevenLabsLimitsAreLeftOut() {
    let long = String(repeating: "a", count: 51)
    #expect(ScribeSpeech.usableKeyterms(["ok", long, "one two three four five", "one two three four five six", ""]) == ["ok", "one two three four five"])
    #expect(ScribeSpeech.usableKeyterms(Array(repeating: "x", count: 1200)).count == 1000)
}
