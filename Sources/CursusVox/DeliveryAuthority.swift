import CursusCore

struct DeliveryAuthority: Sendable {
    let controllerGeneration: UInt64
    let recoveryGeneration: UInt64
    func valid(controller: UInt64, recovery: UInt64?, secure: Bool) -> Bool {
        // Stop can retain an older transcript. New controller activity must
        // still revoke an operation admitted against that earlier recovery.
        controller == controllerGeneration
            && recovery == recoveryGeneration && !secure
    }
}
