import CursusCore

enum PillContent: Equatable {
    case starting, listening, transcribing
    case done(String), failed(String)
    case blockedDelivery(recoveryGeneration: UInt64, controllerGeneration: UInt64)
    case delivered(status: String, transcript: String)
    case busy(String)   // non-dictation work in progress ("Clipping page…")

    var isTerminal: Bool {
        switch self { case .done, .delivered, .failed, .blockedDelivery: true; default: false }
    }
    func allowsRecoveryCopy(recoveryGeneration: UInt64?, controllerGeneration: UInt64) -> Bool {
        guard case let .blockedDelivery(recovery, controller) = self else { return false }
        return recovery == recoveryGeneration && controller == controllerGeneration
    }

}

// What the recording pill shows. Active states follow the controller; the
// result is shown briefly after delivery finishes.
enum PillDisplay {
    static let blockedMessage = "Couldn't paste. Click to copy this transcript, or open Clipboard."
    static func active(_ state: State) -> PillContent? {
        switch state {
        case .startingHeld, .startingToggle: .starting
        case .recordingHeld, .recordingToggle: .listening
        case .finalizing, .delivering: .transcribing
        case .idle, .recoverableError: nil
        }
    }
    // One honest phrase about the AI pass, for the result popup and History. nil: nothing worth saying.
    static func cleanupStatus(_ outcome: CleanupOutcome?) -> String? {
        guard let outcome else { return nil }
        if outcome.model != nil { return "cleaned" }
        guard let note = outcome.note else { return nil }
        switch note {
        case "technical text": return "code left as spoken"
        case "AI cleanup off": return "cleanup off"
        case "nothing to clean", "snippet expanded": return nil
        case "skipped after speech fallback": return "not cleaned: speech fell back"
        case "cleanup key unavailable": return "not cleaned: no OpenRouter key"
        case _ where note.contains("one-step"): return nil
        case _ where note.contains("rejected"): return "not cleaned: model changed your words"
        case _ where note.contains("timed out") || note.contains("budget") || note == "no time left": return "not cleaned: timed out"
        case _ where note.contains("HTTP 402"): return "not cleaned: out of credit"
        default: return "not cleaned: model failed"
        }
    }
    // noTextField: the focused element was seen and takes no text.
    // grokOff: Grok was chosen but its key couldn't be read, so the user should know why quality dropped.
    static func result(_ outcomes: [Outcome], onDevice: Bool, noTextField: Bool = false,
                       grokOff: Bool = false, transcript: String? = nil, cleanup: CleanupOutcome? = nil,
                       recoveryGeneration: UInt64? = nil, controllerGeneration: UInt64? = nil) -> PillContent? {
        let pasted: [Outcome] = [.pasteSentUnconfirmed, .insertedConfirmed, .insertedUnconfirmed]
        if outcomes.contains(where: pasted.contains) {
            let submission = outcomes.contains(.insertedConfirmed) ? "Inserted"
                : outcomes.contains(.insertedUnconfirmed) ? "Insertion sent · check editor" : "Paste sent · check editor"
            let base = onDevice
                ? submission + (grokOff ? " · on-device, Grok is off (click the menu icon)" : " · on-device")
                : submission
            let status = cleanupStatus(cleanup).map { base + " · " + $0 } ?? base
            if outcomes.contains(.recognized), let transcript, !transcript.isEmpty {
                let preview = String(transcript.prefix(240)) + (transcript.count > 240 ? "…" : "")
                return .delivered(status: status, transcript: preview)
            }
            return .done(status)
        }
        if outcomes.contains(.copied) {
            let base = noTextField ? "Copied, no text field — ⌘V to paste" : "Copied — ⌘V to paste"
            return .done(cleanupStatus(cleanup).map { base + " · " + $0 } ?? base)
        }
        if outcomes.contains(.deliveryBlocked) {
            if let recoveryGeneration, let controllerGeneration {
                return .blockedDelivery(recoveryGeneration: recoveryGeneration, controllerGeneration: controllerGeneration)
            }
            return .failed("Couldn't paste. Open Clipboard to copy or retry.")
        }
        return nil
    }
}
