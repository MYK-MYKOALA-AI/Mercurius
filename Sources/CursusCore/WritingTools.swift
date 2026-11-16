import Foundation

public struct Snippet: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var cue: String
    public var text: String
    public init(id: UUID = UUID(), cue: String, text: String) { self.id = id; self.cue = cue; self.text = text }
}

public struct SnippetBook: Codable, Equatable, Sendable {
    public private(set) var entries: [Snippet] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case entries }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode([Snippet].self, forKey: .entries)
        guard decoded.count <= 200 else { throw DecodingError.dataCorruptedError(forKey: .entries, in: container, debugDescription: "Too many snippets") }
        var ids = Set<UUID>()
        for entry in decoded {
            guard ids.insert(entry.id).inserted else { throw DecodingError.dataCorruptedError(forKey: .entries, in: container, debugDescription: "Duplicate snippet identity") }
            do { try save(entry, dictionary: []) }
            catch { throw DecodingError.dataCorruptedError(forKey: .entries, in: container, debugDescription: "Invalid snippet") }
        }
    }
    public enum Problem: Error, Equatable { case invalidCue, invalidText, duplicateCue, dictionaryConflict, full }
    public static func key(_ cue: String) -> String {
        cue.split(whereSeparator: \.isWhitespace).joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_AU"))
    }
    public mutating func save(_ snippet: Snippet, dictionary: [String]) throws(Problem) {
        let cue = Self.key(snippet.cue)
        guard !cue.isEmpty, cue.count <= 80, !snippet.cue.contains(where: \.isNewline) else { throw .invalidCue }
        guard !snippet.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              snippet.text.utf8.count <= 64 * 1024 else { throw .invalidText }
        guard !entries.contains(where: { $0.id != snippet.id && Self.key($0.cue) == cue }) else { throw .duplicateCue }
        guard !dictionary.contains(where: { Self.key($0) == cue }) else { throw .dictionaryConflict }
        let saved = Snippet(id: snippet.id, cue: snippet.cue.trimmingCharacters(in: .whitespacesAndNewlines), text: snippet.text)
        if let i = entries.firstIndex(where: { $0.id == snippet.id }) { entries[i] = saved }
        else { guard entries.count < 200 else { throw .full }; entries.append(saved) }
    }
    public mutating func remove(_ id: UUID) { entries.removeAll { $0.id == id } }
    // Explicit expansion through Command Mode: `snippet <cue>`.
    public func expand(_ cue: String) -> String? { entries.first { Self.key($0.cue) == Self.key(cue) }?.text }
    // Dictation-side expansion (WhisprFlow parity, 2026-11-09). A recording expands ONLY when its
    // whole cleaned transcript is exactly one saved cue. A sentence that merely contains a cue, a
    // cue used mid-sentence, an empty transcript or a Writing-tools command are all left untouched,
    // so ordinary dictation cannot be rewritten by a snippet.
    public func expansion(forTranscript transcript: String, dictionary: [String] = []) -> String? {
        guard !entries.isEmpty else { return nil }
        let spoken = Self.key(transcript)
        guard !spoken.isEmpty else { return nil }
        guard let entry = entries.first(where: { Self.key($0.cue) == spoken }) else { return nil }
        // A cue that is also a dictionary term belongs to the dictionary: the explicit `snippet <cue>`
        // command refuses that conflict, so dictation must not silently expand it either.
        guard !dictionary.contains(where: { Self.key($0) == spoken }) else { return nil }
        return entry.text
    }
    // The dictation path's rule, in one place so the safeguards are testable rather than buried in the
    // app: a whole-recording cue expands, except for technical text (which policy preserves verbatim and
    // never rewrites) and a cue the dictionary also owns.
    public func dictationExpansion(forSpoken spoken: String, cleaned: String, dictionary: [String]) -> String? {
        guard !TranscriptCleanup.isTechnical(spoken) else { return nil }
        return expansion(forTranscript: cleaned, dictionary: dictionary)
    }
}

public enum WritingCommand: Equatable, Sendable {
    case rewrite(Style), translate(String), snippet(String), search(String), uppercase, lowercase, bullets
    public enum Style: String, CaseIterable, Sendable { case concise, formal, friendly }
    // Only recorded commands use this, before the editable confirmation field is shown.
    // Typed arguments and ordinary dictation retain their literal punctuation.
    public static func spokenInput(_ text: String) -> String {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var input = original.trimmingCharacters(in: CharacterSet(charactersIn: ".!?").union(.whitespacesAndNewlines))
        for prefix in ["translate to", "rewrite", "translate", "snippet", "search", "bullet"]
        where input.lowercased().hasPrefix(prefix + ",") {
            let comma = input.index(input.startIndex, offsetBy: prefix.count)
            input = String(input[..<comma]) + " " + input[input.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            break
        }
        return parse(input) == nil ? original : input
    }
    public static func parse(_ text: String) -> WritingCommand? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = input.lowercased()
        if key == "uppercase" { return .uppercase }
        if key == "lowercase" { return .lowercase }
        if key == "bullet list" { return .bullets }
        for style in Style.allCases where key == "rewrite " + style.rawValue { return .rewrite(style) }
        for prefix in ["translate to ", "snippet ", "search "] where key.hasPrefix(prefix) {
            let value = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count <= 512 else { return nil }
            if prefix == "translate to " { return .translate(value) }
            if prefix == "snippet " { return .snippet(value) }
            return .search(value)
        }
        return nil
    }
    public func localResult(source: String, snippets: SnippetBook) -> String? {
        switch self {
        case .uppercase: return source.uppercased()
        case .lowercase: return source.lowercased()
        case .bullets: return source.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { "- " + $0 }.joined(separator: "\n")
        case let .snippet(cue): return snippets.expand(cue)
        default: return nil
        }
    }
    public var instruction: String? {
        switch self {
        case let .rewrite(style): return "Rewrite the supplied text in a \(style.rawValue) style. Preserve its facts, names, numbers and meaning."
        case let .translate(language): return "Translate the supplied text into \(language). Preserve meaning, names, numbers and formatting."
        default: return nil
        }
    }
}

public enum RetainedTextSearch {
    public static func matches(_ query: String, fields: [String]) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return false }
        return terms.allSatisfy { term in fields.contains { $0.localizedStandardContains(String(term)) } }
    }
}

public struct WritingPreviewState: Equatable, Sendable {
    public private(set) var generation = UUID()
    public private(set) var original = ""
    public private(set) var output: String?
    public init() {}
    @discardableResult public mutating func begin(source: String) -> UUID {
        generation = UUID(); original = source; output = nil; return generation
    }
    @discardableResult public mutating func receive(_ text: String, generation: UUID, currentSource: String) -> Bool {
        guard generation == self.generation, original == currentSource,
              original.utf8.count <= Policy.textLimit, !text.isEmpty, text.utf8.count <= Policy.textLimit else { return false }
        output = text; return true
    }
    public func usable(currentSource: String) -> Bool { output != nil && currentSource == original }
    public mutating func clear() { generation = UUID(); original = ""; output = nil }
    public static func sameSelection(original: String, current: String, expected: SelectionAnchor?, observed: SelectionAnchor?) -> Bool {
        guard let expected, let observed, expected.length > 0 else { return false }
        return expected == observed && original == current
    }
}

public struct CommandCaptureState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, starting, recording, finalizing }
    public private(set) var phase = Phase.idle
    public var busy: Bool { phase != .idle }
    public init() {}
    @discardableResult public mutating func begin() -> Bool {
        guard phase == .idle else { return false }; phase = .starting; return true
    }
    @discardableResult public mutating func ready() -> Bool {
        guard phase == .starting else { return false }; phase = .recording; return true
    }
    @discardableResult public mutating func finish() -> Bool {
        guard phase == .recording else { return false }; phase = .finalizing; return true
    }
    public enum Stop: Equatable, Sendable { case cancelStartup, finalize, ignored }
    public mutating func stop() -> Stop {
        switch phase {
        case .starting: reset(); return .cancelStartup
        case .recording: _ = finish(); return .finalize
        case .idle, .finalizing: return .ignored
        }
    }
    public mutating func reset() { phase = .idle }
}
