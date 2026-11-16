import AppKit
import Carbon

@MainActor enum NativePasteShortcut {
    nonisolated static func code(for translations: [CGKeyCode: String]) -> CGKeyCode? {
        let matches = translations.filter { $0.value == "v" || $0.value == "V" }.map(\.key)
        return matches.count == 1 ? matches[0] : nil
    }
    static func currentKey() -> CGKeyCode? {
        // TIS is not thread safe for a UI app; retain its data owner throughout
        // translation. No keyboard event or user-entered text is observed here.
        guard let copied = TISCopyCurrentKeyboardLayoutInputSource() else { return nil }
        let owner = copied.takeRetainedValue()
        guard let raw = TISGetInputSourceProperty(owner, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard CFDataGetLength(data) >= MemoryLayout<UCKeyboardLayout>.size,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var translations: [CGKeyCode: String] = [:]
        for key in CGKeyCode(0)...127 {
            var dead: UInt32 = 0
            var count = 0
            var output = [UniChar](repeating: 0, count: 8)
            let status = output.withUnsafeMutableBufferPointer { buffer in
                UCKeyTranslate(layout, key, UInt16(kUCKeyActionDown), UInt32(cmdKey >> 8),
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead,
                    buffer.count, &count, buffer.baseAddress!)
            }
            if status == noErr, count <= output.count {
                translations[key] = String(utf16CodeUnits: output, count: Int(count))
            }
        }
        withExtendedLifetime(owner) {}
        return code(for: translations)
    }
}
