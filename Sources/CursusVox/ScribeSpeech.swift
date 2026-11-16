import Foundation
import CursusCore

// Direct ElevenLabs Scribe transcription, billed to the user's ElevenLabs credits
// (never OpenRouter). The response carries no dollar cost, so callers record
// credits, not an invented price. Same bounds as the cloud engine: 10 s request,
// 512 KiB reply, no redirects (a redirect would leak the key header).
@MainActor final class ScribeSpeech {
    nonisolated static let model = "scribe_v2"
    nonisolated static let modelID = "elevenlabs-direct/scribe_v2"
    var usage: ((UsageEvent) -> Void)?
    var usageAdmission: ((UsageEvent) -> Bool)?
    var usageRecordingID: UUID?
    var usageOperation: UsageEvent.Operation = .speech
    private var activeSession: URLSession?
    private let protocolClasses: [AnyClass]?
    init(protocolClasses: [AnyClass]? = nil) { self.protocolClasses = protocolClasses }
    func cancel() { activeSession?.invalidateAndCancel(); activeSession = nil }

    func transcribe(_ batch: AudioBatch, key: String, keyterms: [String] = []) async throws -> String {
        let (wav, wavLease) = try NativeAudio.wav(batch)
        defer { withExtendedLifetime(wavLease) {}; withExtendedLifetime(batch) {} }
        return try await transcribe(wav: wav, key: key, keyterms: keyterms)
    }

    func transcribe(wav: Data, key: String, keyterms: [String] = []) async throws -> String {
        try Task.checkCancellation()
        guard CloudCredentials.validated(key) != nil else { throw AudioFailure.conversion }
        let boundary = "cursusvox-\(UUID().uuidString)"
        let body = Self.multipart(wav: wav, boundary: boundary, keyterms: keyterms)
        guard body.count <= 3 * 1024 * 1024, !Task.isCancelled else { throw AudioFailure.limit }
        let configuration = URLSessionConfiguration.ephemeral
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = CloudSpeech.requestTimeout
        configuration.timeoutIntervalForResource = CloudSpeech.requestTimeout
        let session = URLSession(configuration: configuration)
        activeSession = session
        defer { session.invalidateAndCancel(); if activeSession === session { activeSession = nil } }
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        var attempt = UsageEvent(recordingID: usageRecordingID, provider: "elevenlabs", model: Self.modelID, operation: usageOperation, unit: .credits)
        if let usageAdmission {
            guard usageAdmission(attempt) else { throw CloudFailure.accountingUnavailable }
        } else { usage?(attempt) }
        defer { if attempt.outcome == .interrupted { attempt.outcome = Task.isCancelled ? .cancelled : .failed }; usage?(attempt) }
        let (bytes, response) = try await session.bytes(for: request, delegate: NoCredentialRedirects())
        guard !Task.isCancelled, let response = response as? HTTPURLResponse else { throw AudioFailure.conversion }
        guard (200..<300).contains(response.statusCode) else { throw CloudFailure.status(response.statusCode) }
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

    // The personal dictionary biases recognition, so names come out right the first time.
    // ElevenLabs allows up to 1000 batch keyterms of 50 characters and 5 words each.
    nonisolated static func usableKeyterms(_ terms: [String]) -> [String] {
        Array(terms.filter { !$0.isEmpty && $0.count <= 50 && $0.split(whereSeparator: \.isWhitespace).count <= 5 && !$0.contains(where: \.isNewline) }.prefix(1000))
    }
    nonisolated static func multipart(wav: Data, boundary: String, keyterms: [String] = []) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model_id", model)
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
