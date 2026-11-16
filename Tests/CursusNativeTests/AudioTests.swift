import AVFoundation
import Foundation
import Speech
import Testing
@testable import CursusVox

private func fixture(rate: Double = 16_000, frames: UInt32 = 1600) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16,
        sampleRate: rate, channels: 1, interleaved: true))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try #require(buffer.int16ChannelData?[0])
    for i in 0..<Int(frames) { samples[i] = Int16(sin(Double(i) * 0.1) * 1000) }
    return buffer
}

@Test func pcmOwnersReleaseBudgetAndRejectOverflow() throws {
    let budget = AudioBudget()
    var owner: AudioLease? = try budget.reserve(AudioBudget.limit)
    #expect(owner?.bytes == AudioBudget.limit)
    #expect(budget.allocatedBytes == AudioBudget.limit)
    #expect(throws: AudioFailure.self) { try budget.reserve(1) }
    owner = nil
    #expect(budget.allocatedBytes == 0)
    #expect(budget.highWater == AudioBudget.limit)
    #expect(throws: AudioFailure.self) { try budget.reserve(0) }
    #expect(throws: AudioFailure.self) { try budget.reserve(-1) }
}

@Test func previewBufferKeepsItsLeaseAfterTheSideArrayIsCleared() throws {
    let budget = AudioBudget()
    let held = HeldLeases()
    var buffer: AVAudioPCMBuffer? = try fixture()
    held.add(try budget.reserve(3200), buffer: try #require(buffer))
    held.clear()
    #expect(budget.allocatedBytes == 3200)
    buffer = nil
    #expect(budget.allocatedBytes == 0)
}

@Test func previewLeasesHaveNoRollingEviction() throws {
    let budget = AudioBudget()
    let held = HeldLeases()
    for _ in 0...LivePreview.queueLimit {
        held.add(try budget.reserve(2), buffer: try fixture(frames: 1))
    }
    #expect(budget.allocatedBytes == (LivePreview.queueLimit + 1) * 2)
    held.clear()
    #expect(budget.allocatedBytes == 0)
}

@MainActor @Test func endingPreviewDoesNotReleaseARetainedQueuedBuffer() async throws {
    let budget = AudioBudget()
    let preview = LivePreview()
    var buffer: AVAudioPCMBuffer? = try fixture()
    let tap = preview.begin()
    tap(try #require(buffer), try budget.reserve(3200))
    await preview.end().value
    // Teardown has released its side array; the test still owns the PCM buffer.
    #expect(budget.allocatedBytes == 3200)
    // A tap retained by the audio worker must refuse chunks after end.
    tap(try fixture(), try budget.reserve(3200))
    #expect(budget.allocatedBytes == 3200)
    buffer = nil
    #expect(budget.allocatedBytes == 0)
}

@MainActor private final class PreviewDrainGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

@MainActor @Test func previewLeasesReleaseAfterDrainOrDeadline() async throws {
    let budget = AudioBudget()
    let held = HeldLeases()
    held.add(try budget.reserve(3200), buffer: try fixture())
    let gate = PreviewDrainGate()
    let drained = LivePreview.releaseLeases(held, deadline: .seconds(60)) { await gate.wait() }
    #expect(budget.allocatedBytes == 3200)
    gate.open()
    await drained.value
    #expect(budget.allocatedBytes == 0)

    var retained: AVAudioPCMBuffer? = try fixture()
    held.add(try budget.reserve(3200), buffer: try #require(retained))
    held.add(try budget.reserve(3200), buffer: try fixture())
    let stuck = PreviewDrainGate()
    let deadline = LivePreview.releaseLeases(held, deadline: .milliseconds(5)) { await stuck.wait() }
    #expect(budget.allocatedBytes == 6400)
    await deadline.value
    #expect(budget.allocatedBytes == 3200)
    retained = nil
    #expect(budget.allocatedBytes == 0)
    stuck.open()
}

@Test @MainActor func wavHeaderMatchesAuthoredPCMAndOwnership() throws {
    let buffer = try fixture()
    let budget = AudioBudget()
    let owner = try budget.reserve(Int(buffer.frameCapacity) * 2)
    let batch = AudioBatch(input: AnalyzerInput(buffer: buffer), lease: owner, budget: budget)
    do {
        let (wav, wavOwner) = try NativeAudio.wav(batch)
        #expect(wav.count == 3244)
        #expect(String(data: wav.prefix(4), encoding: .utf8) == "RIFF")
        #expect(String(data: wav[8..<16], encoding: .utf8) == "WAVEfmt ")
        #expect(String(data: wav[36..<40], encoding: .utf8) == "data")
        #expect(wav[40..<44].elementsEqual([0x80, 0x0c, 0, 0]))
        #expect(budget.allocatedBytes == 6444)
        withExtendedLifetime(wavOwner) {}
    }
    #expect(budget.allocatedBytes == 3200)
}

@Test @MainActor func providerConversionPreservesFullDuration() throws {
    let buffer = try fixture()
    let budget = AudioBudget()
    let owner = try budget.reserve(Int(buffer.frameCapacity) * 2)
    let batch = AudioBatch(input: AnalyzerInput(buffer: buffer), lease: owner, budget: budget)
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16,
        sampleRate: 8_000, channels: 1, interleaved: true))
    let result = try NativeAudio.compatible(batch, format: format)
    #expect(result.input.buffer.format == format)
    #expect(result.frames == 800)
    #expect(budget.highWater <= AudioBudget.limit)
}

@Test func captureConversionDrainsTailAndReleasesScratch() throws {
    let buffer = try fixture(rate: 48_000, frames: 4800)
    let budget = AudioBudget()
    let accumulator = try AudioAccumulator(source: buffer.format, budget: budget)
    accumulator.append(buffer)
    let batch = try accumulator.seal()
    #expect(batch.frames == 1600)
    #expect(batch.input.buffer.format.sampleRate == 16_000)
    #expect(budget.allocatedBytes == 1_920_000)
    #expect(budget.highWater < AudioBudget.limit)
}

@Test func sixtySecondBoundaryKeepsTheCompleteDeclaredSegment() throws {
    let chunk = try fixture(frames: 1024)
    let budget = AudioBudget()
    let accumulator = try AudioAccumulator(source: chunk.format, budget: budget)
    for _ in 0..<938 { accumulator.append(chunk) }
    #expect(accumulator.error == nil)
    let batch = try accumulator.seal()
    #expect(batch.frames == 960_000)
    #expect(batch.durationLimitReached)
    #expect(budget.highWater <= AudioBudget.limit)
}

@Test func silenceEmptyAndCancelledCaptureCannotInventAudio() throws {
    let buffer = try fixture()
    let budget = AudioBudget()
    let accumulator = try AudioAccumulator(source: buffer.format, budget: budget)
    accumulator.cancel()
    accumulator.append(buffer)
    #expect(throws: AudioFailure.self) { try accumulator.seal() }
}

@Test @MainActor func unsupportedAnalyzerLayoutFailsBeforeFrameworkTrap() throws {
    let buffer = try fixture()
    let budget = AudioBudget()
    let owner = try budget.reserve(Int(buffer.frameCapacity) * 2)
    let batch = AudioBatch(input: AnalyzerInput(buffer: buffer), lease: owner, budget: budget)
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000, channels: 1, interleaved: false))
    #expect(throws: AudioFailure.self) { try NativeAudio.compatible(batch, format: format) }
    #expect(budget.allocatedBytes == 3200)
}
