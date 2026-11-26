import AppKit
import Foundation
import Testing
@testable import CursusVox

// Fake side effects that record what the card asked for.
@MainActor private final class Recorder {
    var saves: [(ClipDraft, String)] = []
    var copies: [String] = []
    var opened: [URL] = []
    var revealed: [URL] = []
    var saveResult: Result<URL, ClipsVault.SaveError> = .success(URL(fileURLWithPath: "/tmp/Mercurius Clips/Clips/Note.md"))
    var copyProblem: String?
    var onSave: (() async -> Void)?
    var noteThere = true   // the saved note is still there, holding the draft
    var effects: ClipCardModel.Effects {
        ClipCardModel.Effects(
            save: { draft, folder, _ in
                self.saves.append((draft, folder)); await self.onSave?(); return self.saveResult
            },
            copy: { text in self.copies.append(text); return self.copyProblem },
            open: { url in self.opened.append(url); return nil },
            reveal: { url in self.revealed.append(url) },
            stillSaved: { _, _ in self.noteThere })
    }
}

private let sample = ClipDraft(title: "Ship it", properties: [.init(name: "source", kind: .text, value: "https://a.example/x")],
                               body: "# Ship\n\nWe ship **Friday**.")

// R2: nothing acts until the draft is ready.
@MainActor @Test func nothingActsBeforeTheDraftIsReady() async {
    let model = ClipCardModel(), fake = Recorder()
    let token = model.begin("Reading…")
    #expect(!model.ready && !model.canAct)
    for action in ClipCardModel.Action.allCases {
        #expect(await model.perform(action, fake.effects) == .failed("The clip isn't ready yet"))
    }
    #expect(fake.saves.isEmpty && fake.copies.isEmpty && fake.opened.isEmpty && fake.revealed.isEmpty)
    model.fail("No page", token: token)
    #expect(model.phase == .failed("No page") && !model.canAct)
    #expect(model.offer(sample, token: token))
    #expect(model.canAct)
}

// R1: the user's edits are never replaced, and a late extraction never lands on another clip.
@MainActor @Test func editsAreNeverOverwritten() {
    let model = ClipCardModel()
    let first = model.begin("Reading…")
    #expect(model.offer(sample, token: first))
    model.edit { $0.title = "My title" }
    #expect(model.edited)
    var refreshed = sample; refreshed.body = "re-extracted"
    #expect(!model.offer(refreshed, token: first))
    #expect(model.draft?.title == "My title" && model.draft?.body == sample.body)
    // An extraction from before a reopen (or an earlier fn+W) is ignored.
    let second = model.begin("Reading…")
    model.load(sample, savedAt: nil, folder: "Work", storeID: UUID())
    #expect(!model.offer(refreshed, token: second))
    model.fail("late failure", token: second)
    #expect(model.phase == .ready && model.draft == sample && model.folder == "Work")
    // An unchanged edit doesn't count.
    model.edit { $0.title = sample.title }
    #expect(!model.edited)
}

// The split button: each action does exactly its own thing, and success is only claimed after it happened.
@MainActor @Test func splitButtonActionsRouteToTheirEffects() async {
    let model = ClipCardModel(), fake = Recorder()
    model.offer(sample, token: model.begin(""))
    var saved: [UUID?] = []
    let entry = UUID(); model.storeID = entry
    model.onSaved = { _, _, id in saved.append(id) }

    #expect(await model.perform(.copyMarkdown, fake.effects) == .done("Copied as Markdown"))
    #expect(await model.perform(.copyPlain, fake.effects) == .done("Copied as plain text"))
    #expect(fake.copies == [sample.markdown, sample.plainText] && fake.saves.isEmpty)

    #expect(await model.perform(.save, fake.effects) == .done("Saved to Note.md"))
    #expect(fake.saves.count == 1 && fake.saves[0].1 == "Clips" && saved == [entry])
    // Saving the same draft again keeps the same note; Reveal and Open use it without a new file.
    #expect(await model.perform(.save, fake.effects) == .done("Saved to Note.md"))
    #expect(await model.perform(.revealInFinder, fake.effects) == .done("Shown in Finder"))
    #expect(await model.perform(.openInObsidian, fake.effects) == .done("Opened in Obsidian"))
    #expect(fake.saves.count == 1 && fake.revealed.count == 1 && fake.opened.count == 1)
    // Save and copy after an edit writes a new note, then copies the edited Markdown.
    model.edit { $0.body += "\n\nMore." }
    #expect(await model.perform(.saveAndCopy, fake.effects) == .done("Saved to Note.md and copied"))
    #expect(fake.saves.count == 2 && fake.copies.last == model.draft?.markdown)
    // A different folder is a new save too.
    model.folder = "Work"
    _ = await model.perform(.save, fake.effects)
    #expect(fake.saves.count == 3 && fake.saves[2].1 == "Work")

    #expect(model.menu == [.copyMarkdown, .copyPlain, .saveAndCopy, .revealInFinder])
    model.obsidianInstalled = true
    #expect(model.menu == [.copyMarkdown, .copyPlain, .saveAndCopy, .openInObsidian, .revealInFinder])
    #expect(ClipCardModel.shortcut("s", command: true, hasSelection: false) == .save)
    #expect(ClipCardModel.shortcut("\r", command: true, hasSelection: true) == .save)
    #expect(ClipCardModel.shortcut("c", command: true, hasSelection: false) == .copyMarkdown)
    #expect(ClipCardModel.shortcut("c", command: true, hasSelection: true) == nil)
    #expect(ClipCardModel.shortcut("s", command: false, hasSelection: false) == nil)
}

// R5/R6: failures say why and nothing is reported as done.
@MainActor @Test func failuresAreReportedNotHidden() async {
    let model = ClipCardModel(), fake = Recorder()
    model.offer(sample, token: model.begin(""))
    var saved = 0
    model.onSaved = { _, _, _ in saved += 1 }
    fake.saveResult = .failure(.noSpace)
    #expect(await model.perform(.save, fake.effects) == .failed("Not saved: The disk is full"))
    #expect(await model.perform(.saveAndCopy, fake.effects) == .failed("Not saved: The disk is full"))
    #expect(await model.perform(.revealInFinder, fake.effects) == .failed("Not saved: The disk is full"))
    #expect(saved == 0 && model.saved == nil && fake.copies.isEmpty && fake.revealed.isEmpty)
    fake.copyProblem = "a password field is active"
    #expect(await model.perform(.copyMarkdown, fake.effects) == .failed("Not copied: a password field is active"))
    fake.saveResult = .success(URL(fileURLWithPath: "/tmp/n.md"))
    #expect(await model.perform(.saveAndCopy, fake.effects) == .failed("Saved, but not copied: a password field is active"))
}

// A second press while a save is still writing is refused, so one press makes one note.
@MainActor @Test func aSecondPressWhileBusyIsRefused() async {
    let model = ClipCardModel(), fake = Recorder()
    model.offer(sample, token: model.begin(""))
    var inner: ClipCardModel.Outcome?
    fake.onSave = { inner = await model.perform(.save, fake.effects) }
    #expect(await model.perform(.save, fake.effects) == .done("Saved to Note.md"))
    #expect(inner == .failed("Still working on the last action"))
    #expect(fake.saves.count == 1 && !model.busy)
}

// Edits reach the main clipboard once each, with the entry they belong to; a draft saved as it
// stands has nothing new to hand over. (The card calls this when typing pauses, before an action
// and on close; the card's own drawing is covered by the opt-in render test.)
@MainActor @Test func editsAreHandedToTheClipboardOnce() async {
    let model = ClipCardModel(), fake = Recorder()
    let entry = UUID()
    model.offer(sample, token: model.begin(""))
    model.storeID = entry
    #expect(model.takeEdits() == nil)   // nothing typed yet
    model.edit { $0.title = "Edited" }
    let edits = model.takeEdits()
    #expect(edits?.draft.title == "Edited" && edits?.storeID == entry)
    #expect(model.takeEdits() == nil)   // already handed over
    model.edit { $0.body = "changed" }
    #expect(model.takeEdits()?.draft.body == "changed")
    model.edit { $0.title = "Saved as is" }
    _ = await model.perform(.save, fake.effects)
    #expect(model.takeEdits() == nil)   // the note holds it
    // A new clip starts clean.
    model.begin("")
    #expect(model.takeEdits() == nil)
}

// The app's copy effect reports a copy that worked as done; only a gone
// app is a failure (a nil success was being turned into "CursusVox is quitting").
@MainActor private final class Board { var problem: String?; var copied: [String] = [] }
@MainActor @Test func copyEffectKeepsSuccessASuccess() async {
    var board: Board? = Board()
    let copy = ClipCardModel.Effects.copying(board!) { board, text in board.copied.append(text); return board.problem }
    #expect(copy("words") == nil && board?.copied == ["words"])
    board?.problem = "the clipboard didn't keep it"
    #expect(copy("words") == "the clipboard didn't keep it")
    board = nil
    #expect(copy("words") == "Mercurius is quitting")
    let model = ClipCardModel(), fake = Recorder()
    model.offer(sample, token: model.begin(""))
    var effects = fake.effects
    let owner = Board()
    effects.copy = ClipCardModel.Effects.copying(owner) { _, _ in nil }
    #expect(await model.perform(.copyMarkdown, effects) == .done("Copied as Markdown"))
    #expect(await model.perform(.saveAndCopy, effects) == .done("Saved to Note.md and copied"))
}

// A thin Google Docs read still loads, and the card carries the hint to show; a new clip clears it.
@MainActor @Test func thinDocsClipsCarryTheHint() {
    #expect(GoogleDocs.notice(url: "https://docs.google.com/document/d/x/edit", words: 84) == GoogleDocs.hint)
    #expect(GoogleDocs.notice(url: "https://docs.google.com/document/d/x/edit", words: 900) == nil)
    #expect(GoogleDocs.notice(url: "https://example.com/doc", words: 10) == nil)
    let model = ClipCardModel()
    #expect(model.offer(sample, token: model.begin(""), notice: GoogleDocs.hint))
    #expect(model.ready && model.notice == GoogleDocs.hint)
    model.begin("")
    #expect(model.notice == nil)
    model.load(sample, savedAt: nil, folder: "Clips", storeID: nil)
    #expect(model.notice == nil)
}

// The card hands its edits to the clipboard before an action runs, so the
// save's completion (which drops the stored copy only if it is what was saved) sees them.
@MainActor @Test func cardHandsEditsOverBeforeSaving() async {
    _ = NSApplication.shared
    let card = ClipCard()
    card.folders = { ["Clips"] }
    card.planned = { title, _ in URL(fileURLWithPath: "/tmp/v/Clips/\(title).md") }
    var handed: [ClipDraft] = []
    var handedAtSave: [ClipDraft] = []
    card.changed = { draft, _ in handed.append(draft) }
    card.effects = ClipCardModel.Effects(
        save: { _, _, _ in handedAtSave = handed; return .success(URL(fileURLWithPath: "/tmp/v/Clips/n.md")) },
        copy: { _ in nil }, open: { _ in nil }, reveal: { _ in })
    let token = card.begin("Reading…", site: "Safari")
    card.offer(sample, token: token, storeID: UUID())
    card.model.edit { $0.title = "Edited first" }
    await card.run(.save)
    #expect(handedAtSave.map(\.title) == ["Edited first"])
    #expect(card.model.saved?.draft.title == "Edited first")
    // The saved path is read out as it is shown, not as "Saves to Saved as …".
    func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
    let path = all(card.panel.contentView!).compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("Saved as ") }
    #expect(path?.accessibilityLabel() == path?.stringValue && path != nil)
    card.model.edit { $0.title = "Edited again" }
    card.offer(sample, token: card.begin("", site: "Safari"), storeID: nil)
    await card.settled()
    let planned = all(card.panel.contentView!).compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("/tmp/v/Clips/") }
    #expect(planned?.accessibilityLabel()?.hasPrefix("Saves to ") == true)
    card.panel.orderOut(nil)
}

// However long the title and however many properties, the card fits the
// screen and Save and Copy stay in view; the content scrolls instead.
@MainActor @Test func theFooterStaysInViewOnAnOverlongClip() throws {
    _ = NSApplication.shared
    let card = ClipCard()
    card.folders = { ["Clips"] }
    card.planned = { title, _ in URL(fileURLWithPath: "/tmp/v/Clips/x.md") }
    card.propertiesOpen = true
    let many = (0..<60).map { ClipDraft.Property(name: "field\($0)", kind: .text, value: "value \($0)") }
    let title = String(repeating: "A very long title that keeps going ", count: 40)
    card.offer(ClipDraft(title: title, properties: many, body: "Body"), token: card.begin("", site: "Safari"), storeID: nil)
    card.present(); card.settleForSnapshot()
    let screen = (card.panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
    #expect(card.panel.frame.height <= screen - 24 + 0.5)
    func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
    let root = try #require(card.panel.contentView)
    let split = try #require(all(root).first { $0 is SplitButton })
    let frame = split.convert(split.bounds, to: root)
    #expect(root.bounds.contains(frame), "\(frame) in \(root.bounds)")
    #expect(all(root).contains { ($0 as? NSScrollView)?.documentView is FlippedView })
    card.panel.orderOut(nil)
}

// Records what the planner was asked, from whichever thread it ran on.
private final class Planner: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = [], onMain = false
    func record(_ title: String, main: Bool) { lock.lock(); asked.append(title); onMain = onMain || main; lock.unlock() }
    var titles: [String] { lock.lock(); defer { lock.unlock() }; return asked }
    var ranOnMain: Bool { lock.lock(); defer { lock.unlock() }; return onMain }
}

// The card's planned path and folder list are worked out off the main actor
// (a slow vault never stalls typing); the path shows at once, and a late answer for an older
// title is never shown.
@MainActor @Test func cardPlansPathsOffTheMainActorAndShowsOnlyTheLatest() async throws {
    _ = NSApplication.shared
    let card = ClipCard()
    let planner = Planner()
    card.folders = { Thread.sleep(forTimeInterval: 0.2); return ["Clips", "Slow"] }
    card.guess = { title, _ in URL(fileURLWithPath: "/tmp/v/Clips/\(title).md") }
    card.planned = { title, _ in
        planner.record(title, main: Thread.isMainThread)
        if title == "First" { Thread.sleep(forTimeInterval: 0.3) }
        return URL(fileURLWithPath: "/tmp/v/Clips/\(title) 2.md")
    }
    func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
    func path() -> String? {
        all(card.panel.contentView!).compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("/tmp/v/Clips/") }?.stringValue
    }
    card.offer(ClipDraft(title: "First", properties: [], body: "x"), token: card.begin("", site: "Safari"), storeID: nil)
    #expect(path() == "/tmp/v/Clips/First.md")       // at once, from the title alone
    card.load(ClipDraft(title: "Second", properties: [], body: "y"), savedAt: nil, folder: "Clips", storeID: nil)
    #expect(path() == "/tmp/v/Clips/Second.md")
    await card.settled()
    #expect(path() == "/tmp/v/Clips/Second 2.md")    // First's late answer was dropped
    #expect(planner.titles == ["First", "Second"] && !planner.ranOnMain)
    let box = try #require(all(card.panel.contentView!).compactMap { $0 as? NSComboBox }.first)
    #expect(box.objectValues as? [String] == ["Clips", "Slow"])
    card.panel.orderOut(nil)
}


@MainActor @Test(arguments: ["", "Untitled"])
func editsDuringPlaceholderTitleSaveSurviveCompletion(_ placeholder: String) async throws {
    let model = ClipCardModel(), fake = Recorder()
    var initial = sample
    initial.title = placeholder
    model.offer(initial, token: model.begin(""))
    var resume: CheckedContinuation<Void, Never>?
    fake.onSave = { await withCheckedContinuation { resume = $0 } }
    let saving = Task { await model.perform(.save, fake.effects) }
    for _ in 0..<1000 where resume == nil { await Task.yield() }
    guard let resume else { saving.cancel(); Issue.record("Save never began"); return }
    model.edit {
        $0.body = "Changed while disk write was pending"
        $0.properties.append(.init(name: "status", kind: .text, value: "new edit"))
    }
    let editedProperties = model.draft?.properties
    resume.resume()
    _ = await saving.value
    #expect(model.draft?.body == "Changed while disk write was pending")
    #expect(model.draft?.properties == editedProperties)
    #expect(model.draft?.title == fake.saves.first?.0.title)
    #expect(model.saved?.draft.body == initial.body)
    #expect(!model.savedUnchanged)
    #expect(model.takeEdits()?.draft.body == "Changed while disk write was pending")
}


@MainActor @Test(arguments: ["", "Untitled"])
func saveAndCopyUsesTheSameResolvedDraft(_ placeholder: String) async throws {
    let model = ClipCardModel(), fake = Recorder()
    let initial = ClipDraft(title: placeholder, properties: [], body: "# Design notes\n\nOriginal body")
    model.offer(initial, token: model.begin(""))
    fake.onSave = { model.edit { $0.body = "Newer unsaved edit" } }
    _ = await model.perform(.saveAndCopy, fake.effects)
    let written = try #require(fake.saves.first?.0)
    #expect(written.title == "Design notes")
    #expect(fake.copies == [written.markdown])
    #expect(model.draft?.body == "Newer unsaved edit")
    #expect(!model.savedUnchanged)
}
