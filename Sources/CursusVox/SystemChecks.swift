import AppKit
import AVFoundation
import ApplicationServices
import Speech

// Live, read-only checks behind the setup checklist. Nothing here writes system
// settings; buttons only request a grant or open the matching Settings pane.
@MainActor enum SystemChecks {
    private nonisolated static let wisprBundleIDs: Set<String> = [
        "com.electron.wispr-flow", "com.electron.wispr-flow.accessibility-mac-app"
    ]
    static var microphone: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var microphoneUndecided: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined }
    static var speech: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }
    static var globeKeyFree: Bool {
        globeKeyIsFree(CFPreferencesCopyAppValue("AppleFnUsageType" as CFString,
                                                  "com.apple.HIToolbox" as CFString) as? Int)
    }
    static var wisprRunning: Bool {
        wisprRunning(bundleIDs: NSWorkspace.shared.runningApplications.map(\.bundleIdentifier))
    }
    static var requiredGranted: Bool {
        requiredGranted(microphone: microphone, accessibility: accessibility, inputMonitoring: inputMonitoring)
    }

    // System Settings › Keyboard › "Press 🌐 key to". 0 is Do Nothing. Apple does
    // not document the other values; any of them makes macOS act on the key.
    nonisolated static func globeKeyIsFree(_ usage: Int?) -> Bool { usage == 0 }
    nonisolated static func wisprRunning(bundleIDs: [String?]) -> Bool {
        bundleIDs.contains { $0.map(wisprBundleIDs.contains) == true }
    }
    nonisolated static func requiredGranted(microphone: Bool, accessibility: Bool, inputMonitoring: Bool) -> Bool {
        microphone && accessibility && inputMonitoring
    }

    static func openPrivacy(_ anchor: String) {
        open("x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
    static func openKeyboard() { open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension") }
    private static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}
