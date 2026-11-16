import AppKit
import CursusCore

@MainActor protocol ClipboardPort {
    var changeCount: Int { get }
    func clearContents() -> Int
    func setString(_ value: String) -> Bool
}

// Reads every item and type, so images, rich text and files come back intact.
// Not main-actor: snapshots run on the Accessibility worker, never the UI thread.
protocol ClipboardReader {
    func itemTypes() -> [[NSPasteboard.PasteboardType]]
    func data(item: Int, type: NSPasteboard.PasteboardType) -> Data?
}
@MainActor protocol RestorableClipboard {
    var changeCount: Int { get }
    func clearContents() -> Int
    func writeItems(_ items: [[NSPasteboard.PasteboardType: Data]]) -> Bool
}
// The general pasteboard's items at one moment, read off the main thread.
struct SystemClipboardReader: ClipboardReader {
    private let items = NSPasteboard.general.pasteboardItems ?? []
    func itemTypes() -> [[NSPasteboard.PasteboardType]] { items.map(\.types) }
    func data(item: Int, type: NSPasteboard.PasteboardType) -> Data? { items[item].data(forType: type) }
}

@MainActor struct PasteboardPort: ClipboardPort, RestorableClipboard {
    let board: NSPasteboard
    var changeCount: Int { board.changeCount }
    func clearContents() -> Int { board.clearContents() }
    func setString(_ value: String) -> Bool { board.setString(value, forType: .string) }
    func writeItems(_ items: [[NSPasteboard.PasteboardType: Data]]) -> Bool {
        let objects = items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        return objects.isEmpty || board.writeObjects(objects)
    }
}

struct ClipboardSnapshot: Sendable {
    let items: [[NSPasteboard.PasteboardType: Data]]
}

@MainActor enum NativeClipboard {
    nonisolated static let snapshotLimit = 32 * 1024 * 1024

    static func write(_ text: String, to board: any ClipboardPort, expectedCounter: Int? = nil,
                      admitMutation: () -> Bool = { true }) -> EffectResult {
        submit(text, to: board, expectedCounter: expectedCounter, admitMutation: admitMutation, rollback: nil)
    }
    private static func submit(_ text: String, to board: any ClipboardPort, expectedCounter: Int?,
                               admitMutation: () -> Bool, rollback: ((Int) -> Bool)?) -> EffectResult {
        guard text.utf8.count <= Policy.textLimit else { return .failed("Clipboard text limit exceeded") }
        guard expectedCounter == nil || board.changeCount == expectedCounter else {
            return .failed("Clipboard changed before automatic copy")
        }
        // NSPasteboard has no atomic compare-and-swap. This immediate check
        // closes the stale observation window, not every cross-process race.
        // The declaration's returned counter identifies our ownership. setString
        // fails if ownership changed. A later sample can invalidate, never adopt it.
        guard admitMutation() else { return .failed("Clipboard admission expired or canceled") }
        let owned = board.clearContents()
        guard board.setString(text) else {
            if let restored = rollback?(owned) {
                return .failed(restored ? "Clipboard write failed; prior clipboard restored"
                    : "Clipboard write failed; clipboard ownership changed or restoration failed")
            }
            return .failed("Clipboard write failed; clipboard may already be cleared")
        }
        return .copied(attributableCounter: board.changeCount == owned ? owned : nil)
    }
    // Automatic delivery must preserve the old board before replacing it. A
    // failed capture leaves both the board and the recovery transcript intact.
    static func writeRestoring(_ text: String, to board: any ClipboardPort & RestorableClipboard,
                               snapshot: ClipboardSnapshot?, expectedCounter: Int?,
                               admitMutation: () -> Bool = { true }) -> EffectResult {
        guard let snapshot else {
            return .failed("Clipboard could not be saved. Open Clipboard to copy the transcript explicitly.")
        }
        return submit(text, to: board, expectedCounter: expectedCounter, admitMutation: admitMutation,
            rollback: { owned in restore(snapshot, to: board, ifOwned: owned) })
    }
    // Returns nil when the clipboard cannot be saved completely: an unreadable or
    // promised (lazily provided) type, more than the budget, or admission ending
    // (secure input, cancellation) before or between reads. Reading stops at the
    // first of these. One eager representation is read whole before its size is
    // known; NSPasteboard offers no size query.
    nonisolated static func snapshot(_ reader: any ClipboardReader,
                                     shouldContinue: () -> Bool = { true }) -> ClipboardSnapshot? {
        guard shouldContinue() else { return nil }
        let allTypes = reader.itemTypes()
        guard !allTypes.joined().contains(where: { $0.rawValue.localizedCaseInsensitiveContains("promise") }) else {
            return nil
        }
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        var bytes = 0
        for (index, types) in allTypes.enumerated() {
            var item: [NSPasteboard.PasteboardType: Data] = [:]
            for type in types {
                guard shouldContinue(), let data = reader.data(item: index, type: type) else { return nil }
                bytes += data.count
                guard bytes <= snapshotLimit else { return nil }
                item[type] = data
            }
            items.append(item)
        }
        return ClipboardSnapshot(items: items)
    }
    // Restores only while the board still holds our transcript or failed write, so anything the
    // user copied after dictation is never overwritten.
    static func restore(_ snapshot: ClipboardSnapshot, to board: any RestorableClipboard, ifOwned counter: Int) -> Bool {
        guard board.changeCount == counter else { return false }
        _ = board.clearContents()
        return board.writeItems(snapshot.items)
    }
}
