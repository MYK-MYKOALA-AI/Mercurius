import Foundation
import Speech

@MainActor private final class FileRecognitionAttempt {
    var continuation: CheckedContinuation<String?, Never>?
    var task: SFSpeechRecognitionTask?
    var timeout: Task<Void, Never>?
    func finish(_ text: String?) {
        guard let continuation else { return }
        self.continuation = nil; task?.cancel(); task = nil; timeout?.cancel(); timeout = nil
        continuation.resume(returning: text)
    }
}
@MainActor enum LocalFileRetry {
    static func transcribe(_ url: URL) async -> String? {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SpeechLanguageStore.recognitionOrder.compactMap({ SFSpeechRecognizer(locale: Locale(identifier: $0)) })
                .first(where: { $0.isAvailable && $0.supportsOnDeviceRecognition }) else { return nil }
        let attempt = FileRecognitionAttempt()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                attempt.continuation = continuation
                guard !Task.isCancelled else { attempt.finish(nil); return }
                let request = SFSpeechURLRecognitionRequest(url: url)
                request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = false
                attempt.task = recognizer.recognitionTask(with: request) { result, error in
                    let text = result?.isFinal == true ? result?.bestTranscription.formattedString : nil
                    let failed = error != nil
                    Task { @MainActor in
                        if let text { attempt.finish(text) } else if failed { attempt.finish(nil) }
                    }
                }
                attempt.timeout = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { return }; attempt.finish(nil)
                }
            }
        } onCancel: { Task { @MainActor in attempt.finish(nil) } }
    }
}
