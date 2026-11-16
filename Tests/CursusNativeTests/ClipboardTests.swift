import AppKit
import Testing
import CursusCore
@testable import CursusVox

@MainActor private final class RacingBoard: ClipboardPort {
    var count = 20
    var raceBeforeWrite = false
    var raceAfterWrite = false
    var writes = 0
    var clears = 0
    var changeCount: Int { count }
    func clearContents() -> Int { clears += 1; count += 1; return count }
    func setString(_ value: String) -> Bool {
        if raceBeforeWrite { count += 1; return false }
        writes += 1
        if raceAfterWrite { count += 1 }
        return true
    }
}

private final class SnapshotBoard: ClipboardReader, RestorableClipboard, ClipboardPort, @unchecked Sendable {
    var count = 7
    var clears = 0
    var failTextWrite = false
    var concurrentCopyOnFailure = false
    nonisolated(unsafe) var items: [[NSPasteboard.PasteboardType: Data]] = []
    nonisolated(unsafe) var unreadable: [NSPasteboard.PasteboardType] = []
    nonisolated(unsafe) var reads = 0
    var changeCount: Int { count }
    func clearContents() -> Int { clears += 1; count += 1; items = []; return count }
    func setString(_ value: String) -> Bool {
        if failTextWrite {
            if concurrentCopyOnFailure {
                count += 1
                items = [[.string: Data("new user copy".utf8)]]
            }
            return false
        }
        items = [[.string: Data(value.utf8)]]; return true
    }
    nonisolated func itemTypes() -> [[NSPasteboard.PasteboardType]] {
        items.enumerated().map { index, item in Array(item.keys) + (index == 0 ? unreadable : []) }
    }
    nonisolated func data(item: Int, type: NSPasteboard.PasteboardType) -> Data? {
        reads += 1; return items[item][type]
    }
    func writeItems(_ value: [[NSPasteboard.PasteboardType: Data]]) -> Bool { items = value; return true }
}

@MainActor struct ClipboardTests {
    @Test func restorePutsBackEveryItemAndTypeWhenTheBoardIsStillOurs() {
        let board = SnapshotBoard()
        let image = Data([0x89, 0x50, 0x4e, 0x47])
        board.items = [[.string: Data("before".utf8), .rtf: Data("{\\rtf1 before}".utf8)], [.png: image]]
        let snapshot = NativeClipboard.snapshot(board)!
        let owned = board.clearContents()
        board.items = [[.string: Data("dictated".utf8)]]
        #expect(NativeClipboard.restore(snapshot, to: board, ifOwned: owned))
        #expect(board.items == [[.string: Data("before".utf8), .rtf: Data("{\\rtf1 before}".utf8)], [.png: image]])
    }
    @Test func restoreNeverOverwritesSomethingTheUserCopiedAfterUs() {
        let board = SnapshotBoard()
        board.items = [[.string: Data("before".utf8)]]
        let snapshot = NativeClipboard.snapshot(board)!
        let owned = board.clearContents()
        _ = board.clearContents(); board.items = [[.string: Data("user copied this".utf8)]]
        #expect(!NativeClipboard.restore(snapshot, to: board, ifOwned: owned))
        #expect(board.items == [[.string: Data("user copied this".utf8)]])
    }
    @Test func oversizedClipboardIsNotSnapshotted() {
        let board = SnapshotBoard()
        board.items = [[.tiff: Data(count: NativeClipboard.snapshotLimit + 1)]]
        #expect(NativeClipboard.snapshot(board) == nil)
    }
    @Test func snapshotStopsReadingOnceTheBudgetIsSpent() {
        let board = SnapshotBoard()
        let half = NativeClipboard.snapshotLimit / 2 + 1
        board.items = [[.tiff: Data(count: half)], [.png: Data(count: half)], [.string: Data("never read".utf8)]]
        #expect(NativeClipboard.snapshot(board) == nil)
        #expect(board.reads == 2)
    }
    @Test func snapshotStopsBeforeReadingWhenAdmissionEnds() {
        let board = SnapshotBoard()
        board.items = [[.string: Data("a".utf8)], [.string: Data("b".utf8)]]
        var allowed = 2
        #expect(NativeClipboard.snapshot(board, shouldContinue: { allowed -= 1; return allowed >= 0 }) == nil)
        #expect(board.reads == 1)
        #expect(NativeClipboard.snapshot(board, shouldContinue: { false }) == nil)
        #expect(board.reads == 1)
    }
    @Test func promisedLazyItemsAreNeverMaterialised() {
        let board = SnapshotBoard()
        board.items = [[NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"): Data()]]
        #expect(NativeClipboard.snapshot(board) == nil)
        #expect(board.reads == 0)
    }
    @Test func unreadableTypeMakesTheSnapshotIncomplete() {
        let board = SnapshotBoard()
        board.items = [[.string: Data("text".utf8)]]
        board.unreadable = [.rtf]
        #expect(NativeClipboard.snapshot(board) == nil)
    }
    @Test func changedClipboardIsNotClearedBeforeAutomaticWrite() {
        let board = RacingBoard()
        let sampled = board.changeCount
        board.count += 1
        guard case .failed = NativeClipboard.write("owned fixture", to: board, expectedCounter: sampled) else {
            Issue.record("A changed clipboard must reject automatic copy"); return
        }
        #expect(board.clears == 0)
        #expect(board.writes == 0)
    }
    @Test func ownershipRaceBeforeWriteFailsWithoutAdoptingForeignCounter() {
        let board = RacingBoard(); board.raceBeforeWrite = true
        guard case .failed = NativeClipboard.write("owned fixture", to: board) else {
            Issue.record("Foreign ownership must fail"); return
        }
        #expect(board.writes == 0)
    }
    @Test func ownershipRaceAfterWriteCannotQualifyPaste() {
        let board = RacingBoard(); board.raceAfterWrite = true
        #expect(NativeClipboard.write("owned fixture", to: board) == .copied(attributableCounter: nil))
        #expect(board.writes == 1)
    }
    @Test func nativeNamedBoardReturnsItsDeclarationCounter() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let result = NativeClipboard.write("CursusVox original synthetic clipboard fixture", to: PasteboardPort(board: board))
        #expect(result == .copied(attributableCounter: board.changeCount))
        #expect(board.string(forType: .string) == "CursusVox original synthetic clipboard fixture")
    }
    @Test func savedSnapshotStillRejectsAConcurrentCopy() {
        let board = SnapshotBoard()
        let snapshot = ClipboardSnapshot(items: [[.string: Data("before".utf8)]])
        board.count = 21
        let result = NativeClipboard.writeRestoring("dictation", to: board, snapshot: snapshot, expectedCounter: 20)
        #expect(result == .failed("Clipboard changed before automatic copy"))
        #expect(board.clears == 0)
        #expect(board.items.isEmpty)
    }
    @Test(arguments: [false, true])
    func failedTextWriteRestoresOnlyItsOwnClearedBoard(_ concurrentCopy: Bool) throws {
        let board = SnapshotBoard()
        let original = [[NSPasteboard.PasteboardType.string: Data("original clipboard".utf8),
                         .rtf: Data("{\\rtf1 original}".utf8)]]
        board.items = original
        let snapshot = try #require(NativeClipboard.snapshot(board))
        let expected = board.changeCount
        board.failTextWrite = true; board.concurrentCopyOnFailure = concurrentCopy
        var claims = 0
        let result = NativeClipboard.writeRestoring("dictation", to: board, snapshot: snapshot,
            expectedCounter: expected, admitMutation: { claims += 1; return true })
        guard case .failed = result else { Issue.record("A failed write qualified delivery"); return }
        #expect(claims == 1)
        if concurrentCopy {
            #expect(board.items == [[.string: Data("new user copy".utf8)]])
            #expect(board.clears == 1)
        } else {
            #expect(board.items == original)
            #expect(board.clears == 2)
        }
    }
    @Test(arguments: ["timeout", "unreadable", "promised", "oversized", "cancelled"])
    func failedPreservationNeverClearsTheOriginalClipboard(_ failure: String) {
        let board = SnapshotBoard()
        board.items = [[.string: Data("original clipboard".utf8)]]
        if failure == "unreadable" { board.unreadable = [.rtf] }
        if failure == "promised" {
            board.items.append([NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"): Data()])
        }
        if failure == "oversized" { board.items.append([.tiff: Data(count: NativeClipboard.snapshotLimit + 1)]) }
        let original = board.items, counter = board.changeCount
        let snapshot = failure == "timeout" ? nil
            : NativeClipboard.snapshot(board, shouldContinue: { failure != "cancelled" })
        #expect(snapshot == nil)
        var claimed = false
        let result = NativeClipboard.writeRestoring("dictation", to: board, snapshot: snapshot,
            expectedCounter: counter, admitMutation: { claimed = true; return true })
        guard case .failed = result else { Issue.record("Unsafe automatic copy succeeded"); return }
        #expect(!claimed)
        #expect(board.clears == 0 && board.changeCount == counter)
        #expect(board.items == original)
        // Explicit Copy remains available when the user chooses to replace it.
        #expect(NativeClipboard.write("dictation", to: board) == .copied(attributableCounter: board.changeCount))
        #expect(board.items == [[.string: Data("dictation".utf8)]])
    }

}

@Test func onlyOneClipboardCaptureMayBeOutstanding() {
    let gate = CaptureGate()
    #expect(gate.tryBegin())
    #expect(!gate.tryBegin())   // a stalled earlier read blocks new captures
    gate.end()
    #expect(gate.tryBegin())
    gate.end()
}
@Test func resumeOnceDeliversExactlyOneValue() async {
    let once = ResumeOnce()
    let value: ClipboardSnapshot? = await withCheckedContinuation { continuation in
        once.set(continuation)
        once.resume(ClipboardSnapshot(items: [[.string: Data("first".utf8)]]))
        once.resume(nil)
    }
    #expect(value?.items.first?[.string] == Data("first".utf8))
    #expect(once.done)
}
