import Carbon

// Cancellation survives a lock/unlock or focus round trip. Recheck after an
// awaited observation before the caller may retain content or copy it.
@MainActor enum CaptureExecution {
    static func interrupt(_ task: Task<Void, Never>?, permit: EffectPermit?) {
        task?.cancel(); permit?.revoke()
    }
    static func allows(_ permit: EffectPermit, secureInput: () -> Bool = { IsSecureEventInputEnabled() },
                       current: () async -> Bool) async -> Bool {
        guard permit.valid, !Task.isCancelled, !secureInput() else { return false }
        let sameOrigin = await current()
        return sameOrigin && permit.valid && !Task.isCancelled && !secureInput()
    }
}
