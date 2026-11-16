import Foundation

// One clip as the review card edits it: a title, typed properties and a Markdown body.
// The note's frontmatter is always rebuilt from these fields by `Frontmatter.render`, never
// copied from the page, so nothing in a page's title or description can break the YAML.
struct ClipDraft: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case text, date, datetime, list }
    struct Property: Codable, Equatable, Sendable {
        var name: String
        var kind: Kind
        var value: String     // a text, date or datetime value
        var items: [String]   // a list's items, each kept whole ("Doe, Jane" stays one author)
        init(name: String, kind: Kind, value: String = "", items: [String] = []) {
            self.name = name; self.kind = kind; self.value = value; self.items = items
        }
        private enum CodingKeys: String, CodingKey { case name, kind, value, items }
        // Drafts kept before lists were stored as items held them comma-separated in `value`.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            kind = try c.decode(Kind.self, forKey: .kind)
            value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
            if let items = try c.decodeIfPresent([String].self, forKey: .items) { self.items = items }
            else if kind == .list {
                items = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                value = ""
            } else { items = [] }
        }
        // What the card's one-line field shows: a list's items comma-separated, and an item that
        // holds a comma or a quote double-quoted (a quote inside doubled), so `items(from:)` gets
        // back exactly the same items.
        var text: String { kind == .list ? Self.text(items) : value }
        static func text(_ items: [String]) -> String {
            items.map { item in
                item.contains(",") || item.contains("\"") || item.trimmingCharacters(in: .whitespaces) != item
                    ? "\"" + item.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : item
            }.joined(separator: ", ")
        }
        static func items(from text: String) -> [String] {
            var items: [String] = [], current = ""
            var quoted = false, inQuotes = false
            let chars = Array(text)
            var index = 0
            func end() {
                let item = quoted ? current : current.trimmingCharacters(in: .whitespaces)
                if !item.isEmpty { items.append(item) }
                current = ""; quoted = false
            }
            while index < chars.count {
                let c = chars[index]; index += 1
                if inQuotes {
                    if c != "\"" { current.append(c) }
                    else if index < chars.count, chars[index] == "\"" { current.append("\""); index += 1 }
                    else { inQuotes = false }
                } else if c == "," {
                    end()
                } else if c == "\"", !quoted, current.allSatisfy({ $0 == " " }) {
                    inQuotes = true; quoted = true; current = ""
                } else if !(quoted && c == " ") {
                    current.append(c)
                }
            }
            end()
            return items
        }
        // Sets the property from what was typed in its field.
        mutating func set(_ typed: String) {
            if kind == .list { items = Self.items(from: typed) } else { value = typed }
        }
    }
    var title: String
    var properties: [Property]
    var body: String
    // The body's size before it was cut to the budget; nil when nothing was cut.
    var originalBytes: Int?

    // A note this size is still quick to preview and edit; a bigger page keeps its first part.
    static let budget = 512 * 1024

    init(title: String, properties: [Property], body: String, originalBytes: Int? = nil) {
        self.title = title; self.properties = properties; self.body = body; self.originalBytes = originalBytes
    }

    // From the clipper's note (or fn+W's Accessibility note): its frontmatter becomes properties.
    init(note: WebClipper.Note) {
        let parsed = Frontmatter.parse(note.markdown)
        var title = note.title
        var properties: [Property] = []
        for field in parsed.fields {
            if field.key == "title" {
                if title.trimmingCharacters(in: .whitespaces).isEmpty { title = field.values.joined(separator: " ") }
                continue
            }
            let kind = Self.kind(for: field.key, list: field.isList)
            properties.append(kind == .list ? Property(name: field.key, kind: kind, items: field.values)
                                            : Property(name: field.key, kind: kind, value: field.values.joined(separator: " ")))
        }
        let cut = Self.cut(parsed.body.trimmingCharacters(in: .newlines))
        self.init(title: Self.oneLine(title), properties: properties, body: cut.text, originalBytes: cut.original)
    }

    static func kind(for key: String, list: Bool) -> Kind {
        if list || ["tags", "aliases", "cssclasses"].contains(key) { return .list }
        switch key {
        case "published", "date": return .date
        case "clipped", "created", "updated": return .datetime
        default: return .text
        }
    }
    // Titles are one line: a newline in a page title becomes a space.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    // Keeps the body within the budget, cutting at a paragraph break when one is near.
    static func cut(_ body: String, budget: Int = budget) -> (text: String, original: Int?) {
        let size = body.utf8.count
        guard size > budget else { return (body, nil) }
        let head = prefix(body, bytes: budget)
        if let paragraph = head.range(of: "\n\n", options: .backwards), head.distance(from: head.startIndex, to: paragraph.lowerBound) > head.count / 2 {
            return (String(head[..<paragraph.lowerBound]), size)
        }
        return (head, size)
    }
    // The longest prefix of whole characters that fits in `bytes` of UTF-8.
    static func prefix(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: bytes)
        while end > text.startIndex, String.Index(end, within: text) == nil { end = text.utf8.index(before: end) }
        return String(text[..<end])
    }

    // YouTube transcript is appended here (YouTubeTranscript.fetch, added on the PR #8 branch).
    // Call it on the extracted draft before the card is offered it; a transcript that arrives
    // later goes through ClipCardModel.offer, which leaves an edited draft alone. The body stays
    // within the budget, and a cut says so in the note.
    mutating func appendTranscript(_ text: String) {
        let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return }
        let joined = (body.isEmpty ? "" : body + "\n\n") + "## Transcript\n\n" + transcript
        let cut = Self.cut(joined)
        body = cut.text
        if let original = cut.original { originalBytes = max(originalBytes ?? 0, original) }
    }

    func value(_ name: String) -> String? {
        properties.first { $0.name == name }.map(\.text).flatMap { $0.isEmpty ? nil : $0 }
    }
    var source: String? { value("source") }
    var site: String? { value("site") ?? source.flatMap { URL(string: $0)?.host } }
    // Empty or "Untitled" (Obsidian / clipper default) → heading, host, first line, or "Clip".
    static func isPlaceholderTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.compare("Untitled", options: .caseInsensitive) == .orderedSame
    }
    func displayTitle(url: String? = nil) -> String {
        if !Self.isPlaceholderTitle(title) { return Self.oneLine(title) }
        if let heading = Self.firstHeading(in: body) { return Self.oneLine(heading) }
        if let host = Self.host(from: url ?? source) { return host }
        if let line = Self.firstBodyLine(in: body) { return Self.oneLine(line) }
        return "Clip"
    }
    mutating func resolvePlaceholderTitle(url: String? = nil) {
        guard Self.isPlaceholderTitle(title) else { return }
        title = displayTitle(url: url)
    }
    static func firstHeading(in body: String) -> String? {
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let match = line.firstMatch(of: /^#{1,6}\s+(\S.*)$/) else { continue }
            let text = String(match.1).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        return nil
    }
    static func firstBodyLine(in body: String) -> String? {
        for raw in body.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("```") || line.hasPrefix(">") { continue }
            if let match = line.firstMatch(of: /^#{1,6}\s+/) { line = String(line[match.range.upperBound...]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return line }
        }
        return nil
    }
    static func host(from url: String?) -> String? {
        guard let url, let host = URL(string: url)?.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    var truncationNotice: String? {
        originalBytes.map { "Long page: kept the first \(Self.size(body.utf8.count)) of \(Self.size($0))." }
    }
    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // The note as saved and copied: frontmatter, body, and a line saying when the page was cut.
    var markdown: String {
        var note = Frontmatter.render(title: title, properties: properties) + body
        if let truncationNotice { note += "\n\n> [!note] " + truncationNotice }
        return note.hasSuffix("\n") ? note : note + "\n"
    }
    // The title and the body with the Markdown marks taken out.
    var plainText: String {
        let text = Self.plain(body)
        return title.isEmpty ? text : title + "\n\n" + text
    }
    var words: Int { body.split(whereSeparator: \.isWhitespace).count }

    static func plain(_ markdown: String) -> String {
        var lines: [String] = []
        var fenced = false
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .init(charactersIn: "\r"))
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fenced.toggle(); continue }
            if fenced { lines.append(line); continue }
            var text = Substring(line)
            if let match = text.firstMatch(of: /^#{1,6}\s+/) { text = text[match.range.upperBound...] }
            while let match = text.firstMatch(of: /^>\s?/) { text = text[match.range.upperBound...] }
            lines.append(MarkdownPreview.inlinePlain(String(text)))
        }
        return lines.joined(separator: "\n")
    }
}

// The small part of YAML a note's properties need: reading the clipper's frontmatter, and
// writing ours with every value quoted and escaped.
enum Frontmatter {
    struct Field: Equatable { let key: String; let values: [String]; let isList: Bool }

    static func parse(_ markdown: String) -> (fields: [Field], body: String) {
        let lines = markdown.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return ([], markdown) }
        var fields: [Field] = []
        var index = 1
        while index < close {
            let line = lines[index]; index += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("-"), let colon = keyEnd(line) else { continue }
            let key = unquote(String(line[..<colon]).trimmingCharacters(in: .whitespaces))
            let rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                var items: [String] = []
                while index < close, let item = lines[index].firstMatch(of: /^\s*-\s?(.*)$/) {
                    items.append(unquote(String(item.1).trimmingCharacters(in: .whitespaces))); index += 1
                }
                fields.append(Field(key: key, values: items, isList: !items.isEmpty))
            } else if rest.hasPrefix("[") && rest.hasSuffix("]") {
                fields.append(Field(key: key, values: flowItems(String(rest.dropFirst().dropLast())), isList: true))
            } else {
                fields.append(Field(key: key, values: [unquote(rest)], isList: false))
            }
        }
        return (fields, lines[(close + 1)...].joined(separator: "\n"))
    }
    // A flow list's items (`["Doe, Jane", 'it''s', plain]`): split only at commas outside quotes
    // (a double-quoted item may escape its quote, a single-quoted one doubles it), then each
    // unquoted. Empty items are dropped.
    static func flowItems(_ inner: String) -> [String] {
        var items: [String] = [], current = ""
        var quote: Character?, escaped = false
        func end() {
            let item = current.trimmingCharacters(in: .whitespaces)
            if !item.isEmpty { items.append(unquote(item)) }
            current = ""
        }
        for c in inner {
            if let open = quote {
                current.append(c)
                if open == "\"" {
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { quote = nil }
                } else if c == "'" { quote = nil }
                continue
            }
            if c == "," { end(); continue }
            // A quote opens an item, or (after a closing single quote) continues it: 'it''s'.
            if (c == "\"" || c == "'"), current.trimmingCharacters(in: .whitespaces).isEmpty || (c == "'" && current.last == "'") {
                if current.trimmingCharacters(in: .whitespaces).isEmpty { current = "" }
                quote = c
            }
            current.append(c)
        }
        end()
        return items
    }
    // The colon that ends a key: the first one followed by a space or the line's end, outside quotes.
    private static func keyEnd(_ line: String) -> String.Index? {
        var quote: Character?
        for index in line.indices {
            let c = line[index]
            if let open = quote { if c == open { quote = nil }; continue }
            if c == "\"" || c == "'" { quote = c; continue }
            if c == ":" {
                let next = line.index(after: index)
                if next == line.endIndex || line[next] == " " { return index }
            }
        }
        return nil
    }
    // A scalar as written: double-quoted (with escapes), single-quoted, or plain.
    static func unquote(_ text: String) -> String {
        if text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") {
            return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        var out = "", chars = Array(text.dropFirst().dropLast()), i = 0
        while i < chars.count {
            let c = chars[i]; i += 1
            guard c == "\\", i < chars.count else { out.append(c); continue }
            let e = chars[i]; i += 1
            switch e {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "0": out.append("\0")
            case "x", "u", "U":
                let width = e == "x" ? 2 : e == "u" ? 4 : 8
                let hex = String(chars[i..<min(chars.count, i + width)])
                if hex.count == width, let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) {
                    out.unicodeScalars.append(scalar); i += width
                } else { out.append(e) }
            default: out.append(e)
            }
        }
        return out
    }

    // Writes the frontmatter. Text is always double-quoted with quotes, backslashes, newlines and
    // every control or invisible line-break character escaped; dates are written bare only when
    // they are strictly a date, so Obsidian reads them as one.
    static func render(title: String, properties: [ClipDraft.Property]) -> String {
        var lines = ["---", "title: " + quoted(title)]
        for property in properties where property.name != "title" {
            let key = self.key(property.name)
            switch property.kind {
            case .list:
                let items = property.items
                if items.isEmpty { lines.append(key + ": []") }
                else { lines.append(key + ":"); lines += items.map { "  - " + quoted($0) } }
            case .date, .datetime:
                let value = property.value.trimmingCharacters(in: .whitespaces)
                lines.append(key + ":" + (value.isEmpty ? "" : " " + (isDate(value) ? value : quoted(value))))
            case .text:
                lines.append(key + ":" + (property.value.isEmpty ? "" : " " + quoted(property.value)))
            }
        }
        return (lines + ["---", ""]).joined(separator: "\n")
    }
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                let v = scalar.value
                if v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v) || v == 0x2028 || v == 0x2029 || v == 0xFEFF {
                    out += String(format: "\\u%04X", v)
                } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
    // A plain key stays bare; anything else is quoted so it can't start a new mapping.
    static func key(_ name: String) -> String {
        name.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_\-]*/) != nil ? name : quoted(name)
    }
    static func isDate(_ text: String) -> Bool {
        text.wholeMatch(of: /\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+\-]\d{2}:?\d{2})?)?/) != nil
    }
}
