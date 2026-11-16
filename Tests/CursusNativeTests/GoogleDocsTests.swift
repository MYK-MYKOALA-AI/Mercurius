import AppKit
import Foundation
import Testing
@testable import CursusVox

// Synthetic metadata only: never use a live shareable document identifier in fixtures.
private let id = "synthetic-document-0000000000000001"

@Suite struct GoogleDocsExportTests {
    @Test func documentExportsAsMarkdownInTheSameAccount() {
        #expect(GoogleDocs.export(for: "https://docs.google.com/document/d/\(id)/edit?tab=t.0")
                == GoogleDocs.Export(url: URL(string: "https://docs.google.com/document/d/\(id)/export?format=md")!, id: id, fileExtension: "md", isTable: false))
        #expect(GoogleDocs.export(for: "https://docs.google.com/spreadsheets/d/\(id)/edit#gid=5")?.gid == "5")
        #expect(GoogleDocs.export(for: "https://docs.google.com/document/u/1/d/\(id)/edit")?.url.absoluteString
                == "https://docs.google.com/document/u/1/d/\(id)/export?format=md")
    }
    @Test func sheetExportsTheOpenSheetAsCSV() {
        #expect(GoogleDocs.export(for: "https://docs.google.com/spreadsheets/d/\(id)/edit#gid=123456")?.url.absoluteString
                == "https://docs.google.com/spreadsheets/d/\(id)/export?format=csv&gid=123456")
        #expect(GoogleDocs.export(for: "https://docs.google.com/spreadsheets/d/\(id)/edit?gid=7")?.url.absoluteString
                == "https://docs.google.com/spreadsheets/d/\(id)/export?format=csv&gid=7")
        // A gid that isn't a number is dropped, never passed on.
        #expect(GoogleDocs.export(for: "https://docs.google.com/spreadsheets/d/\(id)/edit#gid=1&x=y%26z")?.url.absoluteString
                == "https://docs.google.com/spreadsheets/d/\(id)/export?format=csv&gid=1")
        #expect(GoogleDocs.export(for: "https://docs.google.com/spreadsheets/d/\(id)/edit#gid=1%26evil")?.url.absoluteString
                == "https://docs.google.com/spreadsheets/d/\(id)/export?format=csv")
        #expect(GoogleDocs.export(for: "https://docs.google.com/spreadsheets/d/\(id)/edit")?.isTable == true)
    }
    @Test func accountNamedInTheQueryCarriesOver() {
        #expect(GoogleDocs.export(for: "https://docs.google.com/document/d/\(id)/edit?authuser=2")?.url.absoluteString
                == "https://docs.google.com/document/d/\(id)/export?format=md&authuser=2")
        #expect(GoogleDocs.export(for: "https://docs.google.com/document/d/\(id)/edit?authuser=sam%40example.com")?.url.absoluteString
                == "https://docs.google.com/document/d/\(id)/export?format=md&authuser=sam%40example.com")
        #expect(GoogleDocs.export(for: "https://docs.google.com/presentation/d/\(id)/edit?authuser=1")?.url.absoluteString
                == "https://docs.google.com/presentation/d/\(id)/export/txt?authuser=1")
        // Anything that could add a parameter or fragment is dropped.
        #expect(GoogleDocs.export(for: "https://docs.google.com/document/d/\(id)/edit?authuser=1%26format=pdf")?.url.absoluteString
                == "https://docs.google.com/document/d/\(id)/export?format=md")
    }
    @Test func presentationExportsAsText() {
        #expect(GoogleDocs.export(for: "https://docs.google.com/presentation/d/\(id)/edit#slide=id.p")?.url.absoluteString
                == "https://docs.google.com/presentation/d/\(id)/export/txt")
    }
    @Test func anythingElseHasNoExport() {
        for address in [
            "http://docs.google.com/document/d/\(id)/edit",            // not https
            "https://docs.google.com.evil.example/document/d/\(id)/edit",
            "https://user@docs.google.com/document/d/\(id)/edit",
            "https://docs.google.com:8443/document/d/\(id)/edit",
            "https://docs.google.com/document/d/e/2PACX-\(id)/pub",     // published copy: a normal page
            "https://docs.google.com/document/d/short/edit",
            "https://docs.google.com/document/d/\(id)%2F..%2Fx/edit",
            "https://docs.google.com/forms/d/\(id)/edit",
            "https://docs.google.com/document/u/abc/d/\(id)/edit",
            "https://drive.google.com/file/d/\(id)/view",
            "not a url",
        ] { #expect(GoogleDocs.export(for: address) == nil, "\(address)") }
        #expect(GoogleDocs.export(for: nil) == nil)
    }

    @Test func picturesAreDroppedFromTheBody() {
        let exported = "# Resume\n\n![][image1]Lee Example\n\nSkills\n\n[image1]: <data:image/png;base64,iVBORw0KGgo=>\n"
        #expect(GoogleDocs.body(exported, isTable: false) == "# Resume\n\nLee Example\n\nSkills")
    }
    @Test func sheetGoesInACodeBlock() {
        #expect(GoogleDocs.body("a,b\n1,2\n", isTable: true) == "```csv\na,b\n1,2\n```")
        #expect(GoogleDocs.body("x,\"```\"\n", isTable: true) == "~~~~csv\nx,\"```\"\n~~~~")
    }
    @Test func titlesComeFromTheFile() {
        #expect(GoogleDocs.title(fromFile: "Resume (1).md") == "Resume")
        #expect(GoogleDocs.title(fromFile: "Q3 plan.csv") == "Q3 plan")
    }
}

// The browser is replaced by a closure that "downloads" into a temporary folder and stamps the
// file with where it came from, as browsers do.
private func stamp(_ url: URL, from source: String) {
    let data = try! PropertyListSerialization.data(fromPropertyList: [source], format: .binary, options: 0)
    _ = data.withUnsafeBytes { setxattr(url.path, DocsExport.whereFroms, $0.baseAddress, data.count, 0, 0) }
}
// Stand-in for the Trash in tests: the file just goes, so the Mini's real Trash isn't filled.
private let binned: @Sendable (URL) -> Bool = { (try? FileManager.default.removeItem(at: $0)) != nil }
private let served = "https://doc-0o-6g-docstext.googleusercontent.com/export/abc/def/1791896275000/1/2/\(id)?format=md&dat=x"

@Suite struct DocsExportFetchTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("docs-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private let export = GoogleDocs.export(for: "https://docs.google.com/document/d/\(id)/edit")!

    @Test func onlyThisDocumentsDownloadIsTaken() {
        #expect(DocsExport.owns(whereFroms: [served], export: export))
        #expect(DocsExport.owns(whereFroms: ["https://docs.google.com/document/d/\(id)/export?format=md"], export: export))
        #expect(!DocsExport.owns(whereFroms: [served.replacingOccurrences(of: id, with: "OTHER\(id.dropFirst(5))")], export: export))
        #expect(!DocsExport.owns(whereFroms: ["https://evil.example/\(id)"], export: export))
        #expect(!DocsExport.owns(whereFroms: ["https://googleusercontent.com.evil.example/\(id)"], export: export))
        #expect(!DocsExport.owns(whereFroms: ["http://docs.google.com/document/d/\(id)/export"], export: export))
        #expect(!DocsExport.owns(whereFroms: ["https://docs.google.com/x?id=\(id)"], export: export))   // query, not a path part
        // Safari puts the page the download started on second: that alone proves nothing.
        #expect(!DocsExport.owns(whereFroms: ["https://evil.example/file.md", "https://docs.google.com/document/d/\(id)/edit"], export: export))
        #expect(!DocsExport.owns(whereFroms: [], export: export))
        // The format and sheet asked for, where the stamp says them.
        #expect(!DocsExport.owns(whereFroms: [served.replacingOccurrences(of: "format=md", with: "format=pdf")], export: export))
        let sheet = GoogleDocs.export(for: "https://docs.google.com/spreadsheets/d/\(id)/edit#gid=9")!
        let sheetServed = "https://doc-0s-sheets.googleusercontent.com/export/a/b/1/2/3/\(id)?format=csv&gid="
        #expect(DocsExport.owns(whereFroms: [sheetServed + "9"], export: sheet))
        #expect(!DocsExport.owns(whereFroms: [sheetServed + "7"], export: sheet))
        let firstSheet = GoogleDocs.export(for: "https://docs.google.com/spreadsheets/d/\(id)/edit")!
        #expect(DocsExport.owns(whereFroms: [sheetServed + "0"], export: firstSheet))
        #expect(DocsExport.owns(whereFroms: [sheetServed + "12345"], export: firstSheet))
    }

    @Test func finishedDownloadIsReadOnceAndDeleted() async throws {
        let downloads = try folder()
        defer { try? FileManager.default.removeItem(at: downloads) }
        let mine = downloads.appendingPathComponent("Resume.md")      // already there: never touched
        try Data("old".utf8).write(to: mine)
        let file = await DocsExport.fetch(export, browser: "test", downloads: downloads, timeout: .seconds(5), trash: binned) { url, _ in
            #expect(url == self.export.url)
            Task.detached {
                // In progress first, as Chromium does, then the finished name, then the stamp.
                let partial = downloads.appendingPathComponent("Resume (1).md.crdownload")
                try? Data("# Resume\n\nHello".utf8).write(to: partial)
                try? await Task.sleep(for: .milliseconds(400))
                let done = downloads.appendingPathComponent("Resume (1).md")
                try? FileManager.default.moveItem(at: partial, to: done)
                try? await Task.sleep(for: .milliseconds(400))
                stamp(done, from: served)
            }
            return true
        }
        #expect(file == DocsExport.File(name: "Resume (1).md", text: "# Resume\n\nHello", left: nil))
        #expect(!FileManager.default.fileExists(atPath: downloads.appendingPathComponent("Resume (1).md").path))
        #expect(try String(contentsOf: mine, encoding: .utf8) == "old")
    }
    @Test func anotherDownloadIsLeftAloneWhateverItsName() async throws {
        let downloads = try folder()
        defer { try? FileManager.default.removeItem(at: downloads) }
        let unstamped = downloads.appendingPathComponent("Resume private.md")
        let elsewhere = downloads.appendingPathComponent("Resume.md")
        let file = await DocsExport.fetch(export, browser: "test", downloads: downloads, timeout: .seconds(1), trash: binned) { _, _ in
            try? Data("not ours".utf8).write(to: unstamped)
            try? Data("not ours either".utf8).write(to: elsewhere)
            stamp(elsewhere, from: "https://bank.example/statement.md")
            return true
        }
        #expect(file == nil)
        #expect(try String(contentsOf: unstamped, encoding: .utf8) == "not ours")
        #expect(try String(contentsOf: elsewhere, encoding: .utf8) == "not ours either")
    }
    @Test func aLinkIsNeverFollowed() async throws {
        let downloads = try folder()
        let outside = try folder()
        defer { try? FileManager.default.removeItem(at: downloads); try? FileManager.default.removeItem(at: outside) }
        let target = outside.appendingPathComponent("secret.md")
        try Data("secret".utf8).write(to: target)
        stamp(target, from: served)
        let file = await DocsExport.fetch(export, browser: "test", downloads: downloads, timeout: .seconds(1), trash: binned) { _, _ in
            try? FileManager.default.createSymbolicLink(at: downloads.appendingPathComponent("Resume.md"), withDestinationURL: target)
            return true
        }
        #expect(file == nil)
        #expect(try String(contentsOf: target, encoding: .utf8) == "secret")
    }
    @Test func aFirefoxDownloadIsTakenOnlyOnceItsPartFileIsGone() async throws {
        let downloads = try folder()
        defer { try? FileManager.default.removeItem(at: downloads) }
        let final = downloads.appendingPathComponent("Resume.md"), part = downloads.appendingPathComponent("Resume.md.part")
        let file = await DocsExport.fetch(export, browser: "test", downloads: downloads, timeout: .seconds(5), trash: binned) { _, _ in
            try? Data("# Res".utf8).write(to: final)
            stamp(final, from: served)
            try? Data().write(to: part)
            Task.detached {
                try? await Task.sleep(for: .milliseconds(900))
                try? Data("# Resume, all of it".utf8).write(to: final)
                stamp(final, from: served)
                try? FileManager.default.removeItem(at: part)
            }
            return true
        }
        #expect(file?.text == "# Resume, all of it")
    }
    @Test func browserThatWontOpenGivesUpAtOnce() async throws {
        let downloads = try folder()
        defer { try? FileManager.default.removeItem(at: downloads) }
        let started = Date()
        let file = await DocsExport.fetch(export, browser: "test", downloads: downloads, timeout: .seconds(5), trash: binned) { _, _ in false }
        #expect(file == nil)
        #expect(Date().timeIntervalSince(started) < 1)
    }
    @Test func nothingArrivingTimesOut() async throws {
        let downloads = try folder()
        defer { try? FileManager.default.removeItem(at: downloads) }
        let file = await DocsExport.fetch(export, browser: "test", downloads: downloads, timeout: .milliseconds(700), trash: binned) { _, _ in true }
        #expect(file == nil)
    }
}

// SafeFolder.take: one open decides, reads and removes.
@Suite struct SafeFolderTakeTests {
    @Test func aFileSwappedInAfterTheOpenIsNeverRemoved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("take-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = dir.appendingPathComponent("doc.md"), other = dir.appendingPathComponent("other.md")
        try Data("export".utf8).write(to: name)
        try Data("yours".utf8).write(to: other)
        let folder = try SafeFolder.open(dir, followLink: false, create: false)
        let result = folder.take("doc.md", limit: 1 << 20, trash: binned) { _ in
            // Between the open and the removal, something else takes the name.
            _ = rename(other.path, name.path)
            return true
        }
        #expect(result == .taken(Data("export".utf8), left: "doc.md"))
        #expect(try String(contentsOf: name, encoding: .utf8) == "yours")
    }
    @Test func aFileTheTrashRefusesIsPutBackUnderItsName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("take-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("export".utf8).write(to: dir.appendingPathComponent("doc.md"))
        let folder = try SafeFolder.open(dir, followLink: false, create: false)
        #expect(folder.take("doc.md", limit: 1 << 20, trash: { _ in false }) { _ in true } == .taken(Data("export".utf8), left: "doc.md"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["doc.md"])
    }
    @Test func onlyTheTakenFileGoesToTheTrash() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("take-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("export".utf8).write(to: dir.appendingPathComponent("doc.md"))
        let folder = try SafeFolder.open(dir, followLink: false, create: false)
        var binnedNames: [String] = []
        let result = folder.take("doc.md", limit: 1 << 20, trash: { url in
            binnedNames.append(url.lastPathComponent)
            return (try? FileManager.default.removeItem(at: url)) != nil
        }) { _ in true }
        #expect(result == .taken(Data("export".utf8), left: nil))
        #expect(binnedNames.count == 1 && binnedNames[0].hasPrefix(".cursusvox-taking-"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
    @Test func notOursOrTooBigIsRefusedAndUnstampedWaits() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("take-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("abc".utf8).write(to: dir.appendingPathComponent("a.md"))
        let folder = try SafeFolder.open(dir, followLink: false, create: false)
        #expect(folder.take("a.md", limit: 10, trash: binned) { _ in false } == .refused)
        #expect(folder.take("a.md", limit: 10) { _ in nil } == .notYet)
        #expect(folder.take("a.md", limit: 2) { _ in true } == .refused)
        #expect(folder.take("missing.md", limit: 10) { _ in true } == .notYet)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.md").path))
    }
}

// What the pill says after fn+T: no warning hides another.
@Suite @MainActor struct CaptureStatusTests {
    @Test func plainCopyIsDone() {
        #expect(Application.captureStatus(words: 50, from: "Comet", copied: true, copyProblem: nil, kept: "a b", whole: "a b",
                                          thin: false, leftBehind: nil) == .done("Copied 50 words from Comet"))
    }
    @Test func refusedCopyOfATruncatedCaptureSaysBoth() {
        let whole = String(repeating: "word ", count: 10), kept = String(repeating: "word ", count: 4)
        #expect(Application.captureStatus(words: 10, from: "Comet", copied: false, copyProblem: "a password field is active",
                                          kept: kept, whole: whole, thin: false, leftBehind: nil)
                == .failed("Not copied: a password field is active. Clipboard kept only the first 2 MB. Kept 4 words from Comet in Clipboard"))
    }
    @Test func everyWarningLeadsAndFitsThePill() {
        let whole = String(repeating: "word ", count: 10), kept = String(repeating: "word ", count: 4)
        guard case let .failed(message) = Application.captureStatus(words: 10, from: "Comet", copied: false,
                copyProblem: "a password field is active", kept: kept, whole: whole, thin: false,
                leftBehind: GoogleDocs.leftBehind("Quarterly planning notes (1).md")) else { Issue.record("expected a warning"); return }
        #expect(message.hasPrefix("\"Quarterly planning notes (1).md\" is still in Downloads. Not copied: a password field is active. Clipboard kept only the first 2 MB"))
        // What the pill shows: the warnings must all be inside its three lines.
        let shown = RecordingPill.firstLines(NSAttributedString(string: message, attributes: [.font: RecordingPill.textFont])).string
        #expect(shown.contains("Clipboard kept only the first 2 MB"), "\(shown)")
    }
    @Test func aLongFileNameStillLeavesRoomForEveryWarning() {
        let name = String(repeating: "Very long document title ", count: 9) + "(1).md"   // 230+ characters
        #expect(GoogleDocs.shortName(name).count == 40 && GoogleDocs.shortName(name).hasSuffix("….md"))
        let whole = String(repeating: "word ", count: 10), kept = String(repeating: "word ", count: 4)
        guard case let .failed(message) = Application.captureStatus(words: 10, from: "Comet", copied: false,
                copyProblem: "a password field is active", kept: kept, whole: whole, thin: false,
                leftBehind: GoogleDocs.leftBehind(name)) else { Issue.record("expected a warning"); return }
        let shown = RecordingPill.firstLines(NSAttributedString(string: message, attributes: [.font: RecordingPill.textFont])).string
        #expect(shown.contains("Clipboard kept only the first 2 MB"), "\(shown)")
        #expect(GoogleDocs.shortName("Resume.md") == "Resume.md")
    }
    @Test func exportLeftInDownloadsIsReportedEvenWhenTheCopyFails() {
        guard case let .failed(message) = Application.captureStatus(words: 5, from: "Comet", copied: false, copyProblem: "blocked",
                                                                     kept: "x", whole: "x", thin: false, leftBehind: GoogleDocs.leftBehind("Resume.md")) else {
            Issue.record("expected a warning"); return
        }
        #expect(message == "\"Resume.md\" is still in Downloads. Not copied: blocked. Kept 5 words from Comet in Clipboard")
    }
    @Test func keptWithoutCopyingIsDoneWhenWhole() {
        #expect(Application.captureStatus(words: 2, from: "Notes", copied: false, copyProblem: nil, kept: "a b", whole: "a b",
                                          thin: false, leftBehind: nil) == .done("Kept 2 words from Notes in Clipboard"))
    }
    @Test func youTubeTitleFromTheWindow() {
        #expect(YouTubeTranscript.title(fromWindow: "(193) Manchester City vs The World - YouTube - Audio playing - Comet")
                == "Manchester City vs The World")
        #expect(YouTubeTranscript.title(fromWindow: "Lecture 1 - YouTube") == "Lecture 1")
    }
}
