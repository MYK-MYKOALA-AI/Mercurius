import Foundation
import CursusCore

protocol TextInsertionPort {
    var selectedRange: CFRange? { get }
    var isFocused: Bool { get }
    func replaceSelectedText(_ text: String) -> Bool
    func string(in range: CFRange) -> String?
}

enum NativeInsertion {
    static func insert(_ text: String, into field: any TextInsertionPort, expectedSelection: SelectionAnchor? = nil,
                       admitMutation: () -> Bool = { true }) -> EffectResult {
        guard !text.isEmpty, text.utf8.count <= Policy.textLimit,
              let range = field.selectedRange, range.location >= 0, range.length >= 0,
              range.location <= Int.max - text.utf16.count else {
            return .failed("Selected range unavailable or text limit exceeded")
        }
        if let expectedSelection,
           expectedSelection.location != range.location || expectedSelection.length != range.length {
            return .failed("Selection changed before insertion")
        }
        guard field.isFocused else { return .failed("Editor lost focus before insertion") }
        guard admitMutation() else { return .failed("Insertion admission expired or canceled") }
        guard field.replaceSelectedText(text) else { return .failed("Editor rejected text insertion") }
        // Read back only the range containing our supplied text. Never read the
        // entire field or repeat a mutation when readback is unavailable.
        let inserted = CFRange(location: range.location, length: text.utf16.count)
        return field.string(in: inserted) == text ? .axConfirmed : .axSent
    }
}
