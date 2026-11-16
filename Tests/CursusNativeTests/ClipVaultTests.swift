import Foundation
import Testing
@testable import CursusVox

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}
private func mode(_ url: URL) throws -> Int? {
    try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
}

// R17/R19: every value is quoted and escaped, so nothing in a page can end the frontmatter or add a key.
@Test func frontmatterEscapesEverythingAPageCanThrowAtIt() {
    #expect(Frontmatter.quoted(#"say "hi" \ bye"#) == #""say \"hi\" \\ bye""#)
    #expect(Frontmatter.quoted("a\nb\rc\td") == #""a\nb\rc\td""#)
    #expect(Frontmatter.quoted("bell\u{07}del\u{7F}c1\u{85}ls\u{2028}ps\u{2029}bom\u{FEFF}")
            == #""bell\u0007del\u007Fc1\u0085ls\u2028ps\u2029bom\uFEFF""#)
    let hostile = "Title\n---\nevil: true\n# not a heading"
    let note = Frontmatter.render(title: hostile, properties: [
        .init(name: "description", kind: .text, value: "a: b\n---"),
        .init(name: "tags", kind: .list, items: ["one", "\"two\"", "three\\"]),
        .init(name: "published", kind: .date, value: "2026-10-13"),
        .init(name: "updated", kind: .datetime, value: "2026-10-13; rm -rf"),
        .init(name: "weird key: x", kind: .text, value: "v"),
        .init(name: "aliases", kind: .list)
    ])
    let lines = note.components(separatedBy: "\n")
    // Opening and closing markers only, and every line a key, a list item or the end.
    #expect(lines.filter { $0 == "---" }.count == 2)
    #expect(lines.contains("published: 2026-10-13"))
    #expect(lines.contains(#"updated: "2026-10-13; rm -rf""#))
    #expect(lines.contains(#""weird key: x": "v""#))
    #expect(lines.contains("aliases: []"))
    #expect(lines.contains(#"  - "\"two\"""#))
    // And it reads back as written.
    let parsed = Frontmatter.parse(note + "Body")
    #expect(parsed.body == "Body")
    #expect(parsed.fields.first { $0.key == "title" }?.values == [hostile])
    #expect(parsed.fields.first { $0.key == "description" }?.values == ["a: b\n---"])
    #expect(parsed.fields.first { $0.key == "tags" }?.values == ["one", "\"two\"", "three\\"])
    #expect(parsed.fields.first { $0.key == "weird key: x" }?.values == ["v"])
}

@Test func draftReadsTheClippersNoteAndWritesItBackTheSame() {
    let markdown = """
    ---
    title: "Ship it Friday"
    source: "https://notes.example.com/ship"
    author:
      - "[[Lee Example]]"
    published: 2026-10-01
    created: 2026-10-13T09:30:00+11:00
    description: "How we ship: every week."
    tags:
      - "clippings"
    ---
    # Ship it Friday

    We ship every **Friday**.
    """
    let draft = ClipDraft(note: WebClipper.Note(name: "Ship it Friday", markdown: markdown, title: "Ship it Friday"))
    #expect(draft.title == "Ship it Friday")
    #expect(draft.properties.map(\.name) == ["source", "author", "published", "created", "description", "tags"])
    #expect(draft.properties.map(\.kind) == [.text, .list, .date, .datetime, .text, .list])
    #expect(draft.site == "notes.example.com")
    #expect(draft.body.hasPrefix("# Ship it Friday"))
    let again = ClipDraft(note: WebClipper.Note(name: "x", markdown: draft.markdown, title: draft.title))
    #expect(again == draft)
    #expect(draft.plainText == "Ship it Friday\n\nShip it Friday\n\nWe ship every Friday.")
}

// R25: a long page keeps its first part and says so, in the card and in the note.
@Test func longPagesAreCutToTheBudgetWithANotice() {
    let paragraph = String(repeating: "word ", count: 200) + "\n\n"
    let body = String(repeating: paragraph, count: 1000)
    let draft = ClipDraft(note: WebClipper.Note(name: "Long", markdown: body, title: "Long"))
    #expect(draft.body.utf8.count <= ClipDraft.budget)
    #expect(draft.originalBytes == body.trimmingCharacters(in: .newlines).utf8.count)
    #expect(draft.truncationNotice?.hasPrefix("Long page: kept the first") == true)
    #expect(draft.markdown.contains("> [!note] Long page"))
    #expect(ClipDraft.prefix("🦘🦘", bytes: 5) == "🦘")
    let short = ClipDraft(title: "t", properties: [], body: "short")
    #expect(short.truncationNotice == nil && !short.markdown.contains("[!note]"))
}

@Test func transcriptHookAppendsWithinTheBudget() {
    var draft = ClipDraft(title: "Video", properties: [], body: "Description")
    draft.appendTranscript("  hello there  ")
    #expect(draft.body == "Description\n\n## Transcript\n\nhello there")
    draft.appendTranscript("   ")
    #expect(draft.body.hasSuffix("hello there"))
    var big = ClipDraft(title: "Video", properties: [], body: "")
    big.appendTranscript(String(repeating: "a ", count: ClipDraft.budget))
    #expect(big.body.utf8.count <= ClipDraft.budget && big.originalBytes != nil)
}

@Test func placeholderTitlesPreferHeadingThenHostThenFirstLine() {
    #expect(ClipDraft.isPlaceholderTitle("") && ClipDraft.isPlaceholderTitle("untitled")
            && ClipDraft.isPlaceholderTitle("Untitled") && !ClipDraft.isPlaceholderTitle("Ship it"))
    #expect(ClipDraft(title: "", properties: [], body: "Intro\n\n# Real Heading\n\nBody")
        .displayTitle() == "Real Heading")
    #expect(ClipDraft(title: "Untitled", properties: [], body: "No heading here.")
        .displayTitle(url: "https://www.example.com/path") == "example.com")
    #expect(ClipDraft(title: "untitled", properties: [], body: "First meaningful line\n\nMore")
        .displayTitle() == "First meaningful line")
    #expect(ClipDraft(title: "", properties: [], body: "   \n")
        .displayTitle() == "Clip")
    var kept = ClipDraft(title: "Ship it", properties: [], body: "# Ignored heading")
    kept.resolvePlaceholderTitle()
    #expect(kept.title == "Ship it")
    var empty = ClipDraft(title: "Untitled", properties: [], body: "# From body")
    empty.resolvePlaceholderTitle()
    #expect(empty.title == "From body")
}

// R13/R14: names and folders are cleaned against the vault root.
@Test func namesAndFoldersAreSafe() {
    for title in ["../../Desktop/evil", "..", "a\u{0}b:c/d", String(repeating: "🦘", count: 120), "", " .hidden", "\u{202E}txt.md"] {
        let name = ClipsVault.safeName(title)
        #expect(!name.isEmpty && !name.hasPrefix(".") && !name.hasPrefix(" "), "\(title)")
        #expect(!name.contains("/") && !name.contains(":") && !name.contains("\u{0}"), "\(title)")
        #expect(name.utf8.count <= 150, "\(title)")
    }
    #expect(ClipsVault.safeFolder("") == "Clips")
    #expect(ClipsVault.safeFolder("/") == "Clips")
    #expect(ClipsVault.safeFolder("../../etc") == "etc")
    #expect(ClipsVault.safeFolder("/Users/x/../Work/./Reading") == "Users/x/Work/Reading")
    #expect(ClipsVault.safeFolder("a/b/c/d/e/f") == "a/b/c/d")
    #expect(ClipsVault.safeFolder("Work\\Notes") == "Work/Notes")
    #expect(ClipsVault.safeFolder(".git/hooks") == "git/hooks")
}

@Test func savingNeverOverwritesAndStaysPrivate() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let planned = ClipsVault.planned(title: "Ship: it", folder: "Work/Reading", in: root)
    let first = try ClipsVault.save("one", title: "Ship: it", folder: "Work/Reading", in: root)
    #expect(ClipsVault.relative(first, in: root) == ClipsVault.relative(planned, in: root))
    #expect(ClipsVault.relative(first, in: root) == "Work/Reading/Ship it.md")
    let second = try ClipsVault.save("two", title: "Ship: it", folder: "Work/Reading", in: root)
    let third = try ClipsVault.save("three", title: "Ship: it", folder: "Work/Reading", in: root)
    #expect(first.lastPathComponent == "Ship it.md")
    #expect(second.lastPathComponent == "Ship it 2.md" && third.lastPathComponent == "Ship it 3.md")
    #expect(try String(contentsOf: first, encoding: .utf8) == "one")
    #expect(try String(contentsOf: third, encoding: .utf8) == "three")
    #expect(ClipsVault.planned(title: "Ship: it", folder: "Work/Reading", in: root).lastPathComponent == "Ship it 4.md")
    #expect(ClipsVault.relative(second, in: root) == "Work/Reading/Ship it 2.md")
    #expect(ClipsVault.folder(of: second, in: root) == "Work/Reading")
    #expect(try mode(first) == 0o600)
    for dir in [root, root.appendingPathComponent("Work"), root.appendingPathComponent("Work/Reading")] {
        #expect(try mode(dir) == 0o700, "\(dir.path)")
    }
    // A typed path can't climb out, and the default folder is used when none is given.
    let escaped = try ClipsVault.save("x", title: "../../escape", folder: "../../..", in: root)
    #expect(ClipsVault.parts(of: escaped, in: root) != nil)
    #expect(try ClipsVault.save("x", title: "Untitled", folder: "", in: root).deletingLastPathComponent().lastPathComponent == "Clips")
    #expect(ClipsVault.folders(in: root) == ["Clips", "Work"])
}

@Test func savingRefusesLinksAndFilesInThePath() throws {
    let manager = FileManager.default
    let root = tempRoot(), outside = tempRoot()
    defer { try? manager.removeItem(at: root); try? manager.removeItem(at: outside) }
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    try manager.createDirectory(at: outside, withIntermediateDirectories: true)
    try manager.createSymbolicLink(at: root.appendingPathComponent("Out"), withDestinationURL: outside)
    #expect(throws: ClipsVault.SaveError.outsideVault) { try ClipsVault.save("x", title: "t", folder: "Out", in: root) }
    #expect(try manager.contentsOfDirectory(atPath: outside.path).isEmpty)
    try "file".write(to: root.appendingPathComponent("Notes"), atomically: true, encoding: .utf8)
    #expect(throws: ClipsVault.SaveError.notAFolder("Notes")) { try ClipsVault.save("x", title: "t", folder: "Notes/Inner", in: root) }
    // A link where the note would go is never written through.
    try manager.createDirectory(at: root.appendingPathComponent("Clips"), withIntermediateDirectories: true)
    try manager.createSymbolicLink(at: root.appendingPathComponent("Clips/t.md"), withDestinationURL: outside.appendingPathComponent("t.md"))
    let file = try ClipsVault.save("x", title: "t", folder: "Clips", in: root)
    #expect(file.lastPathComponent == "t 2.md")
    #expect(!manager.fileExists(atPath: outside.appendingPathComponent("t.md").path))
    #expect(ClipsVault.SaveError(errno: ENOSPC) == .noSpace && ClipsVault.SaveError(errno: EACCES) == .noPermission)
}

@Test func savedNotesListFoldersNotLooseDrafts() throws {
    let manager = FileManager.default
    let root = tempRoot()
    defer { try? manager.removeItem(at: root) }
    try manager.createDirectory(at: root.appendingPathComponent("Saved"), withIntermediateDirectories: true)
    try "loose".write(to: root.appendingPathComponent("loose.md"), atomically: true, encoding: .utf8)
    try "kept".write(to: root.appendingPathComponent("Saved/Kept note.md"), atomically: true, encoding: .utf8)
    try "x".write(to: root.appendingPathComponent("Saved/readme.txt"), atomically: true, encoding: .utf8)
    let notes = ClipsVault.savedNotes(in: root)
    #expect(notes.map(\.title) == ["Kept note"])
    #expect(notes.first?.bytes == 4)
}

// Review round 1 (P2): a list item holding a comma stays one item from the page, through the
// card's field and the stored draft, to the note and back.
@Test func listItemsKeepTheirBoundaries() throws {
    let markdown = """
    ---
    title: "Paper"
    author:
      - "Doe, Jane"
      - "Turing, Alan"
    tags: [one, two]
    ---
    Body
    """
    let draft = ClipDraft(note: WebClipper.Note(name: "Paper", markdown: markdown, title: "Paper"))
    let author = try #require(draft.properties.first { $0.name == "author" })
    #expect(author.kind == .list && author.items == ["Doe, Jane", "Turing, Alan"])
    #expect(draft.markdown.contains("author:\n  - \"Doe, Jane\"\n  - \"Turing, Alan\""))
    #expect(ClipDraft(note: WebClipper.Note(name: "x", markdown: draft.markdown, title: draft.title)) == draft)
    let stored = try JSONDecoder().decode(ClipDraft.self, from: JSONEncoder().encode(draft))
    #expect(stored == draft)
    // The card's one-line field shows and reads back the same items, quotes and all.
    for items in [["Doe, Jane", "Turing, Alan"], ["He said \"hi\"", "plain"], ["  spaced  ", "x,y,z"], []] {
        let field = ClipDraft.Property.text(items)
        #expect(ClipDraft.Property.items(from: field) == items, "\(field)")
    }
    #expect(author.text == "\"Doe, Jane\", \"Turing, Alan\"")
    #expect(ClipDraft.Property.items(from: "one, two ,, three") == ["one", "two", "three"])
    var edited = author; edited.set("\"Hopper, Grace\", Lovelace")
    #expect(edited.items == ["Hopper, Grace", "Lovelace"])
    // A draft kept before lists were items still opens, its old comma-separated value split once.
    let legacy = #"{"name":"tags","kind":"list","value":"a, b"}"#
    let old = try JSONDecoder().decode(ClipDraft.Property.self, from: Data(legacy.utf8))
    #expect(old.items == ["a", "b"] && old.value.isEmpty)
}

// Review round 1 (P1): the folder is held open from its checks to the write, so swapping it for
// a link in between can't send the note outside the vault.
@Test func aFolderSwappedForALinkMidSaveIsNotFollowed() throws {
    let manager = FileManager.default
    let root = tempRoot(), outside = tempRoot()
    defer { try? manager.removeItem(at: root); try? manager.removeItem(at: outside) }
    try manager.createDirectory(at: outside, withIntermediateDirectories: true)
    try manager.createDirectory(at: root.appendingPathComponent("Clips"), withIntermediateDirectories: true)
    let written = try ClipsVault.save("note", title: "t", folder: "Clips", in: root) {
        try? manager.moveItem(at: root.appendingPathComponent("Clips"), to: root.appendingPathComponent("Moved"))
        try? manager.createSymbolicLink(at: root.appendingPathComponent("Clips"), withDestinationURL: outside)
    }
    #expect(try manager.contentsOfDirectory(atPath: outside.path).isEmpty)
    #expect(try String(contentsOf: root.appendingPathComponent("Moved/t.md"), encoding: .utf8) == "note")
    // Review round 2 (P1): the path returned is the file that was written (now under Moved), not
    // Clips/t.md behind the link, and reading that path inside the vault gives the note.
    #expect(ClipsVault.relative(written, in: root) == "Moved/t.md")
    #expect(ClipsVault.readNote(written, in: root) == "note")
    #expect(SafeFolder.realPath(written) == SafeFolder.realPath(root.appendingPathComponent("Moved/t.md")))
    // With the link in place, a new save is refused before anything is written.
    #expect(throws: ClipsVault.SaveError.outsideVault) { try ClipsVault.save("x", title: "u", folder: "Clips", in: root) }
    #expect(try manager.contentsOfDirectory(atPath: outside.path).isEmpty)
}

// Review round 1 (P1): reading a note takes a plain file inside the vault, within a size limit.
@Test func notesAreReadOnlyAsPlainFilesInsideTheVault() throws {
    let manager = FileManager.default
    let root = tempRoot()
    defer { try? manager.removeItem(at: root) }
    let file = try ClipsVault.save("hello", title: "n", folder: "Work/Reading", in: root)
    #expect(ClipsVault.readNote(file, in: root) == "hello")
    #expect(ClipsVault.readNote(file, in: root, limit: 4) == nil)
    #expect(ClipsVault.parts(of: file, in: root) == ["Work", "Reading", "n.md"])
    #expect(ClipsVault.parts(of: URL(fileURLWithPath: "/etc/hosts"), in: root) == nil)
    try manager.removeItem(at: file)
    #expect(mkfifo(file.path, 0o600) == 0)
    #expect(ClipsVault.readNote(file, in: root) == nil)   // refused at once, never waits on the FIFO
}

// Review round 2 (P1): a folder moved out of the vault mid-save: the note it got is removed again
// and the save refused, so nothing is reported, or left, outside the vault.
@Test func aFolderMovedOutOfTheVaultMidSaveLeavesNothing() throws {
    let manager = FileManager.default
    let root = tempRoot(), outside = tempRoot()
    defer { try? manager.removeItem(at: root); try? manager.removeItem(at: outside) }
    try manager.createDirectory(at: outside, withIntermediateDirectories: true)
    try manager.createDirectory(at: root.appendingPathComponent("Clips"), withIntermediateDirectories: true)
    #expect(throws: ClipsVault.SaveError.outsideVault) {
        try ClipsVault.save("note", title: "t", folder: "Clips", in: root) {
            try? manager.moveItem(at: root.appendingPathComponent("Clips"), to: outside.appendingPathComponent("Clips"))
        }
    }
    #expect(try manager.contentsOfDirectory(atPath: outside.appendingPathComponent("Clips").path).isEmpty)
}

// agy P3 (round 2): a file the save can't stand behind (not read back, or not where it should be)
// is removed, so trying again gets the same name rather than leaving an orphan and making " 2".
@Test func aFileTheSaveRefusesIsRemovedAgain() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try SafeFolder.open(root, followLink: false, create: true, mode: 0o700)
    #expect(throws: SafeFolder.Problem.rejected) { try folder.create("n.md", data: Data("x".utf8)) { _ in false } }
    #expect(folder.missing("n.md"))
    let path = try folder.create("n.md", data: Data("x".utf8))
    #expect(path.lastPathComponent == "n.md" && folder.read("n.md", limit: 10) == Data("x".utf8))
    #expect(throws: SafeFolder.Problem.exists) { try folder.create("n.md", data: Data("y".utf8)) }
    // Replacing swaps the whole file in one step and leaves no temporary file behind.
    try folder.replace("n.md", data: Data("z".utf8))
    #expect(folder.read("n.md", limit: 10) == Data("z".utf8))
    #expect(folder.entries().map(\.name) == ["n.md"])
    #expect(throws: SafeFolder.Problem.self) { try folder.create("../escape.md", data: Data()) }
    // A link at the root is refused when links aren't allowed there.
    let link = tempRoot()
    defer { try? FileManager.default.removeItem(at: link) }
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
    #expect(throws: SafeFolder.Problem.link) { try SafeFolder.open(link, followLink: false, create: true) }
}

// Review round 2 (P2): an inline YAML list keeps a quoted item whole, commas and quotes and all,
// and the note written back reads the same.
@Test func flowListsKeepQuotedCommas() throws {
    let markdown = """
    ---
    title: "Paper"
    author: ["Doe, Jane", x]
    tags: ['it''s, ok', "a \\"b, c\\"", plain, don't]
    aliases: []
    ---
    Body
    """
    let fields = Frontmatter.parse(markdown).fields
    #expect(fields.first { $0.key == "author" }?.values == ["Doe, Jane", "x"])
    #expect(fields.first { $0.key == "tags" }?.values == ["it's, ok", "a \"b, c\"", "plain", "don't"])
    #expect(fields.first { $0.key == "aliases" }.map { $0.values.isEmpty && $0.isList } == true)
    let draft = ClipDraft(note: WebClipper.Note(name: "Paper", markdown: markdown, title: "Paper"))
    #expect(draft.properties.first { $0.name == "author" }?.items == ["Doe, Jane", "x"])
    #expect(ClipDraft(note: WebClipper.Note(name: "x", markdown: draft.markdown, title: draft.title)) == draft)
    #expect(Frontmatter.flowItems(#" "a,b" , 'c' ,, d "#) == ["a,b", "c", "d"])
}

// Review round 2 (P2): the old Clips page's loose clips still within their 48 hours are found
// (with their text) for the main clipboard; older ones, hidden files and saved notes are not.
@Test func recentLooseClipsAreFoundForImport() throws {
    let manager = FileManager.default
    let root = tempRoot()
    defer { try? manager.removeItem(at: root) }
    try manager.createDirectory(at: root.appendingPathComponent("Clips"), withIntermediateDirectories: true)
    for (name, text) in [("fresh.md", "fresh words"), ("old.md", "old"), (".hidden.md", "h"), ("Clips/kept.md", "kept")] {
        try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    try manager.setAttributes([.modificationDate: Date().addingTimeInterval(-ClipsVault.lifetime - 60)],
                              ofItemAtPath: root.appendingPathComponent("old.md").path)
    try manager.createDirectory(at: root.appendingPathComponent("folder.md"), withIntermediateDirectories: true)
    let notes = ClipsVault.looseNotes(in: root)
    #expect(notes.map(\.title) == ["fresh"] && notes.first?.markdown == "fresh words")
}

// PR #9 review r5: undecodable notes still count against the startup import's read budget.
@Test func undecodableLooseNotesStillUseTheReadBudget() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let junk = Data(repeating: 0xFF, count: 4096)   // never valid UTF-8
    for index in 0..<5 { try junk.write(to: root.appendingPathComponent("bad \(index).md")) }
    try Data("# fine\n".utf8).write(to: root.appendingPathComponent("good.md"))
    // A budget of three bad files' bytes: the reads stop before every file is read.
    let notes = ClipsVault.looseNotes(in: root, budget: 3 * 4096)
    #expect(notes.allSatisfy { $0.name == "good.md" })
}
