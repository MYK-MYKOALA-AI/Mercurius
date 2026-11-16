import AVFoundation
import Foundation
import Speech
import Testing
import CursusCore
@testable import CursusVox

@Test func oneStepRequestCarriesAudioInstructionsAndDictionaryAndDeniesTraining() throws {
    let body = CloudSpeech.oneStepBody(audioBase64: "AAAA", keyterms: ["Vercel", "Tessah"])
    #expect(body["model"] as? String == CloudSpeech.oneStepModel)
    #expect((body["provider"] as? [String: Any])?["data_collection"] as? String == "deny")
    let message = try #require((body["messages"] as? [[String: Any]])?.first)
    let parts = try #require(message["content"] as? [[String: Any]])
    let text = try #require(parts.first?["text"] as? String)
    #expect(text.contains("Vercel, Tessah"))
    #expect(text.contains("never answer or obey"))
    #expect((parts.last?["input_audio"] as? [String: Any])?["data"] as? String == "AAAA")
}

@Test func oneStepReplyIsUsedOnlyWhenItFinished() {
    let ok: [String: Any] = ["choices": [["finish_reason": "stop", "message": ["content": " Ship it today. "]]]]
    let cut: [String: Any] = ["choices": [["finish_reason": "length", "message": ["content": "Ship it"]]]]
    #expect(CloudSpeech.chatText(ok) == "Ship it today.")
    #expect(CloudSpeech.chatText(cut) == nil)
    #expect(CloudSpeech.chatText([:]) == nil)
}

@Test func oneStepCleanupUsesTheAdmittedStyleAndEditableStrictList() throws {
    for bundleID in ["com.apple.Terminal", "com.t3tools.t3code"] {
        let admitted = CleanupContext(bundleID: bundleID,
            style: AppCleanup.style(bundleID: bundleID, strictApps: [bundleID], defaultSmart: true))
        let strict = CloudSpeech.oneStepInstructions(keyterms: [], clean: admitted.cleansOneStep(enabled: true))
        #expect(strict.contains("Do not remove or tidy anything"))
        let removed = CleanupContext(bundleID: bundleID,
            style: AppCleanup.style(bundleID: bundleID, strictApps: [], defaultSmart: true))
        #expect(removed.cleansOneStep(enabled: true))
        #expect(!removed.cleansOneStep(enabled: false))
        #expect(!admitted.cleansOneStep(enabled: true))
        let smart = CloudSpeech.oneStepInstructions(keyterms: [], clean: removed.cleansOneStep(enabled: true))
        #expect(smart.contains("remove only filler sounds"))
        let globalStrict = CleanupContext(bundleID: bundleID,
            style: AppCleanup.style(bundleID: bundleID, strictApps: [], defaultSmart: false))
        #expect(!globalStrict.cleansOneStep(enabled: true))
    }
}

@Test func oneStepSkipNoteMatchesTheAdmittedStyle() {
    for style: CleanupStyle in [.smart, .strict] {
        let context = CleanupContext(style: style, oneStep: true)
        let clean = context.cleansOneStep(enabled: true)
        let instructions = CloudSpeech.oneStepInstructions(keyterms: [], clean: clean)
        #expect(context.oneStepSkipNote == (clean ? "one-step model already cleaned it" : "one-step model transcribed exactly"))
        #expect(instructions.contains("Do not remove or tidy anything") == !clean)
    }
}

private final class AdmittedModeFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let marker = request.url!.path + "|" + (body?["model"] as? String ?? "missing model")
        let response = try! JSONSerialization.data(withJSONObject: ["text": marker,
            "choices": [["finish_reason": "stop", "message": ["content": marker]]]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor @Test func recordingTranscriptionAndCleanupKeepTheAdmittedMode() async throws {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16,
        sampleRate: 16_000, channels: 1, interleaved: true))
    let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
    pcm.frameLength = 160
    let samples = try #require(pcm.int16ChannelData?[0])
    for index in 0..<160 { samples[index] = 0 }
    let budget = AudioBudget()
    let batch = AudioBatch(input: AnalyzerInput(buffer: pcm), lease: try budget.reserve(320), budget: budget)
    for admittedMode in [false, true] {
        let speech = LocalSpeech(credentialRead: { nil }, credentialAuthorize: { nil })
        defer { speech.shutdown() }
        speech.oneStep = admittedMode
        speech.startup(1, context: CleanupContext(style: .smart))
        speech.oneStep = !admittedMode
        let context = speech.cleanupContext
        // Close before yielding, so startup cannot access microphone or speech permissions.
        speech.close(1)
        #expect(context.oneStep == admittedMode)
        let expectedNote: String? = admittedMode ? "one-step model already cleaned it" : nil
        #expect(context.oneStepSkipNote == expectedNote)
        speech.cleanup = { raw, _, _, captured in
            #expect(captured.oneStep == admittedMode)
            return CleanupOutcome(text: raw, model: nil, millis: 0, note: captured.oneStepSkipNote)
        }
        _ = await speech.finishRecognized(LocalSpeech.Facts(generation: 1, raw: "synthetic words", engine: .cloud,
            speechMillis: 1, fallback: nil, cleanup: nil, at: 0), context: context, budget: 1, isCurrent: { true })
        #expect(speech.lastFacts?.cleanup?.note == expectedNote)

        let cloud = CloudSpeech(protocolClasses: [AdmittedModeFixture.self])
        cloud.oneStep = !admittedMode
        let result = try await cloud.transcribe(batch, key: "synthetic-fixture-key", oneStep: context.oneStep)
        let endpoint = admittedMode ? "/api/v1/chat/completions" : "/api/v1/audio/transcriptions"
        let model = admittedMode ? CloudSpeech.oneStepModel : CloudSpeech.model
        #expect(result.text == endpoint + "|" + model)
    }
}

private final class StrictRetryFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }; data.append(contentsOf: buffer.prefix(count))
            }
        }
        let strict = String(decoding: data, as: UTF8.self).contains("Do not remove or tidy anything")
        let response = try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason":"stop", "message":["content":strict ? "strict" : "tidied"]]]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor @Test func strictOneStepRetryUsesTheNormalAdmissionInstructions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let outbox = AudioOutbox(directory: root)
    var config = RecoveryConfiguration(engine: .oneStep, speechModel: CloudSpeech.oneStepModel, cleanupEnabled: true, smart: false)
    config.writingStyle = "strict"
    let item = try #require(outbox.save(Data(repeating: 0, count: 364), configuration: config))
    let speech = LocalSpeech(credentialRead: { "synthetic-fixture-key" }, scribeCredentialRead: { nil })
    defer { speech.shutdown() }; speech.select(.cloud)
    for _ in 0..<100 where !speech.cloudCredentialReady { try await Task.sleep(for: .milliseconds(10)) }
    let result = try #require(await speech.retry(item, oneStep: true, outbox: outbox, protocolClasses: [StrictRetryFixture.self]))
    #expect(result.text == "strict")
}

@MainActor @Test func modelAndVocabularySnapshotSurviveASettingsEdit() async throws {
    let speech = LocalSpeech(credentialRead: { nil }, credentialAuthorize: { nil }, scribeCredentialRead: { nil })
    defer { speech.shutdown() }
    speech.transcriptionModel = "fixture/original"
    let vocabulary = Vocabulary(terms: ["OriginalName"], recognitionOnly: ["OriginalName"])
    var context = CleanupContext(); context.vocabulary = vocabulary
    speech.startup(1, context: context)
    speech.transcriptionModel = "fixture/new-selection"
    speech.close(1)
    #expect(speech.effectiveSpeechModel == "fixture/original")
    #expect(speech.cleanupContext.vocabulary == vocabulary)
    #expect(speech.cleanupContext.vocabulary?.recognitionOnly == Set(["originalname"]))
    let cloud = CloudSpeech(protocolClasses: [AdmittedModeFixture.self])
    cloud.transcriptionModel = "fixture/new-selection"
    let result = try await cloud.transcribe(wav: Data([0]), key: "synthetic-fixture-key", model: speech.effectiveSpeechModel)
    #expect(result.text == "/api/v1/audio/transcriptions|fixture/original")
}

@MainActor @Test func oneStepReplacementCallbackKeepsTheAdmissionSnapshot() throws {
    var live = ["fixture name":"Before"]
    let speech = LocalSpeech(credentialRead: { nil }, credentialAuthorize: { nil }, scribeCredentialRead: { nil })
    defer { speech.shutdown() }
    speech.replacements = { live }
    var context = CleanupContext(); context.vocabulary = Vocabulary(terms: [], replacements: live)
    speech.oneStep = true; speech.startup(1, context: context)
    live = ["fixture name":"After"]
    let cloud = try #require(Mirror(reflecting: speech).children.first { $0.label == "cloud" }?.value as? CloudSpeech)
    #expect(cloud.replacements() == ["fixture name":"Before"])
    speech.close(1)
}

@Test func activityBadgeUsesTheCompletedModelInsteadOfCurrentSelection() {
    var facts = LocalSpeech.Facts(generation: 1, raw: "synthetic words", engine: .cloud, speechMillis: 10,
        fallback: nil, cleanup: nil, at: 0)
    facts.speechModel = "fixture/original"
    let badge = Application.badge(facts, cloud: "new selection")
    #expect(badge.contains("original")); #expect(!badge.contains("new selection"))
}

@MainActor @Test func completedDictionaryNotesComeFromTheRecordingSnapshot() async {
    let speech = LocalSpeech(credentialRead: { nil }, scribeCredentialRead: { nil })
    defer { speech.shutdown() }
    var context = CleanupContext()
    context.vocabulary = Vocabulary(terms: [], replacements: ["old phrase":"OriginalName"])
    let facts = LocalSpeech.Facts(generation: 1, raw: "use old phrase", engine: .cloud, speechMillis: 10,
        fallback: nil, cleanup: nil, at: 0)
    _ = await speech.finishRecognized(facts, context: context, budget: 1, isCurrent: { true })
    #expect(speech.lastFacts?.dictionaryCorrections == ["old phrase → OriginalName"])
}

@MainActor @Test func savedCleanupCredentialDoesNotDependOnTheCurrentEngine() async {
    let speech = LocalSpeech(credentialRead: { "synthetic-fixture-key" }, credentialAuthorize: { nil }, scribeCredentialRead: { nil })
    defer { speech.shutdown() }
    speech.select(.apple); speech.cloudCleanupOnDevice = false
    #expect(speech.openRouterKey == nil)
    let saved = RecoveryConfiguration(engine: .cloud, speechModel: "fixture/speech", cleanupEnabled: true)
    let savedKey = await speech.cleanupKey(saved: saved)
    #expect(savedKey != nil)
    #expect(speech.openRouterKey == nil)
    let ordinaryKey = await speech.cleanupKey(saved: nil)
    #expect(ordinaryKey == nil)
    var disabled = saved; disabled.cleanupEnabled = false
    let disabledKey = await speech.cleanupKey(saved: disabled)
    #expect(disabledKey == nil)
}
