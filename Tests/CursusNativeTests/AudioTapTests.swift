import AVFoundation
import Foundation
import Testing
@testable import CursusVox

@MainActor struct AudioTapTests {
    @Test func audioWorkerCallbackDoesNotRequireMainActor() async throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16,
            sampleRate: 16_000, channels: 1, interleaved: true))
        let accumulator = try AudioAccumulator(source: format, budget: AudioBudget())
        let tap = AudioTap.callback(for: accumulator)
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // All borrowed AV objects are created and used on this worker.
                let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                    sampleRate: 16_000, channels: 1, interleaved: true)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
                buffer.frameLength = 1024
                memset(buffer.int16ChannelData![0], 0, 2048)
                tap(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000))
                continuation.resume()
            }
        }
        let result = try accumulator.seal()
        #expect(result.frames == 1024)
        #expect(accumulator.error == nil)
    }
}
