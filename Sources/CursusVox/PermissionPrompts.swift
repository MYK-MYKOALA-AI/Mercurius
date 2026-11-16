import AppKit
import AVFoundation
import Speech
import CursusPlatform
import CursusCore

@MainActor final class PermissionPrompts {
    enum Outcome { case completed, settingsOpened }
    private var setup = PermissionSetup()
    private let perform: (PermissionSetup.Permission) async -> Outcome
    var changed: (() -> Void)?
    var isRequesting: Bool { setup.pending != nil }
    var awaitingSettings: Bool { setup.awaitingSettings }

    init(perform: @escaping (PermissionSetup.Permission) async -> Outcome = PermissionPrompts.perform) {
        self.perform = perform
    }

    func receive(_ event: PermissionSetup.Event) async {
        // Completion belongs to the operation that owns the pending request.
        switch event {
        case .completed, .handedOff: return
        case .resumed:
            guard setup.awaitingSettings else { return }
            _ = setup.receive(event); changed?(); return
        default: break
        }
        guard let permission = setup.receive(event) else { return }
        changed?()
        guard !Task.isCancelled else {
            _ = setup.receive(.completed(permission)); changed?(); return
        }
        let outcome = await perform(permission)
        _ = setup.receive(outcome == .settingsOpened ? .handedOff(permission) : .completed(permission))
        changed?()
    }

    private static func perform(_ permission: PermissionSetup.Permission) async -> Outcome {
        switch permission {
        case .microphone:
            if SystemChecks.microphoneUndecided {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            } else if !SystemChecks.microphone {
                SystemChecks.openPrivacy("Privacy_Microphone")
                return .settingsOpened
            }
        case .speech:
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    let reply: @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void = { _ in done.resume() }
                    SFSpeechRecognizer.requestAuthorization(reply)
                }
            } else if !SystemChecks.speech {
                SystemChecks.openPrivacy("Privacy_SpeechRecognition")
                return .settingsOpened
            }
        case .accessibility:
            guard !SystemChecks.accessibility else { return .completed }
            _ = CursusRequestAccessibilityTrust()
            SystemChecks.openPrivacy("Privacy_Accessibility")
            return .settingsOpened
        case .inputMonitoring:
            guard !SystemChecks.inputMonitoring else { return .completed }
            _ = CGRequestListenEventAccess()
            SystemChecks.openPrivacy("Privacy_ListenEvent")
            return .settingsOpened
        }
        return .completed
    }
}
