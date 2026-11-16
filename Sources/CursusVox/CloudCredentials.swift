import Foundation
import Security
import LocalAuthentication

enum CloudCredentials {
    private static let service = "au.com.mykoala.mercurius.openrouter"
    private static let account = "OpenRouter API key"
    private static let elevenLabsService = "au.com.mykoala.mercurius.elevenlabs"
    private static let elevenLabsAccount = "ElevenLabs API key"
    enum Provider: String, CaseIterable, Sendable { case openRouter = "OpenRouter", elevenLabs = "ElevenLabs" }
    static func itemQuery(for provider: Provider) -> [String: Any] {
        provider == .openRouter ? query : query(service: elevenLabsService, account: elevenLabsAccount)
    }
    // Explicit in-app Save uses the same exact Keychain identities as provisioning.
    static func save(_ value: String, provider: Provider) -> OSStatus {
        let result: OSStatus? = KeychainInteraction.perform(allow: true, get: {
            var previous: DarwinBoolean = false
            guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess else { return nil }
            return previous.boolValue
        }, set: { SecKeychainSetUserInteractionAllowed($0) == errSecSuccess }) {
            persist(value, provider: provider, add: { SecItemAdd($0, nil) }, update: { SecItemUpdate($0, $1) })
        }
        return result ?? errSecInteractionNotAllowed
    }
    // Injected Security operations keep fixtures away from the real Keychain.
    static func persist(_ value: String, provider: Provider, add: (CFDictionary) -> OSStatus,
                        update: (CFDictionary, CFDictionary) -> OSStatus) -> OSStatus {
        guard let value = validated(value), let data = value.data(using: .utf8) else { return errSecParam }
        let query = itemQuery(for: provider)
        var item = query
        item[kSecValueData as String] = data
        let status = add(item as CFDictionary)
        return status == errSecDuplicateItem ? update(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) : status
    }
    static func validated(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 4096,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0)
                  || CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }
    private static var query: [String: Any] { query(service: service, account: account) }
    private static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
    // Called only by conscious cloud selection. No enumeration, browser store,
    // synced secret file or unrelated Keychain item is read by this app.
    static func load() -> String? { read(allowInteraction: false) }
    static func loadElevenLabs() -> String? {
        read(allowInteraction: false, query: query(service: elevenLabsService, account: elevenLabsAccount))
    }
    // Only an explicit credential-setup action may request OS authorisation.
    static func authorize() -> String? { read(allowInteraction: true) }
    static func authorizeElevenLabs() -> String? {
        read(allowInteraction: true, query: query(service: elevenLabsService, account: elevenLabsAccount))
    }
    private static func read(allowInteraction: Bool, query: [String: Any] = CloudCredentials.query) -> String? {
        let result: String?? = KeychainInteraction.perform(allow: allowInteraction, get: {
            var previous: DarwinBoolean = false
            guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess else { return nil }
            return previous.boolValue
        }, set: { SecKeychainSetUserInteractionAllowed($0) == errSecSuccess }) {
            var request = query
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            // LAContext governs modern authentication. The scoped legacy policy
            // above also covers this app's existing login-Keychain item.
            let authentication = LAContext()
            authentication.interactionNotAllowed = !allowInteraction
            request[kSecUseAuthenticationContext as String] = authentication
            var value: CFTypeRef?
            guard SecItemCopyMatching(request as CFDictionary, &value) == errSecSuccess,
                  let data = value as? Data else { return nil }
            return validated(String(data: data, encoding: .utf8))
        }
        return result ?? nil
    }
    // The installer receives only the existing credential in its environment.
    // Keep it out of arguments, logs, configuration and the application bundle.
    static func installFromEnvironment(rebindAccess: Bool = false) -> OSStatus {
        install(environment: "OPENROUTER_API_KEY", query: query, rebindAccess: rebindAccess)
    }
    static func installElevenLabsFromEnvironment() -> OSStatus {
        install(environment: "ELEVENLABS_API_KEY", query: query(service: elevenLabsService, account: elevenLabsAccount))
    }
    private static func install(environment name: String, query: [String: Any], rebindAccess: Bool = false) -> OSStatus {
        guard let key = validated(ProcessInfo.processInfo.environment[name]),
              let data = key.data(using: .utf8) else { return errSecParam }
        var updates: [String: Any] = [kSecValueData as String: data]
        if rebindAccess {
            // Only explicit signing migration replaces the old app's ACL.
            // Routine credential provisioning preserves existing access decisions.
            guard let executable = Bundle.main.executableURL else { return errSecParam }
            var application: SecTrustedApplication?
            let trusted = SecTrustedApplicationCreateFromPath(executable.path, &application)
            guard trusted == errSecSuccess, let application else { return trusted }
            var access: SecAccess?
            let created = SecAccessCreate("Mercurius OpenRouter" as CFString, [application] as CFArray, &access)
            guard created == errSecSuccess, let access else { return created }
            updates[kSecAttrAccess as String] = access
        }
        var item = query
        item.merge(updates, uniquingKeysWith: { _, value in value })
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        }
        return status
    }
}
