import Foundation
import CursusCore

// Direct ElevenLabs Scribe transcription, billed to the user's ElevenLabs credits
// (never OpenRouter). The response carries no dollar cost, so callers record
// credits, not an invented price. Same bounds as the cloud engine: 10 s request,
// 512 KiB reply, no redirects (a redirect would leak the key header).
@MainActor final class ScribeSpeech {
    // Batch Scribe models offered in Settings, newest first. ElevenLabs accepted both on
    // 2026-11-23; its docs put scribe_v3 at 27% fewer word errors than scribe_v2 (FLEURS).
    // Realtime models (scribe_v3_live) stream over a WebSocket and are not batch models.
    nonisolated static let catalog = ["scribe_v3", "scribe_v2"]
    nonisolated static let defaultModel = catalog[0]
    // Usage, History and recovery store "elevenlabs-direct/<model>".
    nonisolated static let idPrefix = "elevenlabs-direct/"
    nonisolated static func id(_ model: String) -> String { idPrefix + model }
    nonisolated static func isDirect(_ id: String?) -> Bool { id?.hasPrefix(idPrefix) == true }
    // A saved choice or a recording's frozen id, back to a listed model; anything else is the default.
    nonisolated static func model(_ saved: String?) -> String {
        guard var name = saved else { return defaultModel }
        if name.hasPrefix(idPrefix) { name.removeFirst(idPrefix.count) }
        return catalog.contains(name) ? name : defaultModel
    }
    // "scribe_v3" -> "Scribe v3"
    nonisolated static func displayName(_ model: String) -> String {
        let name = model.hasPrefix(idPrefix) ? String(model.dropFirst(idPrefix.count)) : model
        guard name.hasPrefix("scribe_") else { return name }
        return "Scribe " + name.dropFirst("scribe_".count).replacingOccurrences(of: "_", with: " ")
    }
    // The picked model first; a model ElevenLabs no longer supports moves to the next.
    nonisolated static func order(_ model: String) -> [String] {
        [model] + catalog.filter { $0 != model }
    }
    var model = defaultModel
    // The model that produced the last transcript.
    private(set) var lastModel = defaultModel
    var usage: ((UsageEvent) -> Void)?
    var usageAdmission: ((UsageEvent) -> Bool)?
    var usageRecordingID: UUID?
    var usageOperation: UsageEvent.Operation = .speech
    private var activeSession: URLSession?
    private let protocolClasses: [AnyClass]?
    init(protocolClasses: [AnyClass]? = nil) { self.protocolClasses = protocolClasses }
    func cancel() { activeSession?.invalidateAndCancel(); activeSession = nil }

    // Lowered while Scribe backs up OpenRouter, so both share one request deadline.
    var timeout = CloudSpeech.requestTimeout
    func transcribe(_ batch: AudioBatch, key: String, keyterms: [String] = []) async throws -> String {
        let (wav, wavLease) = try NativeAudio.wav(batch)
        defer { withExtendedLifetime(wavLease) {}; withExtendedLifetime(batch) {} }
        return try await transcribe(wav: wav, key: key, keyterms: keyterms)
    }

    func transcribe(wav: Data, key: String, keyterms: [String] = []) async throws -> String {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var refused: Error = CloudFailure.status(400)
        for candidate in Self.order(model) {
            let left = deadline - ProcessInfo.processInfo.systemUptime
            guard left > 0 else { break }
            do {
                let text = try await request(wav: wav, key: key, keyterms: keyterms, model: candidate, timeout: left)
                lastModel = candidate
                return text
            } catch ScribeRefusal.unsupportedModel {
                refused = CloudFailure.status(400)
            }
        }
        throw refused
    }

    private func request(wav: Data, key: String, keyterms: [String], model: String, timeout: TimeInterval) async throws -> String {
        try Task.checkCancellation()
        guard CloudCredentials.validated(key) != nil else { throw AudioFailure.conversion }
        let boundary = "cursusvox-\(UUID().uuidString)"
        let body = Self.multipart(wav: wav, boundary: boundary, keyterms: keyterms, model: model)
        guard body.count <= 3 * 1024 * 1024, !Task.isCancelled else { throw AudioFailure.limit }
        let configuration = URLSessionConfiguration.ephemeral
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        activeSession = session
        defer { session.invalidateAndCancel(); if activeSession === session { activeSession = nil } }
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        var attempt = UsageEvent(recordingID: usageRecordingID, provider: "elevenlabs", model: Self.id(model), operation: usageOperation, unit: .credits)
        if let usageAdmission {
            guard usageAdmission(attempt) else { throw CloudFailure.accountingUnavailable }
        } else { usage?(attempt) }
        defer { if attempt.outcome == .interrupted { attempt.outcome = Task.isCancelled ? .cancelled : .failed }; usage?(attempt) }
        let (bytes, response) = try await session.bytes(for: request, delegate: NoCredentialRedirects())
        guard !Task.isCancelled, let response = response as? HTTPURLResponse else { throw AudioFailure.conversion }
        guard (200..<300).contains(response.statusCode) else {
            // Only a 400 body is read (at most 8 KiB), to tell a withdrawn model from bad audio.
            if response.statusCode == 400 {
                var refusal = Data()
                for try await byte in bytes { guard !Task.isCancelled, refusal.count < 8 * 1024 else { break }; refusal.append(byte) }
                if Self.isUnsupportedModel(refusal) { throw ScribeRefusal.unsupportedModel }
            }
            throw CloudFailure.status(response.statusCode)
        }
        guard response.expectedContentLength <= 512 * 1024 else { throw AudioFailure.conversion }
        var data = Data()
        for try await byte in bytes {
            guard !Task.isCancelled, data.count < 512 * 1024 else { throw AudioFailure.limit }
            data.append(byte)
        }
        guard !Task.isCancelled, let text = Self.parseText(data),
              text.utf8.count <= Policy.textLimit else { throw AudioFailure.conversion }
        attempt.outcome = .succeeded
        return text
    }

    // ElevenLabs answers an unknown model_id with HTTP 400 and
    // {"detail":{"code":"unsupported_model","status":"invalid_model_id",...}}. Only this
    // refusal moves to the next model; a bad key, credits or audio stays an error.
    nonisolated static func isUnsupportedModel(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"] as? [String: Any] else { return false }
        return detail["code"] as? String == "unsupported_model" || detail["status"] as? String == "invalid_model_id"
    }

    // The personal dictionary biases recognition, so names come out right the first time.
    // ElevenLabs allows up to 1000 batch keyterms of 50 characters and 5 words each.
    nonisolated static func usableKeyterms(_ terms: [String]) -> [String] {
        Array(terms.filter { !$0.isEmpty && $0.count <= 50 && $0.split(whereSeparator: \.isWhitespace).count <= 5 && !$0.contains(where: \.isNewline) }.prefix(1000))
    }
    nonisolated static func multipart(wav: Data, boundary: String, keyterms: [String] = [], model: String = defaultModel) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model_id", Self.model(model))
        field("language_code", "eng")
        field("tag_audio_events", "false")
        field("timestamps_granularity", "none")
        for term in usableKeyterms(keyterms) { field("keyterms", term) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    // Scribe answers {"text": "...", "language_code": "eng", ...}; only the text is used.
    nonisolated static func parseText(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum ScribeRefusal: Error { case unsupportedModel }
