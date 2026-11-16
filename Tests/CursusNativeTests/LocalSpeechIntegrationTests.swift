import AVFoundation
import Foundation
import Speech
import Testing
import CursusCore
@testable import CursusVox

@Suite(.serialized) @MainActor struct AppleIntegration {

// Opt in only for the authored synthetic WAV fixtures included with these tests. No microphone,
// personal recording, download, legacy recognizer or cloud service is used here.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CURSUS_TEST_LOCAL_SPEECH"] == "1"))
@MainActor func appleSpeechRecognizesAuthoredSyntheticAudio() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let path = root.appendingPathComponent("Tests/CursusNativeTests/Fixtures/original-phrase.wav")
    let module = SpeechTranscriber(locale: Locale(identifier: "en-AU"), preset: .transcription)
    let existing = await AssetInventory.reservedLocales
    let locale = try #require(await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-AU")))
    let created = try await AssetInventory.reserve(locale: locale)
    let after = await AssetInventory.reservedLocales
    let owned = after.filter { candidate in !existing.contains(where: { $0.identifier == candidate.identifier }) }
    let analyzer = SpeechAnalyzer(modules: [module])
    do {
        #expect(await AssetInventory.status(forModules: [module]) == .installed)
        let format = try #require(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]))
        let file = try AVAudioFile(forReading: path, commonFormat: .pcmFormatInt16, interleaved: true)
        #expect(file.length > 0 && file.length <= 960_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length)))
        let budget = AudioBudget()
        let owner = try budget.reserve(Int(buffer.frameCapacity) * 2)
        try file.read(into: buffer)
        let batch = AudioBatch(input: AnalyzerInput(buffer: buffer), lease: owner, budget: budget)
        try await analyzer.prepareToAnalyze(in: format)
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(15)) }
            catch { return }
            await analyzer.cancelAndFinishNow()
        }
        defer { timeout.cancel() }
        let text = try await BatchSpeechRecognition.transcribe(batch, analyzer: analyzer,
            transcriber: module, format: format)
        #expect(!text.isEmpty)
        print("SYNTHETIC_TRANSCRIPT:", text)
        print("PCM_HIGH_WATER_BYTES:", budget.highWater)
        await analyzer.cancelAndFinishNow()
        if created { for locale in owned { #expect(await AssetInventory.release(reservedLocale: locale)) } }
    } catch {
        await analyzer.cancelAndFinishNow()
        if created { for locale in owned { #expect(await AssetInventory.release(reservedLocale: locale)) } }
        throw error
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CURSUS_TEST_LOCAL_SPEECH"] == "1"))
@MainActor func appleSpeechQualityUsesAllOriginalPhrases() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let locale = try #require(await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-AU")))
    let before = await AssetInventory.reservedLocales
    let created = try await AssetInventory.reserve(locale: locale)
    let after = await AssetInventory.reservedLocales
    let owned = after.filter { candidate in !before.contains(where: { $0.identifier == candidate.identifier }) }
    var hypotheses: [String?] = []
    for i in Quality.referencePhrases.indices {
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [module])
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            await analyzer.cancelAndFinishNow()
        }
        do {
            let file = try AVAudioFile(forReading: root.appendingPathComponent(String(format:
                "Tests/CursusNativeTests/Fixtures/quality-%02d.wav", i)), commonFormat: .pcmFormatInt16, interleaved: true)
            guard file.length > 0, file.length <= 960_000 else { throw AudioFailure.limit }
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                frameCapacity: UInt32(file.length)))
            let budget = AudioBudget()
            let owner = try budget.reserve(Int(buffer.frameCapacity) * 2)
            try file.read(into: buffer)
            let batch = AudioBatch(input: AnalyzerInput(buffer: buffer), lease: owner, budget: budget)
            let format = try #require(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]))
            try await analyzer.prepareToAnalyze(in: format)
            let text = try await BatchSpeechRecognition.transcribe(batch, analyzer: analyzer,
                transcriber: module, format: format)
            hypotheses.append(text)
        } catch {
            hypotheses.append(nil)
            Issue.record("Original phrase \(i) failed; included as deletions in quality score")
        }
        timeout.cancel()
        await analyzer.cancelAndFinishNow()
    }
    if created { for locale in owned { #expect(await AssetInventory.release(reservedLocale: locale)) } }
    let score = Quality.score(hypotheses)
    print("ORIGINAL_SYNTHETIC_QUALITY: words=\(score.referenceWords) edits=\(score.editCount) WER=\(score.wer)")
    #expect(score.meetsTarget)
}

}
