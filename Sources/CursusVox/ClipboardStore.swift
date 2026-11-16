import Foundation
import os
import CursusCore

// The main clipboard: what CursusVox made, newest first. Page clips (saved or not) and fn+T
// captures are kept on disk, private to this user (folder 0700, files 0600); an unsaved one
// goes 48 hours after it was made unless pinned. A saved clip's text lives in its note, so
// only its entry is kept here. Dictations are never written to disk and go after 10 minutes,
// the same rule as Home's history. Nothing here is ever logged.
// The list lives on the main actor; every read and write of a file happens in order on one
// background queue (`ClipboardDisk`), so a slow disk never holds up the UI or the timers.
@MainActor final class ClipboardStore {
    enum Kind: String, Codable, Sendable { case clip, capture, dictation }
    struct Item: Codable, Equatable, Sendable, Identifiable {
        let id: UUID
        let kind: Kind
        var title: String
        var source: String?     // the app or site it came from
        var url: String?
        let at: Date
        var bytes: Int
        var pinned = false
        var saved: URL?         // the clip's note in the vault, once saved
        var origin: String?     // a loose clip listed from the vault: its file name there
    }
    struct Content: Codable, Equatable, Sendable { var draft: ClipDraft?; var text: String? }

    static let lifetime: TimeInterval = 48 * 3600
    static let dictationLifetime = RepeatedTerms.textLifetime
    static let cap = 500
    static let textLimit = 2 * 1024 * 1024
    // The index's fields are kept short (and free of control characters), so 500 entries stay
    // far below the size the index is read back at (ClipboardDisk.indexLimit).
    static let titleLimit = 300, lineLimit = 500, sourceLimit = 300, urlLimit = 2048
    static func field(_ text: String, _ limit: Int) -> String {
        let short = ClipDraft.prefix(text, bytes: limit * 4)   // bounded work on a huge paste
        let plain = String(String.UnicodeScalarView(short.unicodeScalars.map {
            $0.properties.generalCategory == .control ? " " : $0
        }))
        return ClipDraft.prefix(String(plain.prefix(limit)), bytes: limit * 4)
    }
    private static func field(_ text: String?, _ limit: Int) -> String? { text.map { field($0, limit) } }
    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Mercurius/Clipboard", isDirectory: true)

    let root: URL
    let vault: URL   // where saved notes are read from (never outside it)
    let cap: Int
    private(set) var items: [Item] = []
    private var spoken: [UUID: String] = [:]   // dictation text, memory only
    // Why clips and captures aren't being kept on disk (shown on the Clipboard page); nil when fine.
    private(set) var problem: String?
    var changed: (() -> Void)?
    // Items with an action still running (a save writing its note, a copy reading its file).
    private(set) var busy: Set<UUID> = []
    private let disk: ClipboardDisk
    // Bumped by every change to an item's content or saved note, so work that looked at an item
    // earlier can tell whether it is still the same before acting on what it found.
    private var revisions: [UUID: Int] = [:]
    private var loaded = false
    private var loading: Task<Void, Never>?
    // Notes whose rows were deleted from the Clipboard, so listing the vault's notes doesn't bring
    // them back: a loose clip's file name, or a saved note's path. Kept in `defaults` when given.
    private var dismissed: [String]
    private let defaults: UserDefaults?
    static let dismissedKey = "clipboardDismissedNotes", dismissedLimit = 2000

    init(root: URL = ClipboardStore.defaultRoot, vault: URL = ClipsVault.folder, now: Date = Date(), cap: Int = ClipboardStore.cap,
         defaults: UserDefaults? = nil) {
        self.root = root; self.vault = vault; self.cap = cap; self.defaults = defaults
        dismissed = defaults?.stringArray(forKey: Self.dismissedKey) ?? []
        disk = ClipboardDisk(root: root, vault: vault)
        disk.reported = { [weak self] problem in Task { @MainActor in self?.diskProblem(problem) } }
        disk.found = { [weak self] items in Task { @MainActor in self?.adopt(items) } }
        // The index is read on the disk queue; items made meanwhile are kept and merged with it.
        loading = Task { [weak self, disk] in
            let found = await disk.run { $0.load() }
            self?.merge(found, now: now)
        }
    }

    var count: Int { items.count }
    func item(_ id: UUID) -> Item? { items.first { $0.id == id } }
    // Returns once the items kept from earlier runs are in the list.
    func ready() async {
        await loading?.value
        await refreshPlaceholderTitles()
    }
    // Returns once everything asked of the disk so far is done (tests).
    func settled() async {
        await ready()
        diskProblem(await disk.run { $0.problem })
    }
    // Quitting: waits for the queued writes, so a draft edited last isn't lost.
    func flush() { disk.flushNow() }
    // Tests: `hook` runs on the disk queue once the folder is open, before each file is written.
    func beforeDiskWrite(_ hook: @escaping @Sendable () -> Void) async { await disk.run { $0.beforeWrite = hook } }
    func revision(_ id: UUID) -> Int { revisions[id] ?? 0 }
    private func touch(_ id: UUID) { revisions[id, default: 0] += 1 }

    // MARK: adding

    @discardableResult func add(clip draft: ClipDraft, source: String?, now: Date = Date()) -> UUID {
        var draft = draft
        draft.resolvePlaceholderTitle(url: draft.source)
        let item = Item(id: UUID(), kind: .clip, title: Self.field(draft.displayTitle(url: draft.source), Self.titleLimit),
                        source: Self.field(draft.site ?? source, Self.sourceLimit), url: Self.field(draft.source, Self.urlLimit),
                        at: now, bytes: draft.markdown.utf8.count)
        insert(item, content: Content(draft: draft))
        return item.id
    }
    @discardableResult func add(capture text: String, title: String, source: String?, url: String?, now: Date = Date()) -> UUID {
        let kept = ClipDraft.prefix(text, bytes: Self.textLimit)
        let resolved = ClipDraft.isPlaceholderTitle(title)
            ? ClipDraft(title: title, properties: [], body: kept).displayTitle(url: url)
            : title
        let item = Item(id: UUID(), kind: .capture, title: Self.field(resolved, Self.titleLimit), source: Self.field(source, Self.sourceLimit),
                        url: Self.field(url, Self.urlLimit), at: now, bytes: kept.utf8.count)
        insert(item, content: Content(text: kept))
        return item.id
    }
    @discardableResult func add(dictation text: String, at: Date) -> UUID {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let item = Item(id: UUID(), kind: .dictation, title: Self.field(first, Self.lineLimit), source: nil, url: nil, at: at, bytes: text.utf8.count)
        spoken[item.id] = text
        items.insert(item, at: 0)
        // Dictations never reach the index, so it is only rewritten when the cap dropped a kept item.
        let kept = items.count { $0.kind != .dictation }
        enforceCap()
        if items.count(where: { $0.kind != .dictation }) != kept { save() } else { changed?() }
        return item.id
    }
    private func insert(_ item: Item, content: Content) {
        items.insert(item, at: 0); touch(item.id)
        disk.write(content, for: item.id)
        enforceCap(); save()
    }
    // Over the cap, the oldest unpinned entry goes first (a saved clip's note stays in the vault).
    private func enforceCap() {
        while items.count > cap {
            let index = items.lastIndex { !$0.pinned } ?? items.count - 1
            forget(items.remove(at: index).id)
        }
    }

    // MARK: reading (on the disk queue)

    // The clip as the card edits it: the latest draft, or for a saved clip, its note as it is now
    // (read only from inside the vault: a note swapped for a link is refused).
    func draft(_ id: UUID, now: Date = Date()) async -> ClipDraft? {
        guard let item = item(id), item.kind == .clip, readable(item, now: now) else { return nil }
        let started = Date(), vault = self.vault
        let result: ClipDraft? = await disk.run { disk -> ClipDraft? in
            if let draft = disk.content(id)?.draft { return draft }
            guard let saved = item.saved, let text = ClipsVault.readNote(saved, in: vault) else { return nil }
            return ClipsVault.draft(fromNote: text, title: item.title)
        }
        guard let current = self.item(id), readable(current, now: now.addingTimeInterval(Date().timeIntervalSince(started))) else { return nil }
        return result
    }
    func retained(_ id: UUID, now: Date = Date()) -> Bool { item(id).map { readable($0, now: now) } ?? false }
    private func readable(_ item: Item, now: Date) -> Bool {
        let age = now.timeIntervalSince(item.at)
        guard age >= 0 else { return false }
        return item.kind == .dictation ? age < Self.dictationLifetime
            : item.pinned || item.saved != nil || age < Self.lifetime
    }
    // What Copy puts on the clipboard: a clip's Markdown, a capture's or dictation's text.
    func text(_ id: UUID, now: Date = Date()) async -> String? {
        guard let item = item(id), readable(item, now: now) else { return nil }
        let started = Date()
        switch item.kind {
        // Never handed out past the 10-minute rule, even between purges.
        case .dictation: return now.timeIntervalSince(item.at) < Self.dictationLifetime ? spoken[id] : nil
        case .capture:
            let result = await disk.run { $0.content(id)?.text }
            guard let current = self.item(id), readable(current, now: now.addingTimeInterval(Date().timeIntervalSince(started))) else { return nil }
            return result
        case .clip: return await draft(id, now: now)?.markdown
        }
    }
    // A saved clip edited since its save: reopening it must not claim the note matches.
    func editedSinceSave(_ id: UUID) async -> Bool {
        guard let item = item(id), item.kind == .clip, item.saved != nil else { return false }
        return await disk.run { $0.content(id)?.draft != nil }
    }
    // A capture as a clip draft, for Save to Clips: its words under the same properties a clip has.
    func captureDraft(_ id: UUID, now: Date = Date()) async -> ClipDraft? {
        guard let item = item(id), item.kind == .capture, let text = await self.text(id, now: now) else { return nil }
        var properties: [ClipDraft.Property] = []
        if let url = item.url { properties.append(.init(name: "source", kind: .text, value: url)) }
        if let source = item.source { properties.append(.init(name: "site", kind: .text, value: source)) }
        properties.append(.init(name: "clipped", kind: .datetime, value: ISO8601DateFormatter().string(from: item.at)))
        properties.append(.init(name: "tags", kind: .list, items: ["captures"]))
        let cut = ClipDraft.cut(text)
        return ClipDraft(title: item.title, properties: properties, body: cut.text, originalBytes: cut.original)
    }

    // MARK: actions on one item

    // One action at a time per item: while one runs, another on the same item is refused (nil),
    // so a double press can't save two notes or copy twice.
    func exclusive<T>(_ id: UUID, _ work: @MainActor () async -> T) async -> T? {
        guard busy.insert(id).inserted else { return nil }
        defer { busy.remove(id) }
        return await work()
    }
    // The one gate for writing an item's note, shared by the clip card and the Clipboard row: while
    // either is saving an item, a save of it from the other is refused (.busy), so a slow save
    // followed by Save to Clips can't make two notes. A draft with no entry has nothing to share.
    func savingNote(_ id: UUID?, _ write: @MainActor () async -> Result<URL, ClipsVault.SaveError>) async -> Result<URL, ClipsVault.SaveError> {
        guard let id, item(id) != nil else { return await write() }
        return await exclusive(id, write) ?? .failure(.busy)
    }
    enum RowSave: Equatable { case busy, nothing, saved(URL), failed(ClipsVault.SaveError) }
    // Save to Clips from a Clipboard row: a clip's latest draft, or a capture as a note. One that
    // is already saved (and, for a clip, not edited since) answers with its note: no second copy.
    func saveToClips(_ id: UUID, folder: String = ClipsVault.defaultFolder,
                     write: @MainActor (ClipDraft, String) async -> Result<URL, ClipsVault.SaveError>) async -> RowSave {
        await exclusive(id) {
            guard let item = item(id) else { return .nothing }
            // Already saved, unedited, and the note still there: that note. A note moved or deleted
            // meanwhile is written anew from what is kept here.
            if let saved = item.saved {
                let edited = item.kind == .clip ? await editedSinceSave(id) : false
                let vault = self.vault
                if !edited, await disk.run({ _ in ClipsVault.isNote(saved, in: vault) }) { return .saved(saved) }
            }
            guard let draft = item.kind == .clip ? await draft(id) : await captureDraft(id) else { return .nothing }
            switch await write(draft, folder) {
            case let .success(file): markSaved(id, file: file, draft: draft); return .saved(file)
            case let .failure(error): return .failed(error)
            }
        } ?? .busy
    }

    // MARK: changing

    func update(_ id: UUID, draft: ClipDraft) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].kind == .clip else { return }
        items[index].title = draft.title.isEmpty ? items[index].title : Self.field(draft.title, Self.titleLimit)
        items[index].bytes = draft.markdown.utf8.count
        touch(id)
        disk.write(Content(draft: draft), for: id); save()
    }
    func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinned = pinned; save()
    }
    // A clip's note now holds this draft, so the copy kept here is dropped, but only if it is
    // still that draft (edits made while the note was being written stay, and reopening the clip
    // shows them) and the note is inside the vault where the save said, reading back as that
    // draft. A capture keeps its text (Copy still gives the words as read) and, being saved, is
    // no longer purged.
    func markSaved(_ id: UUID, file: URL, draft: ClipDraft) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].saved = file
        if ClipDraft.isPlaceholderTitle(items[index].title) {
            items[index].title = Self.field(draft.displayTitle(url: draft.source ?? items[index].url), Self.titleLimit)
        }
        touch(id)
        if items[index].kind == .clip { disk.discard(id, ifDraftIs: draft, savedAs: file) }
        save()
    }
    // MARK: notes in the vault

    // The vault's notes listed in the Clipboard, looked for at every launch off the main actor and
    // safe to repeat: each note is known by its path in the vault (ClipsVault.key; a loose clip's
    // file name), never by its title or date. Nothing records an import as done, so nothing can be
    // marked done too early: a note that couldn't be read this time is found on a later launch, and
    // a listed loose clip whose kept copy is missing or unreadable is written again. A row deleted
    // from the Clipboard isn't brought back.
    func importFromVault(now: Date = Date()) async {
        await ready()
        let vault = self.vault
        await importSaved(await Task.detached(priority: .utility) { ClipsVault.savedNotes(in: vault) }.value)
        let rows = items.compactMap { item in item.origin.map { (item.id, $0, item.saved != nil) } }
        // Loose clips listed already whose copy reads back (or that are saved) aren't read again.
        let fine = await disk.run { disk in rows.filter { $0.2 || disk.content($0.0)?.draft != nil }.map(\.1) }
        let skip = Set(fine).union(dismissed)
        await importLoose(await Task.detached(priority: .utility) { ClipsVault.looseNotes(now: now, in: vault, skip: skip) }.value)
    }
    // Saved notes as saved clips (newest kept within the cap); one listed already, or deleted from
    // the Clipboard, is left as it is.
    func importSaved(_ notes: [ClipsVault.SavedNote]) async {
        await ready()
        guard !notes.isEmpty else { return }
        let vault = self.vault, listed = items.compactMap(\.saved), dismissed = self.dismissed.filter { $0.hasPrefix("/") }
        // Keys resolve the vault's real path, so they are worked out off the main actor.
        let (known, keys) = await Task.detached(priority: .utility) {
            (Set((listed + dismissed.map { URL(fileURLWithPath: $0) }).map { ClipsVault.key($0, in: vault) }),
             notes.map { ClipsVault.key($0.url, in: vault) })
        }.value
        let now = Set(items.compactMap { $0.saved?.standardizedFileURL.path })   // saved while the keys were worked out
        var seen = known
        let fresh = zip(notes, keys).filter { seen.insert($0.1).inserted && !now.contains($0.0.url.standardizedFileURL.path) }.map(\.0)
        guard !fresh.isEmpty else { return }
        items += fresh.map {
            let title = ClipDraft.isPlaceholderTitle($0.title) ? "Clip" : $0.title
            return Item(id: UUID(), kind: .clip, title: Self.field(title, Self.titleLimit), source: nil, url: nil, at: $0.date,
                        bytes: $0.bytes, saved: $0.url)
        }
        items.sort { $0.at > $1.at }
        enforceCap(); save()
    }
    // The loose notes the old fn+W left at the top of the vault, as unsaved clips with their own
    // date, so they keep Review, Save to Clips and Pin (and still go 48 hours after they were made).
    // One listed already gets its kept copy written again if that is missing (never over an edit,
    // and never for one saved since, whose text is its note).
    func importLoose(_ notes: [ClipsVault.LooseNote]) async {
        await ready()
        var added = false
        for note in notes where !dismissed.contains(note.name) {
            var draft = ClipDraft(note: WebClipper.Note(name: note.title, markdown: note.markdown, title: note.title))
            draft.resolvePlaceholderTitle(url: draft.source)
            if let row = items.first(where: { $0.origin == note.name }) {
                if row.saved == nil { touch(row.id); disk.restore(Content(draft: draft), for: row.id) }
                if let index = items.firstIndex(where: { $0.id == row.id }),
                   ClipDraft.isPlaceholderTitle(items[index].title) {
                    items[index].title = Self.field(draft.displayTitle(url: draft.source), Self.titleLimit)
                    added = true
                }
                continue
            }
            let title = Self.field(draft.displayTitle(url: draft.source), Self.titleLimit)
            let item = Item(id: UUID(), kind: .clip, title: title, source: Self.field(draft.site, Self.sourceLimit),
                            url: Self.field(draft.source, Self.urlLimit), at: note.date, bytes: draft.markdown.utf8.count,
                            origin: note.name)
            items.append(item); touch(item.id); added = true
            disk.write(Content(draft: draft), for: item.id)
        }
        guard added else { return }
        items.sort { $0.at > $1.at }
        enforceCap(); save()
    }
    // Entries for notes that were moved or deleted outside CursusVox (and not edited since) go.
    // Each is checked again when the answer comes back: an entry edited, saved again or changed
    // in any way meanwhile is kept, so a draft handed over while the check ran is never deleted.
    // `beforeApply` lets a test change an entry at that moment.
    func dropMissingNotes(beforeApply: (() -> Void)? = nil) async {
        await ready()
        let notes = items.compactMap { item in item.kind == .clip ? item.saved.map { (item.id, $0, revision(item.id)) } : nil }
        guard !notes.isEmpty else { return }
        let vault = self.vault
        let missing = await disk.run { disk in
            notes.filter { ClipsVault.presence(of: $0.1, in: vault) == .missing && disk.content($0.0)?.draft == nil }
        }
        beforeApply?()
        let gone = items.filter { item in
            missing.contains { $0.0 == item.id && $0.1 == item.saved && $0.2 == revision(item.id) }
        }
        guard !gone.isEmpty else { return }
        for item in gone { forget(item.id) }
        items.removeAll { item in gone.contains { $0.id == item.id } }
        save()
    }
    // Deleting a row is for good: the note it came from isn't listed again on a later launch.
    func delete(_ id: UUID) {
        if let item = item(id) { dismiss([item.origin, item.saved?.standardizedFileURL.path].compactMap { $0 }) }
        items.removeAll { $0.id == id }
        forget(id); save()
    }
    private func dismiss(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        dismissed = Array((dismissed.filter { !keys.contains($0) } + keys).suffix(Self.dismissedLimit))
        defaults?.set(dismissed, forKey: Self.dismissedKey)
    }
    // Unsaved, unpinned clips and captures go after 48 hours; dictations after 10 minutes.
    func purge(now: Date = Date()) {
        let expired = items.filter { item in
            switch item.kind {
            case .dictation: return now.timeIntervalSince(item.at) >= Self.dictationLifetime
            case .clip, .capture: return !item.pinned && item.saved == nil && now.timeIntervalSince(item.at) >= Self.lifetime
            }
        }
        guard !expired.isEmpty else { return }
        for item in expired { forget(item.id) }
        items.removeAll { item in expired.contains { $0.id == item.id } }
        if expired.contains(where: { $0.kind != .dictation }) { save() } else { changed?() }
    }
    // Dictations only exist in memory; quitting drops them at once.
    func dropDictations() {
        for item in items where item.kind == .dictation { spoken[item.id] = nil }
        items.removeAll { $0.kind == .dictation }
    }

    // MARK: disk

    // The kept items join the list (after anything made meanwhile), expired ones go, and any
    // file no entry points at (a crash between writes) is removed, but only when the kept list
    // was actually read: after a failed load nothing on disk is cleaned up (the disk keeps the
    // unread list aside rather than writing over it).
    private func merge(_ found: ClipboardDisk.Loaded, now: Date) {
        let known = Set(items.map(\.id))
        items += found.items.filter { $0.kind != .dictation && !known.contains($0.id) }
        loaded = true
        diskProblem(found.problem)
        purge(now: now)
        enforceCap(); save()
        if found.complete { disk.removeStrays(keeping: Set(items.map(\.id))) }
    }
    // Untitled / empty rows pick a heading, host or first line from their kept draft or capture text.
    func refreshPlaceholderTitles() async {
        let placeholders = items.enumerated().filter {
            $0.element.kind != .dictation && ClipDraft.isPlaceholderTitle($0.element.title)
        }
        guard !placeholders.isEmpty else { return }
        let contents: [UUID: Content] = await disk.run { disk in
            var found: [UUID: Content] = [:]
            for (_, item) in placeholders {
                if let content = disk.content(item.id) { found[item.id] = content }
            }
            return found
        }
        var touched = false
        for (_, item) in placeholders {
            guard let content = contents[item.id],
                  let current = items.firstIndex(where: { $0.id == item.id }),
                  ClipDraft.isPlaceholderTitle(items[current].title) else { continue }
            let resolved: String
            if let draft = content.draft {
                resolved = draft.displayTitle(url: draft.source ?? item.url)
            } else if let text = content.text {
                resolved = ClipDraft(title: item.title, properties: [], body: text)
                    .displayTitle(url: item.url)
            } else {
                continue
            }
            let title = Self.field(resolved, Self.titleLimit)
            guard title != items[current].title else { continue }
            items[current].title = title
            touch(item.id)
            touched = true
        }
        if touched { save() }
    }
    // The clipboard folder was replaced while running and the list found in it was taken over:
    // its entries join this one, so nothing it holds is written over or cleaned up as unknown.
    private func adopt(_ found: [Item]) {
        disk.acknowledge(Set(found.map(\.id)))
        let known = Set(items.map(\.id))
        let fresh = found.filter { $0.kind != .dictation && !known.contains($0.id) }
        guard !fresh.isEmpty else { return }
        items += fresh
        items.sort { $0.at > $1.at }
        enforceCap(); save()
    }
    private func save() {
        defer { changed?() }
        // Until the index has been read, writing it would drop what it holds; the merge writes it.
        guard loaded else { return }
        disk.writeIndex(items.filter { $0.kind != .dictation })
    }
    private func forget(_ id: UUID) {
        spoken[id] = nil; revisions[id] = nil
        disk.remove(id)
    }
    private func diskProblem(_ problem: String?) {
        guard problem != self.problem else { return }
        self.problem = problem; changed?()
    }
}

// The clipboard's files, read and written in order on one serial queue, off the main actor: a
// read queued after a write sees it. Each piece of work opens the folder afresh as a real folder
// of ours (never through a link) and does everything relative to that descriptor (SafeFolder):
// files are written under a temporary name and renamed into place inside it, read only as plain
// files within a size limit, and removed by name inside it. A folder swapped for a link mid-way
// can't redirect a write. Nothing is written bigger than it can be read back. Content that isn't
// on disk where it is read from is kept in memory here until quit, and `problem` says so.
final class ClipboardDisk: @unchecked Sendable {   // the state below is only touched on `queue`
    // What loading found. `complete` only when the kept list was read (or there was none yet):
    // otherwise nothing on disk may be cleaned up as unknown this run.
    struct Loaded: Sendable { var items: [ClipboardStore.Item]; var complete: Bool; var problem: String? }
    static let indexLimit = 8 * 1024 * 1024
    static let contentLimit = 16 * 1024 * 1024   // a 2 MB capture or a 512 KB draft, as JSON
    static let index = "index.json"
    // A kept list that couldn't be read is renamed to this prefix plus a time, never overwritten.
    static let setAsidePrefix = "index-unreadable-"

    let root: URL
    let vault: URL
    private let queue = DispatchQueue(label: "au.com.mykoala.mercurius.clipboard", qos: .utility)
    private let coalescedIndex = OSAllocatedUnfairLock<[ClipboardStore.Item]?>(initialState: nil)
    // Content not (yet) readable from the folder: kept here until it is, or until quit.
    private var memory: [UUID: ClipboardStore.Content] = [:]
    // The folder whose list this run read (or found none in, or set aside): only there is the list
    // replaced. Another folder put at the same path is a fresh load, never written over from here.
    private var owner: SafeFolder.Identity?
    // Entries taken over from such a folder's list that the store hasn't joined to its own yet:
    // every list written meanwhile keeps them.
    private var pending: [ClipboardStore.Item] = []
    private var lastProblem: String?   // from the latest open or write; the next that works clears it
    private var listProblem: String?   // the kept list wasn't read this run; stays until quit
    var problem: String? {
        listProblem ?? lastProblem
            ?? (memory.isEmpty ? nil : "Some recent items couldn't be written to the clipboard folder, so they're kept until you quit.")
    }
    var reported: (@Sendable (String?) -> Void)?
    // Entries found in the list of a folder that replaced ours while running, for the store to join.
    var found: (@Sendable ([ClipboardStore.Item]) -> Void)?
    // Tests: runs once the folder is open, before each file is written into it.
    var beforeWrite: (@Sendable () -> Void)?

    init(root: URL, vault: URL) { self.root = root; self.vault = vault }

    // Runs `work` on the queue after everything queued before it, and returns its result.
    func run<T: Sendable>(_ work: @escaping @Sendable (ClipboardDisk) -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work(self)) }
        }
    }
    private func later(_ work: @escaping @Sendable (ClipboardDisk) -> Void) {
        queue.async {
            let before = self.problem
            work(self)
            if self.problem != before { self.reported?(self.problem) }
        }
    }
    func flushNow() { queue.sync {} }

    static func name(_ id: UUID) -> String { id.uuidString + ".json" }

    // The folder as it is, for reading or removing: nil when it is missing or isn't a plain
    // folder. It leaves `problem` alone (only loading and writing decide that).
    private func existing() -> SafeFolder? { try? SafeFolder.open(root, followLink: false, create: false) }
    // The folder, opened to load or write: made if missing, refused if it is a link or a file,
    // and its mode put back to 0700; `problem` says why it can't be used.
    private func folder() -> SafeFolder? {
        do {
            let folder = try SafeFolder.open(root, followLink: false, create: true, mode: 0o700)
            try folder.excludeFromBackup()
            lastProblem = nil
            return folder
        } catch SafeFolder.Problem.link {
            lastProblem = "The clipboard folder isn't a plain folder, so items are kept until you quit."
        } catch SafeFolder.Problem.notAFolder {
            lastProblem = "The clipboard folder isn't a plain folder, so items are kept until you quit."
        } catch {
            lastProblem = "Couldn't create the clipboard folder, so items are kept until you quit."
        }
        return nil
    }

    // No list yet is a fresh start; a list that can't be read (too large, damaged, not a plain
    // file) is renamed aside and kept, never overwritten, and the run goes on without it.
    func load() -> Loaded {
        guard let folder = folder(), let here = folder.identity else { return Loaded(items: [], complete: false, problem: problem) }
        if folder.missing(Self.index) {
            owner = here
            return Loaded(items: [], complete: true, problem: problem)
        }
        if let saved = Self.readIndex(in: folder) {
            owner = here
            return Loaded(items: saved, complete: true, problem: problem)
        }
        setAside(in: folder, here)
        return Loaded(items: [], complete: false, problem: problem)
    }
    private static func readIndex(in folder: SafeFolder) -> [ClipboardStore.Item]? {
        folder.read(index, limit: indexLimit).flatMap { try? JSONDecoder().decode([ClipboardStore.Item].self, from: $0) }
    }
    // The folder at the path isn't the one whose list was read (it was replaced while running, or
    // couldn't be opened at load): loaded afresh before anything is written there. No list is a
    // fresh start; a list that reads is taken over (its entries kept in every write and handed to
    // the store); one that doesn't is set aside.
    private func takeOver(_ folder: SafeFolder, _ here: SafeFolder.Identity) {
        pending = []
        if folder.missing(Self.index) { owner = here; return }
        if let saved = Self.readIndex(in: folder) {
            owner = here
            pending = saved.filter { $0.kind != .dictation }
            found?(pending)
            return
        }
        setAside(in: folder, here)
    }
    // Taken over entries the store now holds itself: its own list keeps them from here on.
    func acknowledge(_ ids: Set<UUID>) {
        later { disk in disk.pending.removeAll { ids.contains($0.id) } }
    }
    // The list in the folder wasn't read this run: renamed to a new name beside it (never over
    // another file), so the next write can't replace it. If it can't be moved, the list isn't
    // written at all this run.
    private func setAside(in folder: SafeFolder, _ here: SafeFolder.Identity) {
        let stamp = Int(Date().timeIntervalSince1970)
        let name = "\(Self.setAsidePrefix)\(stamp)-\(UUID().uuidString.prefix(8)).bak"
        if folder.rename(Self.index, to: name) {
            owner = here
            listProblem = "The clipboard's saved list couldn't be read, so earlier items aren't shown. It was kept as \(name) in the clipboard folder."
        } else {
            listProblem = "The clipboard's saved list couldn't be read, so earlier items aren't shown and new ones are kept until you quit."
        }
    }
    func content(_ id: UUID) -> ClipboardStore.Content? {
        if let content = memory[id] { return content }
        guard let data = existing()?.read(Self.name(id), limit: Self.contentLimit) else { return nil }
        return try? JSONDecoder().decode(ClipboardStore.Content.self, from: data)
    }
    // Written only into the folder whose list was read (see `takeOver`). Coalesces rapid index
    // updates while disk I/O is busy so the serial queue cannot grow without bound.
    func writeIndex(_ items: [ClipboardStore.Item]) {
        let shouldEnqueue = coalescedIndex.withLock { latest -> Bool in
            let wasEmpty = (latest == nil)
            latest = items
            return wasEmpty
        }
        guard shouldEnqueue else { return }
        later { disk in
            guard let latest = disk.coalescedIndex.withLock({ state -> [ClipboardStore.Item]? in
                defer { state = nil }
                return state
            }) else { return }
            guard let folder = disk.folder(), let here = folder.identity else { return }
            if here != disk.owner {
                disk.takeOver(folder, here)
                guard here == disk.owner else { return }
            }
            let ids = Set(latest.map(\.id))
            guard let data = try? JSONEncoder().encode(latest + disk.pending.filter { !ids.contains($0.id) }) else { return }
            guard data.count <= Self.indexLimit else {
                disk.lastProblem = "The clipboard's list is too large to save, so recent changes are kept until you quit."
                return
            }
            disk.store(data, as: Self.index, in: folder)
        }
    }
    // The content leaves memory only once it reads back from where it is read (the folder at its
    // path): a write that landed in a folder moved away meanwhile stays recoverable until quit.
    // Content bigger than can be read back is never written; it stays in memory.
    func write(_ content: ClipboardStore.Content, for id: UUID) {
        later { disk in disk.put(content, for: id) }
    }
    // Writes the content only if none reads back for the item now (never over an edit made since).
    func restore(_ content: ClipboardStore.Content, for id: UUID) {
        later { disk in if disk.content(id)?.draft == nil { disk.put(content, for: id) } }
    }
    private func put(_ content: ClipboardStore.Content, for id: UUID) {
        let name = Self.name(id)
        if let data = try? JSONEncoder().encode(content), data.count <= Self.contentLimit,
           let folder = folder(), store(data, as: name, in: folder),
           existing()?.read(name, limit: Self.contentLimit) == data {
            memory[id] = nil
        } else {
            memory[id] = content
        }
    }
    func remove(_ id: UUID) {
        later { disk in disk.memory[id] = nil; disk.existing()?.remove(Self.name(id)) }
    }
    // Drops the kept draft only while it is still the one that was saved, and only once the note
    // is where the save said, inside the vault, reading back as that draft: otherwise the draft
    // stays, so nothing is lost to a save that went wrong.
    func discard(_ id: UUID, ifDraftIs draft: ClipDraft, savedAs file: URL) {
        later { disk in
            guard let kept = disk.content(id), kept.draft == nil || kept.draft == draft,
                  ClipsVault.readNote(file, in: disk.vault) == draft.markdown else { return }
            disk.memory[id] = nil; disk.existing()?.remove(Self.name(id))
        }
    }
    // Files no entry points at (a crash between writes, an interrupted temporary file) go. Called
    // only after the kept list was read, and only in the folder it was read from (not one put in
    // its place since). While a list set aside is in the folder, item files stay: they may be
    // that list's.
    func removeStrays(keeping ids: Set<UUID>) {
        later { disk in
            guard let folder = disk.existing(), let here = folder.identity, here == disk.owner else { return }
            let entries = folder.entries()
            let setAside = entries.contains { $0.name.hasPrefix(Self.setAsidePrefix) }
            let known = Set((ids.union(disk.pending.map(\.id))).map(Self.name))
            for entry in entries where entry.kind == .file
                && ((!setAside && entry.name.hasSuffix(".json") && entry.name != Self.index && !known.contains(entry.name))
                    || (entry.name.hasPrefix(".") && entry.name.hasSuffix(".tmp"))) {
                folder.remove(entry.name)
            }
        }
    }

    // Writes one file (0600) in place in a single step; false (and `problem`) when it can't.
    @discardableResult private func store(_ data: Data, as name: String, in folder: SafeFolder) -> Bool {
        beforeWrite?()
        do { try folder.replace(name, data: data) } catch {
            lastProblem = "Couldn't write to the clipboard folder, so recent items are kept until you quit."
            return false
        }
        return true
    }
}
