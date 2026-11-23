import Foundation
import Testing
@testable import CursusVox
import CursusCore

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
    #expect(text.contains("name=\"model_id\"\r\n\r\nscribe_v3\r\n"))
    let older = String(decoding: ScribeSpeech.multipart(wav: wav, boundary: "fixture", model: "scribe_v2"), as: UTF8.self)
    #expect(older.contains("name=\"model_id\"\r\n\r\nscribe_v2\r\n"))
    // An unlisted id is never sent.
    let unknown = String(decoding: ScribeSpeech.multipart(wav: wav, boundary: "fixture", model: "eleven_v4"), as: UTF8.self)
    #expect(unknown.contains("name=\"model_id\"\r\n\r\nscribe_v3\r\n"))
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
            note: nil, cost: 0.001), at: 0, speechModel: ScribeSpeech.id("scribe_v3"), speechCredits: true)
    #expect(Application.costLine(facts) == "ElevenLabs credits · gpt-oss-120b $0.0010")
    #expect(Application.badge(facts).hasPrefix("ElevenLabs Scribe v3"))
    let spends = Application.spends(facts)
    #expect(ModelCosts.addUnknown(spends, to: [], day: nil, today: "fixture").isEmpty)
    #expect(ModelCosts.summary([ScribeSpeech.id("scribe_v3"): 0]) == "ElevenLabs credits")
    // History written before the picker named the old fixed model; it still reads as credits.
    #expect(ModelCosts.summary(["elevenlabs-direct/scribe_v2": 0]) == "ElevenLabs credits")
    let retry = DeliveryRecord.retry(oneStep: false, heardSpeech: true, cost: nil,
        model: ScribeSpeech.id("scribe_v3"), direct: true)
    #expect(retry.engine == "elevenlabs-direct")
    #expect(retry.speechModel == "elevenlabs-direct/scribe_v3")
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

@Test func scribeModelChoiceMapsSavedAndLegacyIDs() {
    #expect(ScribeSpeech.defaultModel == "scribe_v3")
    #expect(ScribeSpeech.model(nil) == "scribe_v3")
    #expect(ScribeSpeech.model("scribe_v2") == "scribe_v2")
    #expect(ScribeSpeech.model("elevenlabs-direct/scribe_v2") == "scribe_v2")
    #expect(ScribeSpeech.model("eleven_v4") == "scribe_v3")   // a text-to-speech model cannot transcribe
    #expect(ScribeSpeech.model("x-ai/grok-stt-2.0") == "scribe_v3")
    #expect(ScribeSpeech.displayName("elevenlabs-direct/scribe_v3") == "Scribe v3")
    #expect(ScribeSpeech.order("scribe_v2") == ["scribe_v2", "scribe_v3"])
    #expect(ScribeSpeech.isDirect("elevenlabs-direct/scribe_v2") && !ScribeSpeech.isDirect("x-ai/grok-stt-2.0") && !ScribeSpeech.isDirect(nil))
    #expect(Application.engineName("elevenlabs-direct/scribe_v2") == "ElevenLabs Scribe v2")
}

@Test func onlyAnUnsupportedModelRefusalCountsAsWithdrawn() {
    let refusal = #"{"detail":{"type":"validation_error","code":"unsupported_model","status":"invalid_model_id"}}"#
    #expect(ScribeSpeech.isUnsupportedModel(Data(refusal.utf8)))
    #expect(!ScribeSpeech.isUnsupportedModel(Data(#"{"detail":{"status":"invalid_audio"}}"#.utf8)))
    #expect(!ScribeSpeech.isUnsupportedModel(Data("not json".utf8)))
}

// Answers per model_id: scribe_v3 is refused as unsupported (or as bad audio), scribe_v2 transcribes.
private final class ScribeModelFixture: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var models: [String] = []
    nonisolated(unsafe) static var refuseAsAudio = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
        }
        let text = String(decoding: body, as: UTF8.self)
        let model = ScribeSpeech.catalog.first { text.contains("name=\"model_id\"\r\n\r\n\($0)\r\n") } ?? "none"
        Self.models.append(model)
        let refused = model == "scribe_v3"
        let reply = !refused ? #"{"text":"from \#(model)"}"#
            : Self.refuseAsAudio ? #"{"detail":{"status":"invalid_audio"}}"#
            : #"{"detail":{"code":"unsupported_model","status":"invalid_model_id"}}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: refused ? 400 : 200,
            httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor @Test func aWithdrawnScribeModelMovesToTheNextAndRecordsIt() async throws {
    ScribeModelFixture.models = []; ScribeModelFixture.refuseAsAudio = false
    let adapter = ScribeSpeech(protocolClasses: [ScribeModelFixture.self])
    var events: [UsageEvent] = []
    adapter.usage = { events.append($0) }
    #expect(try await adapter.transcribe(wav: Data([0]), key: "synthetic-fixture-key") == "from scribe_v2")
    #expect(ScribeModelFixture.models == ["scribe_v3", "scribe_v2"])
    #expect(adapter.lastModel == "scribe_v2")
    #expect(events.filter { $0.outcome == .failed }.map(\.model) == ["elevenlabs-direct/scribe_v3"])
    #expect(events.filter { $0.outcome == .succeeded }.map(\.model) == ["elevenlabs-direct/scribe_v2"])

    // Any other 400 is an error, not a reason to spend credits on a second model.
    ScribeModelFixture.models = []; ScribeModelFixture.refuseAsAudio = true
    await #expect(throws: CloudFailure.self) { try await adapter.transcribe(wav: Data([0]), key: "synthetic-fixture-key") }
    #expect(ScribeModelFixture.models == ["scribe_v3"])
}

@MainActor @Test func aSavedScribeRecordingRetriesWithTheModelItWasAdmittedWith() async throws {
    ScribeModelFixture.models = []; ScribeModelFixture.refuseAsAudio = false
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-model-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let outbox = AudioOutbox(directory: directory)
    let speech = LocalSpeech(credentialRead: { nil }, scribeCredentialRead: { "synthetic-fixture-key" })
    defer { speech.shutdown() }
    speech.elevenLabsDirect = true
    speech.scribeModel = "scribe_v3"   // the current choice differs from the recording's
    speech.select(.cloud)
    for _ in 0..<100 where !speech.cloudCredentialReady { try await Task.sleep(for: .milliseconds(10)) }
    let item = try #require(outbox.save(Data(repeating: 0, count: 364),
        configuration: RecoveryConfiguration(engine: .elevenLabs, speechModel: ScribeSpeech.id("scribe_v2"))))
    let result = try #require(await speech.retry(item, oneStep: false, outbox: outbox, protocolClasses: [ScribeModelFixture.self]))
    #expect(result.text == "from scribe_v2")
    #expect(ScribeModelFixture.models == ["scribe_v2"])
    speech.select(.apple)
}
