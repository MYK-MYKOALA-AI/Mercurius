import AppKit

// Google Docs, Slides and Sheets draw their content on a canvas, so Accessibility sees mostly menus
// and toolbars (84 words measured on the Air) unless Docs' screen-reader mode is on. fn+W and fn+T
// therefore ask Docs for the file itself: its own export address, opened in the browser the page is
// in, so the download uses that browser's Google sign-in and CursusVox never holds a Google
// credential. The browser saves the file to Downloads; CursusVox reads it once and moves it to the Trash.
// When the export doesn't arrive, the capture falls back to what Accessibility read, with the hint.
enum GoogleDocs {
    static let hint = "Google Docs may have hidden the document text. Turn on Tools › Accessibility › Screen reader support (⌘⌥Z) once, then press again."
    // Menus and toolbars alone measured 84 words; under this, the document's own words are likely missing.
    static let menuWords = 150

    static func isDocument(_ address: String?) -> Bool {
        guard let address, let url = URL(string: address), url.host?.lowercased() == "docs.google.com" else { return false }
        return ["/document/", "/presentation/", "/spreadsheets/"].contains { url.path.hasPrefix($0) }
    }
    // The export was read but couldn't go to the Trash: the document's text is still in Downloads.
    // A long name is shortened in the middle, so the pill's three lines still show every other warning.
    static func leftBehind(_ name: String) -> String { "\"\(shortName(name))\" is still in Downloads" }
    static func shortName(_ name: String, limit: Int = 40) -> String {
        guard name.count > limit else { return name }
        let ext = (name as NSString).pathExtension
        let tail = ext.isEmpty || ext.count > 8 ? String(name.suffix(8)) : "." + ext
        return String(name.prefix(limit - tail.count - 1)) + "…" + tail
    }
    static func hidesText(url: String?, words: Int) -> Bool { isDocument(url) && words < menuWords }
    // What the clip card shows above a thin Docs clip (the draft still loads); nil otherwise.
    static func notice(url: String?, words: Int) -> String? { hidesText(url: url, words: words) ? hint : nil }

    // MARK: export

    struct Export: Equatable {
        let url: URL
        let id: String              // the file's id: what a download must have come from
        let fileExtension: String   // what the browser saves it as
        let isTable: Bool           // Sheets: comma-separated values
        var gid: String? = nil      // Sheets: the sheet asked for
    }

    // Docs' export address for the file a page shows, in the same signed-in account (/u/N/):
    // a document as Markdown, the open sheet as CSV, a presentation as plain text. nil for
    // anything else, including published copies (/d/e/…), which are ordinary web pages.
    static func export(for address: String?) -> Export? {
        guard let address, let page = URLComponents(string: address), page.scheme?.lowercased() == "https",
              page.host?.lowercased() == "docs.google.com", page.port == nil, page.user == nil else { return nil }
        let parts = page.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let kind = parts.first else { return nil }
        var at = 1
        var account = ""
        if parts.count > 2, parts[1] == "u", (1...2).contains(parts[2].count), parts[2].allSatisfy(\.isASCII), parts[2].allSatisfy(\.isNumber) {
            account = "u/\(parts[2])/"
            at = 3
        }
        guard parts.count > at + 1, parts[at] == "d" else { return nil }
        let id = parts[at + 1]
        guard id != "e", (20...200).contains(id.count),
              id.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") })
        else { return nil }
        let base = "https://docs.google.com/\(kind)/\(account)d/\(id)/"
        // Some links name the signed-in account as ?authuser=N (or an address) instead of /u/N/.
        let authuser = page.percentEncodedQueryItems?.first { $0.name == "authuser" }?.value.flatMap { value -> String? in
            guard (1...254).contains(value.count) else { return nil }
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_%@")
            return value.unicodeScalars.allSatisfy(allowed.contains) && !value.contains("%26") && !value.contains("%23") ? value : nil
        }
        let account2 = authuser.map { "&authuser=\($0)" } ?? ""
        func made(_ address: String, _ ext: String, table: Bool = false) -> Export? {
            URL(string: address).map { Export(url: $0, id: id, fileExtension: ext, isTable: table) }
        }
        switch kind {
        case "document":
            return made(base + "export?format=md" + account2, "md")
        case "presentation":
            return made(base + "export/txt" + (authuser.map { "?authuser=\($0)" } ?? ""), "txt")
        case "spreadsheets":
            // The open sheet is named by gid in the fragment (#gid=N) or the query (?gid=N), read still
            // percent-encoded so an encoded "&" can't smuggle anything past the digits check.
            let fromQuery = page.percentEncodedQueryItems?.first { $0.name == "gid" }?.value
            let fromFragment = page.percentEncodedFragment?.split(separator: "&").first { $0.hasPrefix("gid=") }.map { String($0.dropFirst(4)) }
            let gid = [fromFragment, fromQuery].compactMap { $0 }.first { !$0.isEmpty && $0.count <= 12 && $0.allSatisfy { $0.isASCII && $0.isNumber } }
            return made(base + "export?format=csv" + (gid.map { "&gid=\($0)" } ?? "") + account2, "csv", table: true)
                .map { Export(url: $0.url, id: id, fileExtension: "csv", isTable: true, gid: gid) }
        default:
            return nil
        }
    }

    // The exported file as a note body: pictures (Docs puts each one inline as base64, often
    // megabytes) are dropped, and a sheet goes in a csv code block.
    static func body(_ text: String, isTable: Bool) -> String {
        if isTable {
            let fence = text.contains("```") ? "~~~~" : "```"
            return fence + "csv\n" + text.trimmingCharacters(in: .newlines) + "\n" + fence
        }
        var kept: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // A picture's data: `[image1]: <data:image/png;base64,…>`.
            if line.hasPrefix("[image"), line.contains("]: <data:") { continue }
            kept.append(line)
        }
        // Where each picture was: `![][image1]`.
        let joined = kept.joined(separator: "\n")
            .replacingOccurrences(of: #"!\[[^\]\n]*\]\[image\d+\]"#, with: "", options: .regularExpression)
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // The document's name as its export was saved ("Resume (1).md" → "Resume").
    static func title(fromFile name: String) -> String {
        var stem = (name as NSString).deletingPathExtension
        if let copy = stem.range(of: #" \(\d{1,3}\)$"#, options: .regularExpression) { stem.removeSubrange(copy) }
        return stem.trimmingCharacters(in: .whitespaces)
    }
}

// Fetching an export through the browser: the export address opens in `browser` (in the
// background) and the file it saves into Downloads is taken. A file counts as the export only when
// the browser stamped it as downloaded from this document: macOS keeps the address a download came
// from (kMDItemWhereFroms), and Docs serves an export from docs.google.com or a googleusercontent.com
// address with the file's id as a path part. Names, sizes and timing never decide ownership, so a
// download of your own in the same seconds is left alone, whatever it's called. The file is opened
// once, judged, read and moved to the Trash through that one open (SafeFolder.take): never deleted
// outright, so even a same-document download of your own in the same seconds stays recoverable.
enum DocsExport {
    struct File: Equatable {
        let name: String
        let text: String
        let left: String?   // nil: moved to the Trash; else the name it is still under in Downloads
    }
    static let byteLimit = 32 << 20     // Docs inlines pictures, so a short document can still be large
    static let poll: Duration = .milliseconds(300)
    static let whereFroms = "com.apple.metadata:kMDItemWhereFroms"

    static func fetch(_ export: GoogleDocs.Export, browser: String,
                      downloads: URL? = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
                      timeout: Duration = .seconds(15),
                      trash: @escaping @Sendable (URL) -> Bool = SafeFolder.trash,
                      open: @escaping @Sendable (URL, String) async -> Bool = DocsExport.openInBrowser) async -> File? {
        // Listing Downloads the first time may wait on macOS asking for access; the clock starts after.
        guard let downloads, let folder = await Task.detached(operation: { try? SafeFolder.open(downloads, followLink: true, create: false) }).value
        else { return nil }
        let before = await Task.detached { folder.names() }.value
        guard await open(export.url, browser) else { return nil }
        let ext = export.fileExtension
        var refused = Set<String>()
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            try? await Task.sleep(for: poll)
            if Task.isCancelled { return nil }
            let skip = refused
            let (found, newlyRefused) = await Task.detached { () -> (File?, Set<String>) in
                let names = folder.names()
                var no = Set<String>()
                // A browser still writing keeps a partial file beside it (Firefox: name.part).
                for name in names.subtracting(before).subtracting(skip).sorted()
                where !name.hasPrefix(".") && (name as NSString).pathExtension.lowercased() == ext && !names.contains(name + ".part") {
                    switch folder.take(name, limit: byteLimit, trash: trash, owns: { Self.owns(file: $0, export: export) }) {
                    case .notYet: continue
                    case .refused: no.insert(name)
                    case let .taken(data, left): return (File(name: name, text: String(decoding: data, as: UTF8.self), left: left), no)
                    }
                }
                return (nil, no)
            }.value
            if let found { return found }
            refused.formUnion(newlyRefused)
        }
        return nil
    }

    // The open file's download stamp names this export; nil while the browser hasn't stamped it yet.
    static func owns(file: Int32, export: GoogleDocs.Export) -> Bool? {
        let size = fgetxattr(file, whereFroms, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        guard size <= 64 * 1024 else { return false }
        var bytes = [UInt8](repeating: 0, count: size)
        guard fgetxattr(file, whereFroms, &bytes, size, 0, 0) == size,
              let list = try? PropertyListSerialization.propertyList(from: Data(bytes), format: nil) as? [String]
        else { return false }
        return owns(whereFroms: list, export: export)
    }
    // Only the first address is where the file came from (Safari adds the page it was on after it).
    // It must name this document, and where it says which format or sheet it is (Docs' export
    // addresses carry format= and, for a sheet, gid=), that must be the one asked for: a sheet of
    // the same spreadsheet downloaded by hand meanwhile is not taken for this one.
    static func owns(whereFroms list: [String], export: GoogleDocs.Export) -> Bool {
        guard let first = list.first, let source = URLComponents(string: first), source.scheme?.lowercased() == "https",
              let host = source.host?.lowercased(), host == "docs.google.com" || host.hasSuffix(".googleusercontent.com"),
              source.percentEncodedPath.split(separator: "/").contains(where: { $0 == export.id })
        else { return false }
        let items = source.percentEncodedQueryItems ?? []
        let formats = items.filter { $0.name == "format" }.map { $0.value ?? "" }
        if !formats.isEmpty, formats != [export.fileExtension] { return false }
        let gids = items.filter { $0.name == "gid" }.map { $0.value ?? "" }
        // With no sheet named on the page the export is whichever sheet comes first, whatever its gid.
        if let want = export.gid, !gids.isEmpty, gids != [want] { return false }
        return true
    }

    @Sendable static func openInBrowser(_ url: URL, _ bundle: String) async -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        return (try? await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)) != nil
    }
}
