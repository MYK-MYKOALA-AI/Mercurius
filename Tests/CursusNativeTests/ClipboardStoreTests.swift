import AppKit
import Foundation
import Testing
@testable import CursusVox

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}
private func mode(_ path: String) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
}
private let draft = ClipDraft(title: "Ship it", properties: [.init(name: "source", kind: .text, value: "https://a.example/x")],
                              body: "We ship on Friday.")

@MainActor @Test func storeKeepsClipsAndCapturesPrivatelyOnDisk() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClipboardStore(root: root)
    let clip = store.add(clip: draft, source: "Safari")
    let capture = store.add(capture: "All the words", title: "Notes", source: "Notes", url: nil)
    let spoken = store.add(dictation: "secret dictation words", at: Date())
    #expect(store.items.map(\.id) == [spoken, capture, clip])
    #expect(store.item(clip)?.source == "a.example")
    #expect(await store.text(clip) == draft.markdown)
    #expect(await store.text(capture) == "All the words")
    #expect(await store.text(spoken) == "secret dictation words")

    // 0700 folder, 0600 files, and dictation text never written anywhere.
    await store.settled()
    #expect(mode(root.path) == 0o700)
    let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(files.count == 3)   // index plus one per clip and capture
    for name in files {
        #expect(mode(root.appendingPathComponent(name).path) == 0o600, "\(name)")
        let data = try Data(contentsOf: root.appendingPathComponent(name))
        #expect(!String(decoding: data, as: UTF8.self).contains("secret dictation"), "\(name)")
    }
    // A new launch finds clips and captures, never dictations.
    let reopened = ClipboardStore(root: root)
    await reopened.ready()
    #expect(reopened.items.map(\.id) == [capture, clip])
    #expect(await reopened.draft(clip) == draft)
    #expect(await reopened.text(capture) == "All the words")
}

// Items made before the index has been read join the kept ones; the index is never cut short.
@MainActor @Test func itemsMadeWhileLoadingAreMergedNotLost() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = ClipboardStore(root: root)
    let old = first.add(capture: "old words", title: "Old", source: nil, url: nil, now: Date(timeIntervalSinceNow: -60))
    await first.settled()
    let second = ClipboardStore(root: root)
    let new = second.add(capture: "new words", title: "New", source: nil, url: nil)   // before its load finished
    await second.settled()
    #expect(second.items.map(\.id) == [new, old])
    #expect(await second.text(new) == "new words")
    #expect(await second.text(old) == "old words")
    let third = ClipboardStore(root: root)
    await third.ready()
    #expect(third.items.map(\.id) == [new, old])
}

@MainActor @Test func unsavedItemsExpireUnlessPinnedOrSaved() async throws {
    let root = tempRoot(), vault = tempRoot()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: vault) }
    let start = Date()
    let store = ClipboardStore(root: root, vault: vault, now: start)
    await store.ready()
    let loose = store.add(clip: draft, source: nil, now: start)
    let pinned = store.add(capture: "pinned words", title: "Pinned", source: nil, url: nil, now: start)
    let saved = store.add(clip: draft, source: nil, now: start)
    let savedCapture = store.add(capture: "saved words", title: "Kept", source: nil, url: nil, now: start)
    store.setPinned(pinned, true)
    let file = try ClipsVault.save(draft.markdown, title: draft.title, folder: "Clips", in: vault)
    store.markSaved(saved, file: file, draft: draft)
    store.markSaved(savedCapture, file: file, draft: draft)
    // A saved clip's text now lives in its note; a saved capture keeps its words.
    await store.settled()
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(saved.uuidString + ".json").path))
    #expect(await store.draft(saved) == draft)
    #expect(await store.text(savedCapture) == "saved words")
    #expect(await !store.editedSinceSave(saved))
    var edited = draft; edited.title = "Edited later"
    store.update(saved, draft: edited)
    #expect(await store.editedSinceSave(saved))
    #expect(await store.draft(saved) == edited)

    store.purge(now: start.addingTimeInterval(ClipboardStore.lifetime - 60))
    #expect(store.count == 4)
    store.purge(now: start.addingTimeInterval(ClipboardStore.lifetime + 1))
    #expect(Set(store.items.map(\.id)) == [pinned, saved, savedCapture])
    #expect(store.item(loose) == nil)
    await store.settled()
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(loose.uuidString + ".json").path))
    // Unpinned, the capture goes on the next purge.
    store.setPinned(pinned, false)
    store.purge(now: start.addingTimeInterval(ClipboardStore.lifetime + 2))
    #expect(store.item(pinned) == nil)
    // A note deleted outside CursusVox: an entry with nothing left to open goes, an edited one stays.
    try FileManager.default.removeItem(at: file)
    await store.dropMissingNotes()
    #expect(store.item(saved) != nil)
    store.delete(saved)
    #expect(store.item(saved) == nil && store.count == 1)
}

// Review round 1 (P1): a save that finishes after newer edits reached the clipboard drops only
// the draft it wrote; the newer one stays, and reopening the clip shows it.
@MainActor @Test func savingKeepsEditsMadeWhileTheNoteWasWritten() async throws {
    let root = tempRoot(), vault = tempRoot()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: vault) }
    let store = ClipboardStore(root: root, vault: vault)
    let id = store.add(clip: draft, source: nil)
    let file = try ClipsVault.save(draft.markdown, title: draft.title, folder: "Clips", in: vault)
    var newer = draft; newer.body = "We ship on Thursday now."
    store.update(id, draft: newer)                       // typed while the note was being written
    store.markSaved(id, file: file, draft: draft)        // the save of the older draft finishes
    await store.settled()
    #expect(await store.draft(id) == newer)
    #expect(await store.editedSinceSave(id))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString + ".json").path))
    // Saving the newer draft then drops it, and the note is what reopens.
    let newerFile = try ClipsVault.save(newer.markdown, title: newer.title, folder: "Clips", in: vault)
    store.markSaved(id, file: newerFile, draft: newer)
    await store.settled()
    #expect(await !store.editedSinceSave(id))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString + ".json").path))
}

// Review round 1 (P2): Save to Clips from a row runs once per item, however often it is pressed.
@MainActor @Test func rowSavesRunOncePerItem() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClipboardStore(root: root)
    let id = store.add(capture: "words to keep", title: "Window", source: "Notes", url: nil)
    var writes: [ClipDraft] = []
    var second: ClipboardStore.RowSave?
    let note = URL(fileURLWithPath: "/tmp/v/Clips/Window.md")
    let first = await store.saveToClips(id) { draft, _ in
        writes.append(draft)
        // A second press while the first is still writing.
        second = await store.saveToClips(id) { draft, _ in writes.append(draft); return .success(note) }
        #expect(await store.exclusive(id) { 1 } == nil)
        return .success(note)
    }
    #expect(first == .saved(note) && second == .busy)
    #expect(writes.count == 1 && writes.first?.body == "words to keep")
    #expect(store.item(id)?.saved == note && store.busy.isEmpty)
    #expect(await store.saveToClips(UUID()) { _, _ in .success(note) } == .nothing)
}

// Dictation text follows Home's 10-minute rule exactly and is never pinned or kept longer.
@MainActor @Test func dictationsKeepTheTenMinuteRule() async {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(ClipboardStore.dictationLifetime == 10 * 60)
    let start = Date()
    let store = ClipboardStore(root: root, now: start)
    let id = store.add(dictation: "hello", at: start)
    #expect(await store.text(id, now: start.addingTimeInterval(599)) == "hello")
    // Past ten minutes the text is gone even before the next purge, and pinning doesn't save it.
    store.setPinned(id, true)
    #expect(await store.text(id, now: start.addingTimeInterval(600)) == nil)
    store.purge(now: start.addingTimeInterval(600))
    #expect(store.item(id) == nil)
    let other = store.add(dictation: "bye", at: start)
    store.dropDictations()
    #expect(store.item(other) == nil && store.count == 0)
}

// Review round 1 (P1): at ten minutes a dictation leaves the Clipboard page as well as the store,
// even while Home is closed: no row, label or button keeps its words.
extension MainRunLoop {
@MainActor @Test func purgedDictationsLeaveTheClipboardPage() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = NSApplication.shared
    let start = Date()
    let store = ClipboardStore(root: root, now: start)
    let home = HomePanel()
    home.clipboardItems = { store.items }
    home.clipboardProblem = { nil }
    store.changed = { home.loadClipboard() }   // as the app wires it
    store.add(dictation: "the secret plan for Friday", at: start)
    home.select(.clipboard)
    let view = try #require(home.popover.contentViewController?.view)
    func words(_ view: NSView) -> [String] {
        var found = [(view as? NSTextField)?.stringValue, view.accessibilityLabel()].compactMap { $0 }
        for sub in view.subviews { found += words(sub) }
        return found
    }
    #expect(!home.isShown)
    #expect(words(view).contains { $0.contains("secret plan") })
    store.purge(now: start.addingTimeInterval(ClipboardStore.dictationLifetime))
    #expect(!words(view).contains { $0.contains("secret plan") })
}
}

@MainActor @Test func storeIsCappedOldestUnpinnedFirst() async {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(ClipboardStore.cap == 500)
    // A small cap keeps the main actor free for the timing tests running alongside; the rule is the same.
    let store = ClipboardStore(root: root, cap: 20)
    let start = Date()
    let oldest = store.add(capture: "first", title: "First", source: nil, url: nil, now: start)
    store.setPinned(oldest, true)
    let second = store.add(capture: "second", title: "Second", source: nil, url: nil, now: start)
    for index in 0..<19 {
        store.add(capture: "n\(index)", title: "n", source: nil, url: nil, now: start.addingTimeInterval(Double(index)))
    }
    #expect(store.count == 20)
    #expect(store.item(oldest) != nil && store.item(second) == nil)
    await store.settled()
    let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    #expect(files.count == 21)   // the index and one file per entry: the dropped one's file is gone too
}

// A link where the clipboard folder should be is refused: nothing is written through it.
@MainActor @Test func storeRefusesALinkedFolder() async throws {
    let manager = FileManager.default
    let parent = tempRoot(), outside = tempRoot()
    defer { try? manager.removeItem(at: parent); try? manager.removeItem(at: outside) }
    try manager.createDirectory(at: parent, withIntermediateDirectories: true)
    try manager.createDirectory(at: outside, withIntermediateDirectories: true)
    let root = parent.appendingPathComponent("Clipboard")
    try manager.createSymbolicLink(at: root, withDestinationURL: outside)
    let store = ClipboardStore(root: root)
    let id = store.add(capture: "words", title: "t", source: nil, url: nil)
    await store.settled()
    #expect(store.problem != nil)
    #expect(await store.text(id) == "words")   // kept in memory until quit
    #expect(try manager.contentsOfDirectory(atPath: outside.path).isEmpty)
}

// Review round 1 (P2): the store's files are read only as plain files within a limit, off the
// main actor: a FIFO in an item's place is refused at once instead of blocking.
@MainActor @Test func storeReadsOnlyBoundedPlainFiles() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClipboardStore(root: root)
    let id = store.add(capture: "words", title: "t", source: nil, url: nil)
    await store.settled()
    let file = root.appendingPathComponent(id.uuidString + ".json")
    try FileManager.default.removeItem(at: file)
    #expect(mkfifo(file.path, 0o600) == 0)
    #expect(await store.text(id) == nil)
    let folder = try SafeFolder.open(root, followLink: false, create: false)
    #expect(folder.read(file.lastPathComponent, limit: 1024) == nil)
    // A plain file over the limit is refused too; within it, read whole.
    let big = root.appendingPathComponent("big")
    try Data(repeating: 65, count: 2048).write(to: big)
    #expect(folder.read("big", limit: 2047) == nil)
    #expect(folder.read("big", limit: 2048)?.count == 2048)
}

@MainActor @Test func capturesBecomeNotesAndOldNotesAreListedOnce() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Same clock for init merge and the capture: an epoch-0 row is purged when load merges with Date().
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let store = ClipboardStore(root: root, now: start)
    await store.ready()
    let id = store.add(capture: "# Heading\nLine", title: "Window", source: "Notes", url: "https://a.example/",
                       now: start)
    let note = try #require(await store.captureDraft(id, now: start))
    #expect(note.title == "Window" && note.body == "# Heading\nLine")
    #expect(note.markdown.contains("source: \"https://a.example/\"")
            && note.markdown.contains("clipped: \(ISO8601DateFormatter().string(from: start))"))
    #expect(note.markdown.contains("tags:\n  - \"captures\""))
    let old = ClipsVault.SavedNote(url: URL(fileURLWithPath: "/tmp/v/Saved/Old.md"), title: "Old",
                                   date: start.addingTimeInterval(10), bytes: 9)
    await store.importSaved([old]); await store.importSaved([old])
    #expect(store.items.filter { $0.saved != nil }.count == 1)
    #expect(store.items.first?.title == "Old")   // listed by date, newest first
}

// Review round 1 (P1): a saved note is only read from inside the vault, never through a link.
@MainActor @Test func savedNotesAreNeverReadThroughALink() async throws {
    let manager = FileManager.default
    let root = tempRoot(), vault = tempRoot(), outside = tempRoot()
    defer { for url in [root, vault, outside] { try? manager.removeItem(at: url) } }
    try manager.createDirectory(at: outside, withIntermediateDirectories: true)
    let secret = outside.appendingPathComponent("secret.txt")
    try "private words".write(to: secret, atomically: true, encoding: .utf8)
    let store = ClipboardStore(root: root, vault: vault)
    let id = store.add(clip: draft, source: nil)
    let file = try ClipsVault.save(draft.markdown, title: draft.title, folder: "Clips", in: vault)
    store.markSaved(id, file: file, draft: draft)
    await store.settled()
    #expect(await store.text(id) == draft.markdown)
    // The note swapped for a link to a private file: Copy and Open get nothing.
    try manager.removeItem(at: file)
    try manager.createSymbolicLink(at: file, withDestinationURL: secret)
    #expect(await store.text(id) == nil)
    #expect(await store.draft(id) == nil)
    // Its folder swapped for a link: the same.
    try manager.removeItem(at: file)
    try manager.moveItem(at: vault.appendingPathComponent("Clips"), to: vault.appendingPathComponent("Moved"))
    try "x".write(to: outside.appendingPathComponent(file.lastPathComponent), atomically: true, encoding: .utf8)
    try manager.createSymbolicLink(at: vault.appendingPathComponent("Clips"), withDestinationURL: outside)
    #expect(await store.text(id) == nil)
    // And a file outside the vault is never read as a note, whatever its entry says.
    #expect(ClipsVault.readNote(secret, in: vault) == nil)
}

// Review round 1 (P2): every kept item can be reached: past a page of rows, "Show more" adds the next.
extension MainRunLoop {
@MainActor @Test func everyKeptItemCanBeReachedOnTheClipboardPage() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = NSApplication.shared
    let store = ClipboardStore(root: root)
    let start = Date()
    let oldest = store.add(capture: "first", title: "The oldest capture", source: nil, url: nil, now: start)
    for index in 1...HomePanel.clipboardPage {
        store.add(capture: "n", title: "Capture \(index)", source: nil, url: nil, now: start.addingTimeInterval(Double(index)))
    }
    #expect(store.item(oldest) != nil && store.count == HomePanel.clipboardPage + 1)
    let home = HomePanel()
    home.clipboardItems = { store.items }
    home.clipboardProblem = { nil }
    home.select(.clipboard); home.loadClipboard()
    let view = try #require(home.popover.contentViewController?.view)
    func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
    func rowShown(_ title: String) -> Bool { all(view).contains { $0.accessibilityLabel() == "Text: " + title } }
    #expect(rowShown("Capture 1") && !rowShown("The oldest capture"))
    let more = try #require(all(view).compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("Show 1 more") })
    more.performClick(nil)
    #expect(rowShown("The oldest capture"))
    #expect(!all(view).contains { ($0 as? NSButton)?.title.hasPrefix("Show ") == true })
}
}

// Runs its work once, from any thread (a disk-queue hook).
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func callAsFunction(_ work: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true; work()
    }
}

// Review round 2 (P1): a missing-note check that finds nothing to keep doesn't delete an entry
// that changed while it ran (the card handing over a newer draft, or a save elsewhere).
@MainActor @Test func missingNoteCleanupKeepsAnEntryChangedMeanwhile() async throws {
    let root = tempRoot(), vault = tempRoot()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: vault) }
    let store = ClipboardStore(root: root, vault: vault)
    let edited = store.add(clip: draft, source: nil), resaved = store.add(clip: draft, source: nil), gone = store.add(clip: draft, source: nil)
    var files: [URL] = []
    for id in [edited, resaved, gone] {
        let file = try ClipsVault.save(draft.markdown, title: draft.title, folder: "Clips", in: vault)
        store.markSaved(id, file: file, draft: draft); files.append(file)
    }
    await store.settled()
    for file in files { try FileManager.default.removeItem(at: file) }
    let elsewhere = try ClipsVault.save(draft.markdown, title: draft.title, folder: "Work", in: vault)
    var newer = draft; newer.body = "Edited on the card"
    await store.dropMissingNotes {
        store.update(edited, draft: newer)                             // the card closes with an edit
        store.markSaved(resaved, file: elsewhere, draft: draft)        // saved again into another folder
    }
    #expect(store.item(edited) != nil && store.item(resaved) != nil)
    #expect(store.item(gone) == nil)                                   // unchanged and missing: goes
    await store.settled()
    #expect(await store.draft(edited) == newer)
    #expect(await store.draft(resaved) == draft)
}

// Review round 2 (P1): the Clipboard folder swapped for a link after it was opened, before a
// file is written into it: the write stays in the folder that was opened, nothing reaches the
// link's target, and the next write is refused with a problem shown.
@MainActor @Test func aClipboardFolderSwappedMidWriteIsNotFollowed() async throws {
    let manager = FileManager.default
    let parent = tempRoot(), outside = tempRoot()
    defer { try? manager.removeItem(at: parent); try? manager.removeItem(at: outside) }
    try manager.createDirectory(at: outside, withIntermediateDirectories: true)
    let root = parent.appendingPathComponent("Clipboard"), moved = parent.appendingPathComponent("Moved")
    let store = ClipboardStore(root: root)
    await store.settled()
    let once = Once()
    await store.beforeDiskWrite {
        once {
            try? FileManager.default.moveItem(at: root, to: moved)
            try? FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        }
    }
    let id = store.add(capture: "private words", title: "t", source: nil, url: nil)
    await store.settled()
    #expect(try manager.contentsOfDirectory(atPath: outside.path).isEmpty)
    #expect(manager.fileExists(atPath: moved.appendingPathComponent(id.uuidString + ".json").path))
    #expect(store.problem != nil)
    #expect(try manager.destinationOfSymbolicLink(atPath: root.path) == outside.path)
    // Review round 3 (P2): the capture can't be read back from where it is read, so it stays
    // recoverable: Copy and Save still get its words.
    #expect(await store.text(id) == "private words")
    #expect(await store.captureDraft(id)?.body == "private words")
}

// Review round 2 (P1): a save is trusted (and the stored draft dropped) only when the path it
// reported is inside the vault and reads back as the draft; otherwise the draft stays.
@MainActor @Test func aSaveIsOnlyTrustedWhenItsNoteReadsBack() async throws {
    let manager = FileManager.default
    let root = tempRoot(), vault = tempRoot(), outside = tempRoot()
    defer { for url in [root, vault, outside] { try? manager.removeItem(at: url) } }
    try manager.createDirectory(at: outside, withIntermediateDirectories: true)
    let store = ClipboardStore(root: root, vault: vault)
    let id = store.add(clip: draft, source: nil)
    let kept = root.appendingPathComponent(id.uuidString + ".json")
    let stray = outside.appendingPathComponent("Ship it.md")
    try draft.markdown.write(to: stray, atomically: true, encoding: .utf8)
    store.markSaved(id, file: stray, draft: draft)                     // outside the vault
    await store.settled()
    #expect(manager.fileExists(atPath: kept.path))
    #expect(await store.draft(id) == draft)
    let wrong = try ClipsVault.save("something else", title: "t", folder: "Clips", in: vault)
    store.markSaved(id, file: wrong, draft: draft)                     // in the vault, other words
    await store.settled()
    #expect(manager.fileExists(atPath: kept.path))
    let right = try ClipsVault.save(draft.markdown, title: draft.title, folder: "Clips", in: vault)
    store.markSaved(id, file: right, draft: draft)
    await store.settled()
    #expect(!manager.fileExists(atPath: kept.path))
    #expect(await store.draft(id) == draft)
}

// Review round 2 (P2): the card's save and a Clipboard row's Save to Clips go through one gate per
// entry, so a slow save from either can't be doubled by the other into two notes.
@MainActor @Test func cardAndRowShareOneSaveGate() async throws {
    let root = tempRoot(), vault = tempRoot()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: vault) }
    let store = ClipboardStore(root: root, vault: vault)
    let id = store.add(clip: draft, source: nil)
    var writes = 0
    func write(_ draft: ClipDraft, _ folder: String) -> Result<URL, ClipsVault.SaveError> {
        writes += 1
        do { return .success(try ClipsVault.save(draft.markdown, title: draft.title, folder: folder, in: vault)) }
        catch { return .failure(error as? ClipsVault.SaveError ?? .failed(EIO)) }
    }
    let model = ClipCardModel()
    model.offer(draft, token: model.begin("")); model.storeID = id
    model.onSaved = { file, saved, entry in store.markSaved(entry ?? id, file: file, draft: saved) }
    var row: ClipboardStore.RowSave?
    let effects = ClipCardModel.Effects(
        save: { draft, folder, entry in
            await store.savingNote(entry) {
                // Save to Clips from the row while the card's save is still writing.
                row = await store.saveToClips(id) { draft, folder in write(draft, folder) }
                return write(draft, folder)
            }
        },
        copy: { _ in nil }, open: { _ in nil }, reveal: { _ in })
    #expect(await model.perform(.save, effects) == .done("Saved to Ship it.md"))   // named from outside the default vault
    #expect(row == .busy && writes == 1)
    await store.settled()
    // Saved and unchanged, the row's Save gives the same note back without writing another.
    #expect(await store.saveToClips(id) { draft, folder in write(draft, folder) } == .saved(try #require(store.item(id)?.saved)))
    #expect(writes == 1)
    // And the other way round: a row save in progress refuses the card's.
    let other = store.add(capture: "words", title: "Window", source: nil, url: nil)
    var card: Result<URL, ClipsVault.SaveError>?
    _ = await store.saveToClips(other) { draft, folder in
        card = await store.savingNote(other) { write(draft, folder) }
        return write(draft, folder)
    }
    #expect(card == .failure(.busy) && writes == 2)
    let names = try FileManager.default.contentsOfDirectory(atPath: vault.appendingPathComponent("Clips").path).sorted()
    #expect(names == ["Ship it.md", "Window.md"])
}

// Review round 2 (P2): a storage problem appears on the Clipboard page even when no row changed.
extension MainRunLoop {
@MainActor @Test func storageProblemsShowWhenNoRowChanges() async throws {
    let manager = FileManager.default
    let parent = tempRoot(), outside = tempRoot()
    defer { try? manager.removeItem(at: parent); try? manager.removeItem(at: outside) }
    try manager.createDirectory(at: parent, withIntermediateDirectories: true)
    try manager.createDirectory(at: outside, withIntermediateDirectories: true)
    let root = parent.appendingPathComponent("Clipboard")
    try manager.createSymbolicLink(at: root, withDestinationURL: outside)
    _ = NSApplication.shared
    let home = HomePanel()
    let store = ClipboardStore(root: root)
    home.clipboardItems = { store.items }
    home.clipboardProblem = { store.problem }
    store.changed = { home.loadClipboard() }   // as the app wires it
    home.select(.clipboard); home.loadClipboard()
    let view = try #require(home.popover.contentViewController?.view)
    func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
    func shown(_ text: String) -> Bool { all(view).contains { ($0 as? NSTextField)?.stringValue == text && !$0.isHidden } }
    await store.settled()
    #expect(store.items.isEmpty)
    let problem = try #require(store.problem)
    #expect(shown(problem))
    // Gone once the folder works again (a row message doesn't hide it meanwhile).
    home.clipboardMessage("Copied", ok: true)
    #expect(shown(problem))
    home.clipboardProblem = { nil }; home.loadClipboard()
    #expect(!shown(problem))
}
}

// Review round 2 (P2): the old Clips page's recent loose clips join the clipboard once, as unsaved
// clips that can be reviewed, pinned and saved, and still go 48 hours after they were made.
@MainActor @Test func looseClipsFromTheOldPageJoinTheClipboard() async throws {
    let manager = FileManager.default
    let root = tempRoot(), vault = tempRoot()
    defer { try? manager.removeItem(at: root); try? manager.removeItem(at: vault) }
    try manager.createDirectory(at: vault, withIntermediateDirectories: true)
    let made = Date().addingTimeInterval(-3600)
    for name in ["Ship it Friday", "Second page"] {
        let file = vault.appendingPathComponent(name + ".md")
        try ("---\ntitle: \"" + name + "\"\nsource: \"https://a.example/\"\n---\nWe ship on Friday.\n").write(to: file, atomically: true, encoding: .utf8)
        try manager.setAttributes([.modificationDate: made], ofItemAtPath: file.path)
    }
    let notes = ClipsVault.looseNotes(in: vault)
    let store = ClipboardStore(root: root, vault: vault)
    await store.importLoose(notes); await store.importLoose(notes)
    #expect(store.count == 2 && store.items.allSatisfy { $0.kind == .clip && $0.saved == nil })
    let item = try #require(store.items.first { $0.title == "Ship it Friday" })
    #expect(abs(item.at.timeIntervalSince(made)) < 1 && item.source == "a.example")
    #expect(await store.draft(item.id)?.body == "We ship on Friday.")
    store.setPinned(item.id, true)
    let saved = await store.saveToClips(item.id) { draft, folder in
        do { return .success(try ClipsVault.save(draft.markdown, title: draft.title, folder: folder, in: vault)) }
        catch { return .failure(error as? ClipsVault.SaveError ?? .failed(EIO)) }
    }
    guard case let .saved(file) = saved else { Issue.record("not saved: \(saved)"); return }
    #expect(ClipsVault.relative(file, in: vault) == "Clips/Ship it Friday.md")
    // The other, unpinned and unsaved, goes 48 hours after it was made, like any unsaved clip.
    store.purge(now: made.addingTimeInterval(ClipboardStore.lifetime + 1))
    #expect(store.count == 1 && store.item(item.id) != nil)
}

// Review round 3 (P1): a kept list that can't be read (damaged, or over its size limit) is set
// aside, never overwritten, and nothing in the folder is cleaned up as unknown, then or later.
@MainActor @Test func anUnreadableListIsKeptAsideAndNothingIsCleanedUp() async throws {
    let manager = FileManager.default
    for damage in [Data("not a list".utf8), Data(repeating: 0x20, count: ClipboardDisk.indexLimit + 1)] {
        let root = tempRoot()
        defer { try? manager.removeItem(at: root) }
        let first = ClipboardStore(root: root)
        let old = first.add(capture: "earlier words", title: "Earlier", source: nil, url: nil)
        await first.settled()
        try damage.write(to: root.appendingPathComponent(ClipboardDisk.index))
        let leftover = root.appendingPathComponent(".interrupted.tmp")
        try Data("x".utf8).write(to: leftover)
        let second = ClipboardStore(root: root)
        let new = second.add(capture: "new words", title: "New", source: nil, url: nil)
        await second.settled()
        #expect(second.items.map(\.id) == [new])
        #expect(try #require(second.problem).contains("couldn't be read"))
        let names = try manager.contentsOfDirectory(atPath: root.path)
        let aside = try #require(names.first { $0.hasPrefix(ClipboardDisk.setAsidePrefix) })
        #expect(try Data(contentsOf: root.appendingPathComponent(aside)) == damage)
        #expect(names.contains(ClipboardDisk.name(old)))
        #expect(names.contains(leftover.lastPathComponent))   // no clean-up at all after a failed load
        // The next launch reads the new list, and still removes no item file the old list may hold.
        let third = ClipboardStore(root: root)
        await third.settled()
        #expect(third.items.map(\.id) == [new] && third.problem == nil)
        #expect(manager.fileExists(atPath: root.appendingPathComponent(ClipboardDisk.name(old)).path))
        #expect(!manager.fileExists(atPath: leftover.path))
        #expect(await third.text(new) == "new words")
    }
}

// Review round 3 (P1): nothing is written bigger than it is read back at. A huge title is cut
// short in the list (which stays small); content too large for its file stays in memory, warned.
@MainActor @Test func nothingIsWrittenLargerThanItCanBeReadBack() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var fits = draft; fits.title = String(repeating: "Long title ", count: 9 * 1024 * 1024 / 11)          // ~9 MiB
    var tooBig = draft; tooBig.title = String(repeating: "Long title ", count: ClipboardDisk.contentLimit / 11 + 1)
    let store = ClipboardStore(root: root)
    let kept = store.add(clip: fits, source: nil), held = store.add(clip: tooBig, source: nil)
    await store.settled()
    #expect(store.items.allSatisfy { $0.title.count <= ClipboardStore.titleLimit && $0.title.utf8.count <= ClipboardStore.titleLimit * 4 })
    let index = try Data(contentsOf: root.appendingPathComponent(ClipboardDisk.index))
    #expect(index.count < 64 * 1024)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(ClipboardDisk.name(kept)).path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(ClipboardDisk.name(held)).path))
    #expect(store.problem != nil)
    #expect(await store.draft(held)?.title == tooBig.title)
    // A new launch reads the list and the content that was written.
    let reopened = ClipboardStore(root: root)
    await reopened.settled()
    #expect(Set(reopened.items.map(\.id)) == [kept, held] && reopened.problem == nil)
    #expect(await reopened.draft(kept)?.title == fits.title)
    // Index fields lose control characters and stay short.
    #expect(ClipboardStore.field("a\nb\u{0}c", 10) == "a b c")
    #expect(ClipboardStore.field(String(repeating: "é", count: 1000), 300).count == 300)
}

// Review round 3 (P2): a content write that failed keeps its warning after a later list write
// succeeds, until that item is on disk or gone.
@MainActor @Test func anUnsavedItemKeepsItsWarningAfterTheListIsWritten() async throws {
    let root = tempRoot()
    defer { chmod(root.path, 0o700); try? FileManager.default.removeItem(at: root) }
    let store = ClipboardStore(root: root)
    await store.settled()
    let once = Once(), path = root.path
    // The capture's write finds the folder read-only (no room for it); the list write after it
    // works, the folder being put back to 0700 when it is opened.
    await store.beforeDiskWrite { once { _ = chmod(path, 0o500) } }
    let id = store.add(capture: "words not on disk", title: "Held", source: nil, url: nil)
    await store.settled()
    #expect(mode(root.path) == 0o700)
    let index = try Data(contentsOf: root.appendingPathComponent(ClipboardDisk.index))
    #expect(String(decoding: index, as: UTF8.self).contains(id.uuidString))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(ClipboardDisk.name(id)).path))
    #expect(store.problem != nil)
    #expect(await store.text(id) == "words not on disk")
    store.add(capture: "other words", title: "Other", source: nil, url: nil)
    await store.settled()
    #expect(store.problem != nil)
    store.delete(id)
    await store.settled()
    #expect(store.problem == nil)
}

// Review round 4 (P2-2/P2-3): the vault's notes are looked for at every launch and nothing records
// an import as done, so a vault not mounted, or a clipboard that couldn't keep them, is simply
// tried again on the next launch; repeating it lists nothing twice.
@MainActor @Test func vaultNotesAreListedAtEveryLaunchWithoutDuplicates() async throws {
    let manager = FileManager.default
    let parent = tempRoot(), volume = tempRoot(), root = tempRoot()
    defer { for url in [parent, volume, root] { try? manager.removeItem(at: url) } }
    try manager.createDirectory(at: parent, withIntermediateDirectories: true)
    try manager.createDirectory(at: volume, withIntermediateDirectories: true)
    let vault = parent.appendingPathComponent("Mercurius Clips")
    try manager.createSymbolicLink(at: vault, withDestinationURL: volume.appendingPathComponent("Unmounted"))
    let first = ClipboardStore(root: root, vault: vault)
    await first.importFromVault()
    #expect(first.count == 0)
    // Mounted, with a saved note and a loose clip: the next launch lists both, and launches after it nothing more.
    try manager.createDirectory(at: volume.appendingPathComponent("Unmounted/Clips"), withIntermediateDirectories: true)
    try "kept".write(to: volume.appendingPathComponent("Unmounted/Clips/Kept.md"), atomically: true, encoding: .utf8)
    try "---\ntitle: \"Loose\"\n---\nwords\n".write(to: volume.appendingPathComponent("Unmounted/Loose.md"), atomically: true, encoding: .utf8)
    for _ in 0..<3 {
        let store = ClipboardStore(root: root, vault: vault)
        await store.importFromVault(); await store.importFromVault()
        await store.settled()
        #expect(store.items.map(\.title).sorted() == ["Kept", "Loose"])
    }
}

// Review round 4 (P2-2): a listed loose clip whose kept copy never reached the disk (its write
// failed, the list's didn't) is written again from its note on the next launch, not skipped.
@MainActor @Test func aLooseClipMissingItsCopyIsRepairedNextLaunch() async throws {
    let manager = FileManager.default
    let root = tempRoot(), vault = tempRoot()
    defer { chmod(root.path, 0o700); try? manager.removeItem(at: root); try? manager.removeItem(at: vault) }
    try manager.createDirectory(at: vault, withIntermediateDirectories: true)
    try "---\ntitle: \"Loose\"\n---\nWe ship on Friday.\n".write(to: vault.appendingPathComponent("Loose.md"), atomically: true, encoding: .utf8)
    let store = ClipboardStore(root: root, vault: vault)
    await store.settled()
    let once = Once(), path = root.path
    await store.beforeDiskWrite { once { _ = chmod(path, 0o500) } }   // the clip's copy fails; the list after it works
    await store.importFromVault()
    await store.settled()
    let id = try #require(store.items.first?.id)
    #expect(!manager.fileExists(atPath: root.appendingPathComponent(ClipboardDisk.name(id)).path))
    // Next launch: the row is read back without its copy, which is written again from the note.
    let next = ClipboardStore(root: root, vault: vault)
    await next.ready()
    #expect(next.items.map(\.id) == [id])
    await next.importFromVault()
    await next.settled()
    #expect(next.items.map(\.id) == [id])
    #expect(manager.fileExists(atPath: root.appendingPathComponent(ClipboardDisk.name(id)).path))
    #expect(await next.draft(id)?.body == "We ship on Friday.")
    // A copy that is there (here, edited since) is never written over by a later launch.
    next.update(id, draft: ClipDraft(title: "Loose", properties: [], body: "Edited."))
    await next.settled()
    let third = ClipboardStore(root: root, vault: vault)
    await third.importFromVault(); await third.settled()
    #expect(await third.draft(id)?.body == "Edited.")
}

// Review round 4 (P2-3): a loose clip or a folder of saved notes that can't be read this launch is
// left out, and listed on a later launch once it can be.
@MainActor @Test func unreadableNotesAreListedOnALaterLaunch() async throws {
    let manager = FileManager.default
    let root = tempRoot(), vault = tempRoot()
    let loose = vault.appendingPathComponent("Loose.md"), folder = vault.appendingPathComponent("Work")
    defer { chmod(loose.path, 0o600); chmod(folder.path, 0o700); try? manager.removeItem(at: root); try? manager.removeItem(at: vault) }
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    try "loose words".write(to: loose, atomically: true, encoding: .utf8)
    try "saved words".write(to: folder.appendingPathComponent("Saved.md"), atomically: true, encoding: .utf8)
    chmod(loose.path, 0o000); chmod(folder.path, 0o000)
    let store = ClipboardStore(root: root, vault: vault)
    await store.importFromVault(); await store.settled()
    #expect(store.count == 0)
    chmod(loose.path, 0o600); chmod(folder.path, 0o700)
    let next = ClipboardStore(root: root, vault: vault)
    await next.importFromVault(); await next.settled()
    #expect(next.items.map(\.title).sorted() == ["Loose", "Saved"])
    let row = try #require(next.items.first { $0.title == "Loose" })
    #expect(await next.draft(row.id)?.body == "loose words")
}

// Listing the vault at every launch never brings back a row deleted from the Clipboard.
@MainActor @Test func aDeletedRowIsNotListedAgain() async throws {
    let manager = FileManager.default
    let root = tempRoot(), vault = tempRoot()
    defer { try? manager.removeItem(at: root); try? manager.removeItem(at: vault) }
    try manager.createDirectory(at: vault.appendingPathComponent("Clips"), withIntermediateDirectories: true)
    try "kept".write(to: vault.appendingPathComponent("Clips/Kept.md"), atomically: true, encoding: .utf8)
    try "loose".write(to: vault.appendingPathComponent("Loose.md"), atomically: true, encoding: .utf8)
    let suite = "cursusvox-test-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ClipboardStore(root: root, vault: vault, defaults: defaults)
    await store.importFromVault()
    #expect(store.count == 2)
    for item in store.items { store.delete(item.id) }
    await store.settled()
    let next = ClipboardStore(root: root, vault: vault, defaults: defaults)
    await next.importFromVault(); await next.settled()
    #expect(next.count == 0)
}

// Review round 4 (P1-1): the list belongs to the folder it was read from. Another folder restored
// at the same path while running is loaded afresh: its list is taken over (or set aside when it
// can't be read), never written over, and its items' files are not cleaned up as unknown.
@MainActor @Test func aFolderReplacedWhileRunningKeepsItsOwnList() async throws {
    let manager = FileManager.default
    let root = tempRoot(), other = tempRoot(), aside = tempRoot()
    defer { for url in [root, other, aside] { try? manager.removeItem(at: url) } }
    let store = ClipboardStore(root: root)
    let mine = store.add(capture: "mine", title: "Mine", source: nil, url: nil)
    await store.settled()
    // Folder B, with its own list, made elsewhere and restored at the same path.
    let backup = ClipboardStore(root: other)
    let theirs = backup.add(capture: "theirs", title: "Theirs", source: nil, url: nil)
    await backup.settled()
    try manager.moveItem(at: root, to: aside)
    try manager.moveItem(at: other, to: root)
    let later = store.add(capture: "later", title: "Later", source: nil, url: nil)
    await store.settled()
    await store.settled()   // the list taken over joins the store's
    let index = try String(decoding: Data(contentsOf: root.appendingPathComponent(ClipboardDisk.index)), as: UTF8.self)
    #expect(index.contains(theirs.uuidString) && index.contains(later.uuidString))
    #expect(store.item(theirs) != nil && store.item(mine) != nil)
    // Restarting there keeps B's item and its words.
    let next = ClipboardStore(root: root)
    await next.settled()
    #expect(await next.text(theirs) == "theirs")
    #expect(await next.text(later) == "later")

    // A replacement whose list can't be read is set aside, never overwritten; its files stay.
    let damaged = tempRoot()
    defer { try? manager.removeItem(at: damaged) }
    let third = ClipboardStore(root: damaged)
    let kept = third.add(capture: "kept", title: "Kept", source: nil, url: nil)
    await third.settled()
    try Data("not json".utf8).write(to: damaged.appendingPathComponent(ClipboardDisk.index))
    try manager.removeItem(at: root)
    try manager.moveItem(at: damaged, to: root)
    next.add(capture: "new", title: "New", source: nil, url: nil)
    await next.settled()
    let names = try manager.contentsOfDirectory(atPath: root.path)
    #expect(names.contains { $0.hasPrefix(ClipboardDisk.setAsidePrefix) })
    let restarted = ClipboardStore(root: root)
    await restarted.settled()
    #expect(manager.fileExists(atPath: root.appendingPathComponent(ClipboardDisk.name(kept)).path))
}

// Review round 4 (P2-4): a note the card saved that was moved or deleted since isn't reported as
// saved: Save writes the draft as a new note. One still there (even reopened from the note
// itself) is reused, never doubled.
@MainActor @Test func saveWritesANewNoteWhenTheSavedOneIsGone() async throws {
    let manager = FileManager.default
    let vault = tempRoot(), root = tempRoot()
    defer { try? manager.removeItem(at: vault); try? manager.removeItem(at: root) }
    var writes = 0
    let effects = ClipCardModel.Effects(
        save: { draft, folder, _ in
            writes += 1
            do { return .success(try ClipsVault.save(draft.markdown, title: draft.title, folder: folder, in: vault)) }
            catch { return .failure(error as? ClipsVault.SaveError ?? .failed(EIO)) }
        },
        copy: { _ in nil }, open: { _ in nil }, reveal: { _ in },
        stillSaved: { file, draft in ClipsVault.holds(file, draft, in: vault) })
    let model = ClipCardModel()
    model.offer(draft, token: model.begin(""))
    #expect(await model.perform(.save, effects) == .done("Saved to Ship it.md"))
    let first = try #require(model.saved?.url)
    #expect(await model.perform(.save, effects) == .done("Saved to Ship it.md") && writes == 1)
    // Deleted outside CursusVox while the card is open: Save writes it again.
    try manager.removeItem(at: first)
    #expect(await model.perform(.save, effects) == .done("Saved to Ship it.md") && writes == 2)
    #expect(ClipsVault.readNote(try #require(model.saved?.url), in: vault) == draft.markdown)
    // Reopened from its note (as the Clipboard does), it is reused: no " 2".
    let text = try #require(ClipsVault.readNote(first, in: vault))
    let reopened = ClipsVault.draft(fromNote: text, title: "Ship it")
    model.load(reopened, savedAt: first, folder: "Clips", storeID: nil)
    #expect(await model.perform(.save, effects) == .done("Saved to Ship it.md") && writes == 2)
    // The Clipboard row's Save to Clips does the same for a capture whose note went.
    let store = ClipboardStore(root: root, vault: vault)
    let id = store.add(capture: "words", title: "Window", source: nil, url: nil)
    let write: @MainActor (ClipDraft, String) async -> Result<URL, ClipsVault.SaveError> = { draft, folder in
        writes += 1
        do { return .success(try ClipsVault.save(draft.markdown, title: draft.title, folder: folder, in: vault)) }
        catch { return .failure(error as? ClipsVault.SaveError ?? .failed(EIO)) }
    }
    guard case let .saved(note) = await store.saveToClips(id, write: write) else { Issue.record("not saved"); return }
    #expect(await store.saveToClips(id, write: write) == .saved(note) && writes == 3)
    try manager.removeItem(at: note)
    guard case let .saved(again) = await store.saveToClips(id, write: write) else { Issue.record("not saved again"); return }
    #expect(writes == 4 && ClipsVault.isNote(again, in: vault))
}

// Review round 3 (P2): Open note (a row) and Open in Obsidian (the card, with its remembered
// path) check the note again just before opening, as Review and Copy read it.
@MainActor @Test func openNoteChecksTheSavedNoteJustBeforeOpening() async throws {
    let manager = FileManager.default
    let vault = tempRoot(), outside = tempRoot()
    defer { try? manager.removeItem(at: vault); try? manager.removeItem(at: outside) }
    try manager.createDirectory(at: outside, withIntermediateDirectories: true)
    let secret = outside.appendingPathComponent("secret.txt")
    try "private words".write(to: secret, atomically: true, encoding: .utf8)
    let file = try ClipsVault.save(draft.markdown, title: draft.title, folder: "Clips", in: vault)
    var opened: [URL] = []
    func open(_ url: URL) async -> String? { await Application.openNote(url, in: vault) { opened.append($0); return nil } }
    #expect(await open(file) == nil && opened == [file])
    // The card saved it and remembers the path.
    let model = ClipCardModel()
    model.load(draft, savedAt: file, folder: "Clips", storeID: nil)
    model.obsidianInstalled = true
    let effects = ClipCardModel.Effects(save: { _, _, _ in .failure(.busy) }, copy: { _ in nil },
                                        open: { await open($0) }, reveal: { _ in })
    // Replaced by a link to a file outside the vault: neither opens it.
    try manager.removeItem(at: file)
    try manager.createSymbolicLink(at: file, withDestinationURL: secret)
    #expect(ClipsVault.readNote(file, in: vault) == nil && !ClipsVault.isNote(file, in: vault))
    #expect(await open(file) != nil)
    guard case .failed = await model.perform(.openInObsidian, effects) else { Issue.record("opened through a link"); return }
    // A folder in its place, or a path outside the vault: refused too.
    try manager.removeItem(at: file)
    try manager.createDirectory(at: file, withIntermediateDirectories: true)
    #expect(await open(file) != nil)
    #expect(await open(secret) != nil)
    #expect(opened == [file])
}

@MainActor @Test func clipboardExpiryIsEnforcedAtReadBeforeTimerPurge() async throws {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = ClipboardStore(root: root)
    let clip = store.add(clip: draft, source: "fixture")
    let capture = store.add(capture: "temporary words", title: "fixture", source: "fixture", url: nil)
    await store.settled()
    let expired = Date().addingTimeInterval(ClipboardStore.lifetime)
    #expect(await store.text(clip, now: expired) == nil)
    #expect(await store.draft(clip, now: expired) == nil)
    #expect(await store.text(capture, now: expired) == nil)
    #expect(await store.captureDraft(capture, now: expired) == nil)
    #expect(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
}

@MainActor @Test func placeholderClipTitlesResolveOnAddAndReload() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClipboardStore(root: root)
    await store.ready()
    let headed = store.add(clip: ClipDraft(title: "Untitled", properties: [], body: "# Design notes\n\nDetails."),
                           source: nil)
    let hosted = store.add(clip: ClipDraft(title: "", properties: [
        .init(name: "source", kind: .text, value: "https://www.docs.example/x")
    ], body: "No heading."), source: nil)
    let named = store.add(clip: ClipDraft(title: "Keep me", properties: [], body: "# Other"), source: nil)
    let capture = store.add(capture: "Captured line one\nTwo", title: "untitled", source: nil,
                            url: "https://www.news.example/a")
    #expect(store.item(headed)?.title == "Design notes")
    #expect(store.item(hosted)?.title == "docs.example")
    #expect(store.item(named)?.title == "Keep me")
    #expect(store.item(capture)?.title == "news.example")
    await store.settled()

    // Write an Untitled index title with a heading body so reload upgrades the row.
    let leftover = UUID()
    let leftoverDraft = ClipDraft(title: "Untitled", properties: [], body: "# After load\n\nBody.")
    let index = root.appendingPathComponent("index.json")
    let items = try JSONDecoder().decode([ClipboardStore.Item].self, from: Data(contentsOf: index))
        + [ClipboardStore.Item(id: leftover, kind: .clip, title: "Untitled", source: nil, url: nil,
                               at: Date(), bytes: leftoverDraft.markdown.utf8.count)]
    try JSONEncoder().encode(items).write(to: index, options: .atomic)
    try JSONEncoder().encode(ClipboardStore.Content(draft: leftoverDraft))
        .write(to: root.appendingPathComponent(leftover.uuidString + ".json"), options: .atomic)

    let reopened = ClipboardStore(root: root)
    await reopened.ready()
    #expect(reopened.item(leftover)?.title == "After load")
    #expect(reopened.item(named)?.title == "Keep me")
}
