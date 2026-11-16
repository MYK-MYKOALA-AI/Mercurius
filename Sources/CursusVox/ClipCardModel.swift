import Foundation

// What the clip card can do with its draft, and when. Kept apart from the views so the rules
// are testable: nothing acts before the draft is ready (R2), an edited draft is never replaced
// by a later extraction (R1), and success is only reported once the write is confirmed (R5/R6).
@MainActor final class ClipCardModel {
    enum Phase: Equatable { case extracting(String), ready, failed(String) }
    enum Action: String, CaseIterable, Sendable {
        case save, copyMarkdown, copyPlain, saveAndCopy, openInObsidian, revealInFinder
        var title: String {
            switch self {
            case .save: return "Save to Clips"
            case .copyMarkdown: return "Copy Markdown"
            case .copyPlain: return "Copy plain text"
            case .saveAndCopy: return "Save and copy"
            case .openInObsidian: return "Open in Obsidian"
            case .revealInFinder: return "Reveal in Finder"
            }
        }
        var symbol: String {
            switch self {
            case .save: return "tray.and.arrow.down"
            case .copyMarkdown: return "doc.on.doc"
            case .copyPlain: return "text.alignleft"
            case .saveAndCopy: return "square.and.arrow.down.on.square"
            case .openInObsidian: return "arrow.up.forward.app"
            case .revealInFinder: return "folder"
            }
        }
    }
    enum Outcome: Equatable { case done(String), failed(String) }
    // The side effects, supplied by the app; tests pass fakes. `copy` and `open` return nil on
    // success (the clipboard read back the text, the file opened) or the reason they didn't.
    // Save is async so the app can write the note off the main thread; it is given the clipboard
    // entry the draft belongs to, so the app can hold that entry's save gate while it writes.
    struct Effects {
        var save: @MainActor (ClipDraft, String, UUID?) async -> Result<URL, ClipsVault.SaveError>
        var copy: @MainActor (String) -> String?
        var open: @MainActor (URL) async -> String?
        var reveal: @MainActor (URL) -> Void
        // Whether the note the card saved is still there holding this draft (checked off the main
        // actor), before Save, Reveal or Open reuse it; when it isn't, the draft is saved anew.
        var stillSaved: @MainActor (URL, ClipDraft) async -> Bool = { file, draft in
            await Task.detached(priority: .userInitiated) { ClipsVault.holds(file, draft) }.value
        }
        // A copy effect through a weak owner: the owner's nil (copied) stays a success, and only
        // a gone owner is a failure.
        static func copying<Owner: AnyObject & Sendable>(_ owner: Owner,
                                             _ copy: @escaping @MainActor (Owner, String) -> String?) -> @MainActor (String) -> String? {
            { [weak owner] text in
                guard let owner else { return "Mercurius is quitting" }
                return copy(owner, text)
            }
        }
    }

    private(set) var phase: Phase = .extracting("")
    private(set) var draft: ClipDraft?
    // Something to know about this clip's capture, shown on the card (a thin Google Docs read).
    private(set) var notice: String?
    private(set) var edited = false
    // Which clip the card is showing. An extraction answers with the token it began with, so a
    // late result from an earlier fn+W (or one started before a clip was reopened) is ignored.
    private(set) var token = 0
    // An action is running: the buttons stay off so a double press can't save twice.
    private(set) var busy = false
    private var handedOver: ClipDraft?   // the draft last given to the clipboard, so it isn't written twice
    var folder = ClipsVault.defaultFolder
    var obsidianInstalled = false
    var storeID: UUID?
    // The note this draft was last saved as; saving again unchanged reuses it rather than making
    // " 2", as long as it is still there holding the draft.
    private(set) var saved: (url: URL, draft: ClipDraft, folder: String)?
    // A note was written for the clipboard entry it came from (captured before the write, so a
    // clip reopened meanwhile is never marked by mistake).
    var onSaved: ((URL, ClipDraft, UUID?) -> Void)?

    var ready: Bool { phase == .ready && draft != nil }
    var canAct: Bool { ready && !busy }
    // The split button's dropdown, in order. Open in Obsidian only when Obsidian is installed.
    var menu: [Action] {
        [.copyMarkdown, .copyPlain, .saveAndCopy] + (obsidianInstalled ? [.openInObsidian] : []) + [.revealInFinder]
    }

    // A new extraction starts: the card shows it is working and nothing can act yet. Returns the
    // token the extraction answers with.
    @discardableResult func begin(_ message: String) -> Int {
        token += 1
        phase = .extracting(message); draft = nil; notice = nil; edited = false; saved = nil; storeID = nil; handedOver = nil
        folder = ClipsVault.defaultFolder
        return token
    }
    // A finished extraction. Ignored (false) when it belongs to another clip or the user has
    // already changed the draft: edits are never replaced.
    @discardableResult func offer(_ new: ClipDraft, token: Int, notice: String? = nil) -> Bool {
        guard token == self.token, !edited else { return false }
        draft = new; phase = .ready; saved = nil; self.notice = notice
        return true
    }
    // A draft reopened from the clipboard, already saved or not.
    func load(_ draft: ClipDraft, savedAt file: URL?, folder: String, storeID: UUID?) {
        token += 1
        self.draft = draft; phase = .ready; notice = nil; edited = false; self.folder = folder; self.storeID = storeID
        saved = file.map { ($0, draft, folder) }; handedOver = nil
    }
    // Extraction failed. A draft already on the card stays; only an empty card shows the failure.
    func fail(_ reason: String, token: Int) {
        guard token == self.token, draft == nil else { return }
        phase = .failed(reason)
    }
    // The draft as last saved, unchanged since: nothing new to keep.
    var savedUnchanged: Bool {
        guard let saved, let draft else { return false }
        return saved.draft == draft && saved.folder == folder
    }
    // The user's edits the main clipboard doesn't have yet (nil when there are none, or the draft
    // is exactly what was saved). Taking them marks them handed over.
    func takeEdits() -> (draft: ClipDraft, storeID: UUID?)? {
        guard edited, !savedUnchanged, let draft, draft != handedOver else { return nil }
        handedOver = draft
        return (draft, storeID)
    }
    func edit(_ change: (inout ClipDraft) -> Void) {
        guard var copy = draft else { return }
        change(&copy)
        if copy != draft { draft = copy; edited = true }
    }

    // ⌘S and ⌘↩ save; ⌘C copies the Markdown unless text is selected in a field (then it copies that).
    static func shortcut(_ key: String, command: Bool, hasSelection: Bool) -> Action? {
        guard command else { return nil }
        switch key {
        case "s", "\r": return .save
        case "c": return hasSelection ? nil : .copyMarkdown
        default: return nil
        }
    }

    func perform(_ action: Action, _ effects: Effects) async -> Outcome {
        guard canAct, let draft else { return .failed(busy ? "Still working on the last action" : "The clip isn't ready yet") }
        busy = true
        defer { busy = false }
        switch action {
        case .save:
            switch await ensureSaved(draft, effects) {
            case let .success(file): return .done("Saved to " + ClipsVault.relative(file))
            case let .failure(error): return .failed("Not saved: " + error.reason)
            }
        case .copyMarkdown:
            return effects.copy(draft.markdown).map { .failed("Not copied: " + $0) } ?? .done("Copied as Markdown")
        case .copyPlain:
            return effects.copy(draft.plainText).map { .failed("Not copied: " + $0) } ?? .done("Copied as plain text")
        case .saveAndCopy:
            // Save and copy one resolved snapshot, even if editing continues.
            var resolved = draft
            resolved.resolvePlaceholderTitle(url: resolved.source)
            switch await ensureSaved(resolved, effects) {
            case let .failure(error): return .failed("Not saved: " + error.reason)
            case let .success(file):
                if let problem = effects.copy(resolved.markdown) { return .failed("Saved, but not copied: " + problem) }
                return .done("Saved to \(ClipsVault.relative(file)) and copied")
            }
        case .openInObsidian, .revealInFinder:
            // Both need a file, so an unsaved draft is saved first.
            switch await ensureSaved(draft, effects) {
            case let .failure(error): return .failed("Not saved: " + error.reason)
            case let .success(file):
                if action == .revealInFinder { effects.reveal(file); return .done("Shown in Finder") }
                return await effects.open(file).map { .failed($0) } ?? .done("Opened in Obsidian")
            }
        }
    }
    private func ensureSaved(_ draft: ClipDraft, _ effects: Effects) async -> Result<URL, ClipsVault.SaveError> {
        var draft = draft
        draft.resolvePlaceholderTitle(url: draft.source)
        let folder = self.folder, token = self.token, entry = storeID
        if let saved, saved.draft == draft, saved.folder == folder, await effects.stillSaved(saved.url, draft) {
            return .success(saved.url)
        }
        let result = await effects.save(draft, folder, entry)
        if case let .success(file) = result {
            if token == self.token {
                saved = (file, draft, folder)
                if var current = self.draft, ClipDraft.isPlaceholderTitle(current.title) {
                    // The body and properties may have changed during the save.
                    current.title = draft.title
                    self.draft = current
                }
            }
            onSaved?(file, draft, entry)
        }
        return result
    }
}
