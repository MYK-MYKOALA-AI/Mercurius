// No key material enters policy. Closing a form cannot release an in-flight Keychain operation.
public struct CredentialSetup: Equatable, Sendable {
    public enum Event: Equatable, Sendable { case opened, edited, closed, save(valid: Bool), completed }
    public private(set) var isSaving = false
    public init() {}
    @discardableResult public mutating func receive(_ event: Event) -> Bool {
        switch event {
        case .opened, .edited, .closed: return false
        case let .save(valid):
            guard valid, !isSaving else { return false }
            isSaving = true; return true
        case .completed:
            isSaving = false; return false
        }
    }
}
