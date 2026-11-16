// Encode Koa's rendered PNG sequences into HEVC-with-alpha .mov clips for the app.
//   swift Design/Koa/encode.swift <frames-dir> <out-dir>
// <frames-dir>/<clip>/f_0001.png ... becomes <out-dir>/<clip>.mov at 24 fps, 512 px, transparent.
// Uses AVFoundation only (no ffmpeg), the same codec the app decodes.
import AppKit
import AVFoundation
import VideoToolbox

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: encode.swift <frames-dir> <out-dir>"); exit(2) }
let framesRoot = URL(fileURLWithPath: args[1]), outRoot = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: outRoot, withIntermediateDirectories: true)
let fps: Int32 = 24, size = 512

func pixelBuffer(_ image: CGImage, pool: CVPixelBufferPool) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return buffer
}

// The app's clips and their fixed lengths (Sources/CursusVox/Koa.swift). Every one must be present
// as a complete f_0001.png... sequence before any output is replaced.
let expected = ["pop_in": 12, "listen_calm": 48, "listen_loud": 48, "think": 48, "happy": 19, "oops": 19, "shrug": 14]
func fail(_ message: String) -> Never { print(message); exit(1) }
for (clip, count) in expected {
    let dir = framesRoot.appendingPathComponent(clip)
    let names = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".png") }
    let wanted = Set((1...count).map { String(format: "f_%04d.png", $0) })
    guard names == wanted else {
        fail("\(clip): expected f_0001.png to f_\(String(format: "%04d", count)).png exactly, found \(names.count) PNGs")
    }
}
for clip in expected.keys.sorted() {
    let dir = framesRoot.appendingPathComponent(clip)
    let frames = (1...expected[clip]!).map { String(format: "f_%04d.png", $0) }
    let out = outRoot.appendingPathComponent(clip + ".mov")
    try? FileManager.default.removeItem(at: out)
    let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha, AVVideoWidthKey: size, AVVideoHeightKey: size,
        AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.72,
                                          kVTCompressionPropertyKey_TargetQualityForAlpha as String: 0.8]])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: size, kCVPixelBufferHeightKey as String: size])
    writer.add(input)
    guard writer.startWriting() else { fail("\(clip): \(writer.error?.localizedDescription ?? "cannot write")") }
    writer.startSession(atSourceTime: .zero)
    for (index, name) in frames.enumerated() {
        guard let image = NSImage(contentsOf: dir.appendingPathComponent(name))?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let pool = adaptor.pixelBufferPool, let buffer = pixelBuffer(image, pool: pool) else {
            fail("\(clip): bad frame \(name)")
        }
        // Wait for the writer, but stop at once if it has failed (disk full, encoder error).
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { fail("\(clip): \(writer.error?.localizedDescription ?? "writer stopped")") }
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps)) else {
            fail("\(clip): frame \(name) not written: \(writer.error?.localizedDescription ?? "unknown")")
        }
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else { fail("\(clip): \(writer.error?.localizedDescription ?? "failed")") }
    let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
    print("\(clip).mov \(frames.count) frames \(bytes / 1024) KB")
}
