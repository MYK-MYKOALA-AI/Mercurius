import AppKit
import AVFoundation
import ApplicationServices
import Speech

// Explicit local verification command, not part of normal launch. No permission
// prompt, transcription, file recording or network access occurs in this check.
@MainActor enum NativeDiagnostics {
    // Authored WAV fixture only: exercises partial recognition before ending input.
    // No microphone, network fallback, transcript log or retained audio file.
    static func verifyLivePreview(_ path: String) async -> Int32 {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            print("LIVE_PREVIEW_UNTESTED speech permission missing"); return 2
        }
        let preview = LivePreview()
        let budget = AudioBudget()
        let began = ProcessInfo.processInfo.systemUptime
        var firstPartialMillis: Int?
        preview.changed = {
            if !preview.isEmpty, firstPartialMillis == nil {
                firstPartialMillis = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
            }
        }
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatInt16, interleaved: true)
            guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
                  file.length > 0, file.length <= 960_000 else { throw AudioFailure.format }
            let tap = preview.begin()
            while file.framePosition < file.length {
                let lease = try budget.reserve(3200)
                guard let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1600) else { throw AudioFailure.limit }
                try file.read(into: chunk, frameCount: 1600)
                tap(chunk, lease)
                try await Task.sleep(for: .milliseconds(100))
                if let millis = firstPartialMillis, file.framePosition < file.length {
                    let locale = preview.localeIdentifier ?? "unknown"
                    await preview.end().value
                    print("LIVE_PREVIEW_PASS locale=\(locale) first_partial_ms=\(millis) before_end=true pcm_peak_bytes=\(budget.highWater)")
                    return 0
                }
            }
            await preview.end().value
            print("LIVE_PREVIEW_FAILED no partial text before end of fixture")
            return 1
        } catch {
            await preview.end().value
            print("LIVE_PREVIEW_FAILED fixture or recognition unavailable")
            return 1
        }
    }
    // Synthetic presentation check only. No microphone, clipboard or field access.
    // Yield to AppKit before checking WindowServer; isVisible alone can pass for
    // a panel that never reached the active desktop.
    static func verifyPillPresentation() async -> Int32 {
        await Task.detached(priority: .userInitiated) { await KoaFrames.shared.load() }.value
        guard KoaClip.allCases.allSatisfy({ !KoaFrames.shared.images($0).isEmpty }) else {
            print("PILL_PRESENTATION_FAILED missing_mascot_frames=true"); return 1
        }
        let pill = RecordingPill()
        pill.reduceMotion = { true }
        defer { pill.hide() }
        func presented(_ stage: String) async -> Bool {
            try? await Task.sleep(for: .milliseconds(500))
            let panel = pill.panel
            let onScreen = RecordingPill.isOnScreen(panel)
            let active = panel.isOnActiveSpace
            let unoccluded = panel.occlusionState.contains(.visible)
            let geometry = NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) }
            let passed = panel.isVisible && panel.alphaValue > 0.95 && geometry && active && unoccluded && onScreen
            print("PILL_PRESENTATION_STAGE stage=\(stage) window_visible=\(panel.isVisible) frame_on_screen=\(geometry) active_space=\(active) unoccluded=\(unoccluded) window_server_onscreen=\(onScreen)")
            return passed
        }
        pill.show(.starting, now: ProcessInfo.processInfo.systemUptime)
        guard await presented("starting") else { print("PILL_PRESENTATION_FAILED stage=starting"); return 1 }
        pill.show(.listening, now: ProcessInfo.processInfo.systemUptime)
        pill.preview(settled: "Synthetic popup check", volatile: "")
        guard await presented("listening"), pill.mascotVisible, pill.waveformVisible, !pill.shownPreview.isEmpty else {
            print("PILL_PRESENTATION_FAILED stage=listening"); return 1
        }
        pill.panel.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        pill.show(.listening, now: ProcessInfo.processInfo.systemUptime)
        guard await presented("offscreen") else { print("PILL_PRESENTATION_FAILED stage=offscreen"); return 1 }
        pill.hide()
        pill.show(.starting, now: ProcessInfo.processInfo.systemUptime)
        guard await presented("restart"), pill.shownPreview.isEmpty else {
            print("PILL_PRESENTATION_FAILED stage=restart"); return 1
        }
        pill.preview(settled: "", volatile: "", unavailable: .permission)
        guard !pill.shownPreview.isEmpty else {
            print("PILL_PRESENTATION_FAILED stage=preview-status"); return 1
        }
        guard await presented("preview-status") else { print("PILL_PRESENTATION_FAILED stage=preview-status"); return 1 }
        print("PILL_PRESENTATION_PASS window_server_onscreen=true active_space=true unoccluded=true restart=true preview_status=true pixels_unverified=true")
        return 0
    }

    static func verifyPermissions() {
        let microphone: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = "authorized"
        case .notDetermined: microphone = "notDetermined"
        case .denied: microphone = "denied"
        case .restricted: microphone = "restricted"
        @unknown default: microphone = "unknown"
        }
        let speech: String
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speech = "authorized"
        case .notDetermined: speech = "notDetermined"
        case .denied: speech = "denied"
        case .restricted: speech = "restricted"
        @unknown default: speech = "unknown"
        }
        let statuses: [String: Any] = ["microphone": microphone, "speech": speech,
            "accessibility": AXIsProcessTrusted(), "inputMonitoring": CGPreflightListenEventAccess(),
            "postEventAccess": CGPreflightPostEventAccess()]
        if let data = try? JSONSerialization.data(withJSONObject: statuses, options: .sortedKeys),
           let text = String(data: data, encoding: .utf8) { print("PERMISSION_STATUS", text) }
    }
    static func verifyCapture() async -> Int32 {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            print("CAPTURE_CHECK_UNTESTED: microphone permission not granted")
            return 2
        }
        let audio = NativeAudio()
        defer { audio.close() }
        do {
            try audio.prepare()
            try audio.start()
            try await Task.sleep(for: .seconds(2))
            let batch = try audio.finish()
            guard batch.frames > 0 else { throw AudioFailure.empty }
            print("CAPTURE_CHECK_PASS frames=\(batch.frames) pcm_peak_bytes=\(audio.budget.highWater)")
            return 0
        } catch {
            print("CAPTURE_CHECK_FAILED: no audio retained")
            return 1
        }
    }
}
