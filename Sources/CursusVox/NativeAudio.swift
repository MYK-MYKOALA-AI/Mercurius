import AVFoundation
import Foundation
import Speech

// This lock protects the byte ledger across the audio callback and main actor.
// Leases account PCM capacity before allocation, including conversion scratch.
final class AudioBudget: @unchecked Sendable {
    static let limit = 8 * 1024 * 1024
    private let lock = NSLock()
    private var used = 0
    private var peak = 0
    var highWater: Int { lock.withLock { peak } }
    var allocatedBytes: Int { lock.withLock { used } }
    func reserve(_ bytes: Int) throws -> AudioLease {
        try lock.withLock {
            guard bytes > 0, bytes <= Self.limit - used else { throw AudioFailure.limit }
            used += bytes
            peak = max(peak, used)
            return AudioLease(budget: self, bytes: bytes)
        }
    }
    fileprivate func release(_ bytes: Int) { lock.withLock { used -= bytes } }
}

final class AudioLease: Sendable {
    private let budget: AudioBudget
    let bytes: Int
    fileprivate init(budget: AudioBudget, bytes: Int) {
        self.budget = budget
        self.bytes = bytes
    }
    deinit { budget.release(bytes) }
}

enum AudioFailure: Error {
    case limit, format, conversion, overflow, device, empty
}

struct AudioBatch: Sendable {
    let input: AnalyzerInput
    let lease: AudioLease
    let budget: AudioBudget
    var durationLimitReached = false
    var frames: Int { Int(input.buffer.frameLength) }
}

// Only this object crosses into the tap. All access to its converter, PCM buffer,
// counters and lifecycle is serialized by the lock. Borrowed tap buffers never
// escape append(). The sealed buffer is immutable until its batch is released.
final class AudioAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let budget: AudioBudget
    private let lease: AudioLease
    private let pcm: AVAudioPCMBuffer
    private let converter: AVAudioConverter
    private let sourceFormat: AVAudioFormat
    private let format: AVAudioFormat
    private var accepting = true
    private var failure: AudioFailure?
    private var durationLimited = false
    private var length: AVAudioFrameCount = 0
    private var latestLevel: Float = 0
    // Gets each converted 16 kHz chunk too, for the live preview.
    // Each copy carries a lease on the recording's budget, held until the preview lets go.
    private var tap: (@Sendable (AVAudioPCMBuffer, AudioLease) -> Void)?
    func setTap(_ value: (@Sendable (AVAudioPCMBuffer, AudioLease) -> Void)?) { lock.withLock { tap = value } }

    init(source: AVAudioFormat, budget: AudioBudget) throws {
        guard source.sampleRate > 0, source.channelCount > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                  sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: format) else {
            throw AudioFailure.format
        }
        let lease = try budget.reserve(960_000 * 2)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960_000) else {
            throw AudioFailure.limit
        }
        self.budget = budget
        self.lease = lease
        self.pcm = pcm
        self.converter = converter
        self.sourceFormat = source
        self.format = format
    }
    var error: AudioFailure? { lock.withLock { failure } }
    var durationLimitReached: Bool { lock.withLock { durationLimited } }
    // Peak-normalised loudness of the latest buffer, 0...1, for the level meter.
    var level: Float { lock.withLock { latestLevel } }
    func append(_ borrowed: AVAudioPCMBuffer) {
        let level = Self.rms(borrowed)
        lock.withLock {
            latestLevel = level
            guard accepting, failure == nil else { return }
            do {
                guard borrowed.format == sourceFormat else { throw AudioFailure.device }
                try convert(borrowed, ending: false)
            } catch {
                failure = error as? AudioFailure ?? .conversion
                accepting = false
            }
        }
    }
    private func convert(_ source: AVAudioPCMBuffer?, ending: Bool) throws {
        let inputFrames = Double(source?.frameLength ?? 0)
        let capacity = ceil(inputFrames * 16_000 / sourceFormat.sampleRate) + 4096
        guard capacity.isFinite, capacity > 0,
              capacity <= Double(AudioBudget.limit / 2) else { throw AudioFailure.limit }
        let frames = AVAudioFrameCount(capacity)
        let scratchLease = try budget.reserve(Int(frames) * 2)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw AudioFailure.limit
        }
        let feed = ConverterFeed(source, ending: ending)
        // A bounded drain rejects unexpected converter behaviour instead of silently
        // discarding output. The same scratch allocation is reused throughout.
        for _ in 0..<8 {
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                feed.next(inputStatus)
            }
            guard status != .error, conversionError == nil else { throw AudioFailure.conversion }
            try retainOutput(output)
            if durationLimited {
                withExtendedLifetime(scratchLease) {}
                return
            }
            if status == .inputRanDry || status == .endOfStream {
                withExtendedLifetime(scratchLease) {}
                return
            }
            if status == .haveData && output.frameLength == 0 { throw AudioFailure.conversion }
        }
        throw AudioFailure.conversion
    }
    private func retainOutput(_ output: AVAudioPCMBuffer) throws {
        let remaining = pcm.frameCapacity - length
        let retained = min(output.frameLength, remaining)
        guard let source = output.int16ChannelData?[0], let target = pcm.int16ChannelData?[0] else {
            throw AudioFailure.format
        }
        memcpy(target.advanced(by: Int(length)), source, Int(retained) * 2)
        length += retained
        // The preview gets its own exact-size copy: the converter's buffer may be reused.
        if retained > 0, let tap, let lease = try? budget.reserve(Int(retained) * 2),
           let copy = AVAudioPCMBuffer(pcmFormat: output.format, frameCapacity: retained),
           let to = copy.int16ChannelData?[0] {
            memcpy(to, source, Int(retained) * 2); copy.frameLength = retained
            tap(copy, lease)
        }
        if output.frameLength >= remaining {
            durationLimited = true
            accepting = false
        }
    }
    func seal() throws -> AudioBatch {
        try lock.withLock {
            accepting = false
            if let failure { throw failure }
            if !durationLimited { try convert(nil, ending: true) }
            guard length > 0 else { throw AudioFailure.empty }
            pcm.frameLength = length
            return AudioBatch(input: AnalyzerInput(buffer: pcm), lease: lease, budget: budget,
                              durationLimitReached: durationLimited)
        }
    }
    func cancel() { lock.withLock { accepting = false; latestLevel = 0; tap = nil } }
    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        // Speech RMS sits around 0.01-0.2; a square root curve spreads it across the meter.
        return min(1, (sum / Float(buffer.frameLength)).squareRoot() * 6).squareRoot()
    }
}

// AVAudioConverter can invoke a Sendable input callback. This narrowly scoped
// owner serializes its one-shot cursor. The buffer is immutable for conversion;
// callers retain its PCM lease until the synchronous conversion has returned.
private final class ConverterFeed: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer?
    private let ending: Bool
    private var sent = false
    init(_ buffer: AVAudioPCMBuffer?, ending: Bool) {
        self.buffer = buffer
        self.ending = ending
    }
    var supplied: Bool { lock.withLock { sent } }
    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.withLock {
            if !sent, let buffer {
                sent = true
                status.pointee = .haveData
                return buffer
            }
            status.pointee = ending ? .endOfStream : .noDataNow
            return nil
        }
    }
}

// AVFoundation invokes this on its audio worker, never the main actor. The
// Sendable function type prevents inference of the caller's actor isolation.
enum AudioTap {
    nonisolated static func callback(for accumulator: AudioAccumulator)
        -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in accumulator.append(buffer) }
    }
}

@MainActor final class NativeAudio {
    private var engine: AVAudioEngine?
    private var accumulator: AudioAccumulator?
    private var configurationObserver: NSObjectProtocol?
    private var deviceChanged = false
    private var tapInstalled = false
    let budget = AudioBudget()
    var failure: AudioFailure? { deviceChanged ? .device : accumulator?.error }
    var durationLimitReached: Bool { accumulator?.durationLimitReached == true }
    var level: Float { tapInstalled ? accumulator?.level ?? 0 : 0 }

    func prepare() throws {
        close()
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioFailure.device }
        let accumulator = try AudioAccumulator(source: format, budget: budget)
        self.engine = engine
        self.accumulator = accumulator
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.deviceChanged = true }
        }
    }
    func start() throws {
        guard let engine, let accumulator, !tapInstalled, !deviceChanged else {
            throw AudioFailure.device
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024,
                                    format: engine.inputNode.outputFormat(forBus: 0),
                                    block: AudioTap.callback(for: accumulator))
        tapInstalled = true
        engine.prepare()
        do { try engine.start() }
        catch { close(); throw AudioFailure.device }
    }
    func setPreviewTap(_ tap: (@Sendable (AVAudioPCMBuffer, AudioLease) -> Void)?) { accumulator?.setTap(tap) }
    func finish() throws -> AudioBatch {
        guard let accumulator else { throw AudioFailure.device }
        accumulator.setTap(nil)
        stopEngine()
        if deviceChanged { close(); throw AudioFailure.device }
        do {
            let batch = try accumulator.seal()
            self.accumulator = nil
            return batch
        } catch { close(); throw error }
    }
    private func stopEngine() {
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine = nil
    }
    func close() {
        accumulator?.cancel()
        stopEngine()
        accumulator = nil
        deviceChanged = false
    }

    // One complete bounded batch is converted to the provider-discovered format.
    // Source and destination capacity remain charged through analyzer completion.
    static func compatible(_ batch: AudioBatch, format: AVAudioFormat) throws -> AudioBatch {
        let source = batch.input.buffer
        // The verified SpeechTranscriber formats on this SDK are mono Int16.
        // AnalyzerInput traps for the reproduced planar Float32 input; reject
        // unsupported layouts before entering that nonthrowing initializer.
        guard format.commonFormat == .pcmFormatInt16, format.channelCount == 1 else {
            throw AudioFailure.format
        }
        if source.format == format { return batch }
        guard format.sampleRate > 0, format.channelCount > 0,
              let converter = AVAudioConverter(from: source.format, to: format) else {
            throw AudioFailure.format
        }
        let capacity = ceil(Double(source.frameLength) * format.sampleRate / source.format.sampleRate) + 4096
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
            * (format.isInterleaved ? 1 : Int(format.channelCount))
        guard bytesPerFrame > 0, capacity.isFinite, capacity > 0,
              capacity <= Double(AudioBudget.limit / bytesPerFrame) else { throw AudioFailure.limit }
        let frames = AVAudioFrameCount(capacity)
        let lease = try batch.budget.reserve(Int(frames) * bytesPerFrame)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw AudioFailure.limit
        }
        let feed = ConverterFeed(source, ending: true)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            feed.next(inputStatus)
        }
        guard status != .error, conversionError == nil, feed.supplied, output.frameLength > 0 else {
            throw AudioFailure.conversion
        }
        // Explicitly prove the converter has no remaining samples. Unsupported
        // conversions fail rather than delivering an incomplete batch.
        let tailLease = try batch.budget.reserve(4096 * bytesPerFrame)
        guard let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw AudioFailure.limit
        }
        let tailStatus = converter.convert(to: tail, error: &conversionError) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        guard tailStatus == .endOfStream, conversionError == nil, tail.frameLength == 0 else {
            throw AudioFailure.conversion
        }
        withExtendedLifetime(tailLease) {}
        return AudioBatch(input: AnalyzerInput(buffer: output), lease: lease, budget: batch.budget)
    }

    static func wav(_ batch: AudioBatch) throws -> (Data, AudioLease) {
        let buffer = batch.input.buffer
        guard buffer.format.commonFormat == .pcmFormatInt16,
              buffer.format.sampleRate == 16_000, buffer.format.channelCount == 1,
              let samples = buffer.int16ChannelData?[0] else { throw AudioFailure.format }
        let byteCount = Int(buffer.frameLength) * 2
        let lease = try batch.budget.reserve(byteCount + 44)
        var data = Data(capacity: byteCount + 44)
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); word(UInt32(byteCount + 36))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); word(UInt32(16))
        word(UInt16(1)); word(UInt16(1)); word(UInt32(16_000)); word(UInt32(32_000))
        word(UInt16(2)); word(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); word(UInt32(byteCount))
        data.append(UnsafeRawPointer(samples).assumingMemoryBound(to: UInt8.self), count: byteCount)
        return (data, lease)
    }
}
