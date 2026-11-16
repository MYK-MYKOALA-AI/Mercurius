import Foundation
import AVFoundation
import Speech
import Testing
@testable import CursusVox

@MainActor @Test func failedCommandAudioCannotEnterTheDictationOutbox() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("command-outbox-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let outbox = AudioOutbox(directory: directory)
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
    buffer.frameLength = 160
    buffer.int16ChannelData?.pointee.update(repeating: 0, count: 160)
    let budget = AudioBudget()
    let batch = AudioBatch(input: AnalyzerInput(buffer: buffer), lease: try budget.reserve(320), budget: budget)
    let command = LocalSpeech(credentialRead: { nil }, credentialAuthorize: { nil }, retention: .transient)
    let dictation = LocalSpeech(credentialRead: { nil }, credentialAuthorize: { nil })
    defer { command.shutdown(); dictation.shutdown() }
    #expect(!command.retainFailedAudio(batch, outbox: outbox))
    #expect(outbox.list().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    #expect(dictation.retainFailedAudio(batch, outbox: outbox))
    #expect(outbox.list().count == 1)
}
