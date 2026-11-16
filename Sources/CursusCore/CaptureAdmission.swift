import Foundation

// Capture is a separate authority from insertion: absence of a readable identity refuses a read.
public enum CaptureAdmission {
    public enum Refusal: String, Equatable, Sendable {
        case secureInput, excludedApplication, unavailableWindow, changedOrigin, cancelled
    }
    public enum Outcome: Equatable, Sendable { case allowed, refused(Refusal) }
    public struct Origin: Equatable, Sendable {
        public let process: String
        public let window: String
        public let document: String?
        public let title: String
        public init(process: String, window: String, document: String?, title: String) {
            self.process = process; self.window = window; self.document = document; self.title = title
        }
    }
    public static func admit(classification: Classification, secureInput: Bool, credentialApplication: Bool,
                             knownProcess: Bool, windowAvailable: Bool) -> Outcome {
        if secureInput { return .refused(.secureInput) }
        if classification != .normal || credentialApplication { return .refused(.excludedApplication) }
        if !knownProcess || !windowAvailable { return .refused(.unavailableWindow) }
        return .allowed
    }
    public static func revalidate(_ origin: Origin, current: Origin?, admission: Outcome, cancelled: Bool) -> Outcome {
        if cancelled { return .refused(.cancelled) }
        guard admission == .allowed else { return admission }
        return current == origin ? .allowed : .refused(.changedOrigin)
    }
    public static func readableFocus(role: String?, subrole: String?) -> Bool {
        if let subrole, ["AXUnknown", "AXUnknownRole", "AXUnknownSubrole"].contains(subrole) { return false }
        guard let role, !role.isEmpty, role != "AXUnknown", role != "AXUnknownRole", role != "AXSecureTextField", subrole != "AXSecureTextField" else { return false }
        return role != "AXTextField" || (subrole != nil && subrole?.isEmpty == false)
    }
    public static func samePage(expected: String?, observed: String?) -> Bool {
        expected?.isEmpty == false && expected == observed
    }
    public static func isCredentialApplication(name: String?, bundleID: String? = nil) -> Bool {
        if let bundleID {
            let id = bundleID.lowercased()
            if id == "com.apple.passwords"
                || id == "com.apple.keychainaccess"
                || id.contains("1password")
                || id.contains("bitwarden")
                || id.contains("dashlane")
                || id.contains("keepass")
                || id.contains("lastpass")
                || id.contains("keepersecurity")
                || id.contains("enpass") || id.contains("proton.pass") || id.contains("nordpass")
                || id.contains("roboform") || id.contains("strongbox") || id.contains("macpass") { return true }
        }
        guard let name else { return false }
        let normalized = name.lowercased()
        return ["passwords", "keychain access", "1password", "bitwarden", "dashlane", "keepassxc",
                "enpass", "proton pass", "nordpass", "roboform", "strongbox", "macpass"].contains(normalized)
    }
}
