/// Only an explicit setup action can admit a permission request.
public struct PermissionSetup: Sendable {
    public enum Permission: Sendable, CaseIterable { case microphone, speech, accessibility, inputMonitoring }
    public enum Event: Sendable {
        case opened, refreshed, request(Permission), completed(Permission), handedOff(Permission), resumed
    }
    public private(set) var pending: Permission?
    public private(set) var awaitingSettings = false

    public init() {}

    public mutating func receive(_ event: Event) -> Permission? {
        switch event {
        case .opened, .refreshed: return nil
        case let .request(permission):
            guard pending == nil else { return nil }
            pending = permission
            return permission
        case let .completed(permission):
            if pending == permission { pending = nil; awaitingSettings = false }
            return nil
        case let .handedOff(permission):
            if pending == permission { awaitingSettings = true }
            return nil
        case .resumed:
            if awaitingSettings { pending = nil; awaitingSettings = false }
            return nil
        }
    }
}
