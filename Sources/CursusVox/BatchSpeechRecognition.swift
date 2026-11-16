import AVFoundation
import Speech
import CursusCore

@MainActor enum BatchSpeechRecognition {
    static func transcribe(_ source: AudioBatch, analyzer: SpeechAnalyzer,
                           transcriber: SpeechTranscriber, format: AVAudioFormat) async throws -> String {
        let batch = try NativeAudio.compatible(source, format: format)
        let results = Task<String, Error> {
            var text = ""
            for try await result in transcriber.results {
                try Task.checkCancellation()
                guard result.isFinal else { continue }
                let segment = String(result.text.characters)
                let separator = text.isEmpty || segment.isEmpty ? "" : " "
                guard segment.utf8.count + separator.utf8.count <= Policy.textLimit - text.utf8.count else {
                    throw AudioFailure.limit
                }
                text += separator + segment
            }
            return text
        }
        defer { results.cancel() }
        return try await withTaskCancellationHandler {
            let stream = AsyncStream<AnalyzerInput>(bufferingPolicy: .bufferingOldest(1)) { continuation in
                continuation.yield(batch.input)
                continuation.finish()
            }
            try Task.checkCancellation()
            try await analyzer.start(inputSequence: stream)
            try Task.checkCancellation()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let text = try await results.value
            try Task.checkCancellation()
            withExtendedLifetime(source) {}
            withExtendedLifetime(batch) {}
            return text
        } onCancel: {
            results.cancel()
        }
    }
}
