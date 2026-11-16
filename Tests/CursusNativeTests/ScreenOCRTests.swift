import AppKit
import Testing
@testable import CursusVox

@Suite struct ScreenOCRTests {
    let frame = CGRect(x: 10, y: 20, width: 800, height: 600)
    func window(_ id: UInt32, pid: pid_t = 7, title: String = "Doc", frame: CGRect? = nil) -> ScreenOCR.Candidate {
        .init(id: id, pid: pid, title: title, frame: frame ?? self.frame)
    }
    @Test func onlyTheOneMatchingWindowIsRead() {
        #expect(ScreenOCR.match([window(1), window(2, pid: 8)], pid: 7, title: "Doc", frame: frame) == 1)
        #expect(ScreenOCR.match([window(1, title: "Renamed")], pid: 7, title: "Doc", frame: frame) == 1)
        #expect(ScreenOCR.match([window(1), window(2, title: "Private")], pid: 7, title: "Doc", frame: frame) == 1)
        #expect(ScreenOCR.match([window(1), window(2)], pid: 7, title: "Doc", frame: frame) == nil)
        #expect(ScreenOCR.match([window(1, title: "A"), window(2, title: "B")], pid: 7, title: "Doc", frame: frame) == nil)
        #expect(ScreenOCR.match([window(1, frame: frame.offsetBy(dx: 40, dy: 0))], pid: 7, title: "Doc", frame: frame) == nil)
        #expect(ScreenOCR.match([], pid: 7, title: "Doc", frame: frame) == nil)
    }
    @Test func thinTextIsReplacedOnlyByClearlyMore() {
        #expect(ScreenOCR.prefers(ocrWords: 40, over: 5))
        #expect(!ScreenOCR.prefers(ocrWords: 24, over: 15))
        #expect(!ScreenOCR.prefers(ocrWords: 19, over: 0))
        #expect(ScreenOCR.prefers(ocrWords: 20, over: 0))
    }
    @Test func linesBecomeCleanText() {
        #expect(ScreenOCR.markdown(lines: ["  Hello ", "", "world"]) == "Hello\nworld")
    }
    @Test func textInAnImageIsRecognised() throws {
        let size = NSSize(width: 900, height: 200)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4,
                                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        ("Invoice total 4250 dollars" as NSString).draw(at: NSPoint(x: 30, y: 80), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let text = ScreenOCR.markdown(lines: ScreenOCR.recognise(try #require(bitmap.cgImage)))
        #expect(text.contains("Invoice")); #expect(text.contains("4250"))
    }
}
