import Foundation
import CursusCore

@MainActor enum ProviderBalance {
    // Explicit refreshes and the footer's credit figure use these non-inference endpoints. Never expose the raw response.
    static func refresh(elevenLabs: Bool, key: String) async -> String { await check(elevenLabs: elevenLabs,key: key).detail }
    static func check(elevenLabs: Bool,key: String) async -> (status: HealthStatus,detail: String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 8; configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let endpoint = elevenLabs ? "https://api.elevenlabs.io/v1/user/subscription" : "https://openrouter.ai/api/v1/key"
        var request = URLRequest(url: URL(string: endpoint)!)
        request.setValue(elevenLabs ? key : "Bearer " + key, forHTTPHeaderField: elevenLabs ? "xi-api-key" : "Authorization")
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: NoCredentialRedirects())
            guard let response = response as? HTTPURLResponse else { return (.unknown,"Provider status unknown") }
            guard (200..<300).contains(response.statusCode) else { return (.needsAttention,"Provider check HTTP \(response.statusCode). Check key permissions in Settings.") }
            var data = Data()
            for try await byte in bytes { guard data.count < 64*1024 else { return (.unknown,"Provider response exceeded limit") }; data.append(byte) }
            guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return (.unknown,"Invalid provider metadata") }
            return (.ready,summary(data, elevenLabs: elevenLabs) + " · checked \(Date().formatted())")
        } catch { return (.needsAttention,"Provider status unavailable. Check connection or key permissions.") }
    }
    // The footer's credit figure. Read-only; nil if the key can't read it.
    static func elevenLabsCredits(key: String) async -> (used: Int, limit: Int)? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 8; configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/user/subscription")!)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        guard let (data, response) = try? await session.data(for: request, delegate: NoCredentialRedirects()),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { return nil }
        return credits(data)
    }
    static func credits(_ data: Data) -> (used: Int, limit: Int)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let used = object["character_count"] as? Int, let limit = object["character_limit"] as? Int,
              used >= 0, limit > 0 else { return nil }
        return (used, limit)
    }
    static func summary(_ data: Data, elevenLabs: Bool) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "Provider balance unknown" }
        if elevenLabs {
            guard let used = object["character_count"] as? Int, let limit = object["character_limit"] as? Int,
                  used >= 0, limit >= 0 else { return "ElevenLabs allowance unknown" }
            return "ElevenLabs account allowance: \(used) used / \(limit) credits. Includes other apps."
        }
        guard let info = object["data"] as? [String: Any] else { return "OpenRouter key status unknown" }
        guard let remaining = info["limit_remaining"] as? Double, remaining.isFinite else {
            return "OpenRouter key has no reported remaining cap. This is not your account balance."
        }
        return "OpenRouter key cap remaining: \(ModelCosts.money(remaining)) USD. Includes other apps using this key."
    }
}
