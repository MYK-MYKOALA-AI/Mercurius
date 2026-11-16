import Foundation

// Legacy macOS Keychain interaction policy is process-wide. Serialize this
// app's readers and restore the previous policy before returning a credential.
enum KeychainInteraction {
    private static let lock = NSLock()
    static func perform<Value>(allow: Bool, get: () -> Bool?, set: (Bool) -> Bool,
                               body: () -> Value) -> Value? {
        lock.withLock {
            guard let previous = get(), set(allow) else { return nil }
            let result = body()
            guard set(previous) else { return nil }
            return result
        }
    }
}
