import AppKit
import Testing
@testable import CursusVox

@Test func pasteUsesLogicalVOnOwnedAlternateLayout() {
    #expect(NativePasteShortcut.code(for: [9: "c", 31: "v", 0: "a"]) == 31)
    #expect(NativePasteShortcut.code(for: [9: "v", 31: "o"]) == 9)
}
@Test func uppercaseVIsAdmittedButAmbiguousOrUnavailableLayoutIsRejected() {
    #expect(NativePasteShortcut.code(for: [24: "V", 9: "c"]) == 24)
    #expect(NativePasteShortcut.code(for: [9: "v", 24: "V"]) == nil)
    #expect(NativePasteShortcut.code(for: [9: "c", 31: "o"]) == nil)
    #expect(NativePasteShortcut.code(for: [:]) == nil)
}
@Test func controlAndMultiCharacterTranslationsNeverQualifyAsPaste() {
    #expect(NativePasteShortcut.code(for: [9: "\u{16}", 31: "vv", 24: "v\n"]) == nil)
}
