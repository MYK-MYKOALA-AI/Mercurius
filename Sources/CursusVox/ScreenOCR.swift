import AppKit
import ScreenCaptureKit
import Vision

// Reads a window as an image when Accessibility has no words for it (a photo, a scanned PDF,
// a canvas). On this Mac only: one window, captured on the keypress, never stored.
// shortcut: plain lines of text, no headings or tables; upgrade to Vision's document
// recognition when captures of structured pages matter.
enum ScreenOCR {
    enum Problem: Error, Equatable {
        case permission, windowNotFound, captureFailed, noText
        var message: String {
            switch self {
            case .permission: return "This window has no readable text, so Mercurius needs to look at it. Allow Mercurius in System Settings › Privacy & Security › Screen Recording, reopen Mercurius, then try again."
            case .windowNotFound: return "The window to read could not be pinned down. Click it, then try again."
            case .captureFailed: return "The window could not be read as an image. Try again."
            case .noText: return "No text was found in this window."
            }
        }
    }
    struct Candidate: Equatable { let id: UInt32; let pid: pid_t; let title: String; let frame: CGRect }

    // The one window of this app at this frame; the title settles a tie. Anything else is refused,
    // so another window of the same app is never read by mistake.
    nonisolated static func match(_ candidates: [Candidate], pid: pid_t, title: String, frame: CGRect) -> UInt32? {
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 2 }
        let placed = candidates.filter {
            $0.pid == pid && near($0.frame.minX, frame.minX) && near($0.frame.minY, frame.minY)
                && near($0.frame.width, frame.width) && near($0.frame.height, frame.height)
        }
        let pool = placed.count > 1 ? placed.filter { $0.title == title } : placed
        return pool.count == 1 ? pool[0].id : nil
    }
    nonisolated static func markdown(lines: [String]) -> String {
        lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    // Thin Accessibility text is replaced only by clearly more: twice the words and 20 extra.
    nonisolated static func prefers(ocrWords: Int, over accessibleWords: Int) -> Bool {
        ocrWords >= accessibleWords * 2 && ocrWords >= accessibleWords + 20
    }
    nonisolated static func recognise(_ image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
    private static func frame(of window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
    @MainActor static func text(window: AXUIElement, pid: pid_t, title: String) async -> Result<String, Problem> {
        guard CGPreflightScreenCaptureAccess() else { CGRequestScreenCaptureAccess(); return .failure(.permission) }
        guard let frame = frame(of: window),
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return .failure(.windowNotFound) }
        // The window list reports bounds in the same top-left coordinates as Accessibility.
        let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let candidates = listed.compactMap { entry -> Candidate? in
            guard entry[kCGWindowLayer as String] as? Int == 0, let id = entry[kCGWindowNumber as String] as? UInt32,
                  let owner = entry[kCGWindowOwnerPID as String] as? Int,
                  let bounds = (entry[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) else { return nil }
            return Candidate(id: id, pid: pid_t(owner), title: entry[kCGWindowName as String] as? String ?? "", frame: bounds)
        }
        guard let id = match(candidates, pid: pid, title: title, frame: frame),
              let target = content.windows.first(where: { $0.windowID == id }) else { return .failure(.windowNotFound) }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(frame.width * 2); configuration.height = Int(frame.height * 2); configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target),
                                                                      configuration: configuration) else { return .failure(.captureFailed) }
        let lines = await Task.detached { recognise(image) }.value
        let text = markdown(lines: lines)
        return text.isEmpty ? .failure(.noText) : .success(text)
    }
}
