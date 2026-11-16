import Foundation

public struct VocabularySuggestion: Codable, Equatable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable { case correction, repeated }
    public let id: UUID
    public var term: String
    public var from: String?
    public var source: Source
    public var count: Int
    public var timestamp: Date
    var key: String { (from ?? "").lowercased() + "→" + term.lowercased() }
}
public struct VocabularyChange: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let term: String
    public let from: String?
    public let addedTerm: Bool
    public let addedRule: Bool
    public let revision: Int
    public var recognitionOnlyBefore: Bool? = nil
    public var recognitionOnlyAfter: Bool? = nil
}
public struct VocabularyInbox: Codable, Equatable, Sendable {
    public enum Approval: Sendable { case hintOnly, hintAndReplacement }
    public var version = 1
    public private(set) var pending: [VocabularySuggestion] = []
    public private(set) var ignored: [VocabularySuggestion] = []
    public private(set) var accepted: [VocabularyChange] = []
    public init() {}
    // `pending` ages out and `accepted` is capped, but `ignored` had no bound at all: every
    // dismissed suggestion stayed for the life of the install, inside one UserDefaults value.
    // The oldest dismissals are now dropped first, which is the only case in which a dismissed
    // suggestion can be offered again; recent dismissals are still remembered.
    public static let ignoredLimit = 200
    public mutating func purge(now: Date = Date()) {
        pending.removeAll { now.timeIntervalSince($0.timestamp) >= 30*86400 }
        if ignored.count > Self.ignoredLimit { ignored.removeFirst(ignored.count - Self.ignoredLimit) }
    }
    public mutating func suggest(term: String, from: String?, source: VocabularySuggestion.Source, count: Int = 1, now: Date = Date()) {
        purge(now: now)
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= Vocabulary.maxTermLength else { return }
        let suggestion = VocabularySuggestion(id: UUID(),term: term,from: from,source: source,count: count,timestamp: now)
        guard !ignored.contains(where: { $0.key == suggestion.key }) else { return }
        if let i = pending.firstIndex(where: { $0.key == suggestion.key }) {
            pending[i].count = min(Int.max-1, max(pending[i].count,count))
            pending[i].timestamp = now
        } else if pending.count < 100 { pending.append(suggestion) }
    }
    public mutating func ignore(_ id: UUID) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        // Ignored choices stay until the user restores them, or until `purge` drops the oldest
        // past `ignoredLimit`. A forgotten dismissal is never reactivated silently: it can only
        // come back as a fresh suggestion the user sees again.
        ignored.append(pending.remove(at: i))
    }
    @discardableResult public mutating func restore(_ id: UUID, now: Date = Date()) -> Bool {
        purge(now: now)
        guard pending.count < 100, let index = ignored.firstIndex(where: { $0.id == id }) else { return false }
        var suggestion = ignored.remove(at: index)
        suggestion.timestamp = now
        pending.append(suggestion)
        return true
    }
    public mutating func accept(_ id: UUID, editedTerm: String? = nil, terms: [String], replacements: [String:String], revision: Int = 0, approval: Approval = .hintAndReplacement, wasRecognitionOnly: Bool? = nil, now: Date = Date()) -> (terms: [String], replacements: [String:String])? {
        purge(now: now)
        guard let suggestion = pending.first(where: { $0.id == id }) else { return nil }
        let term = (editedTerm ?? suggestion.term).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= Vocabulary.maxTermLength else { return nil }
        let added = !terms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame })
        guard !added || terms.count < Vocabulary.maxTerms else { return nil }
        var rules = replacements; var addedRule = false
        if approval == .hintAndReplacement, let from = suggestion.from, from.caseInsensitiveCompare(term) != .orderedSame {
            if let existing = rules.first(where: { $0.key.caseInsensitiveCompare(from) == .orderedSame }) {
                guard existing.value == term else { return nil }
            } else { rules[from] = term; addedRule = true }
        }
        var change = VocabularyChange(id: UUID(),term: term,from: suggestion.from,addedTerm: added,addedRule: addedRule,revision: revision)
        change.recognitionOnlyBefore = wasRecognitionOnly
        change.recognitionOnlyAfter = wasRecognitionOnly.map { approval == .hintAndReplacement ? false : added ? true : $0 }
        accepted.append(change); if accepted.count > 100 { accepted.removeFirst() }
        pending.removeAll { $0.id == id }
        return (added ? terms+[term] : terms,rules)
    }
    public mutating func undo(_ id: UUID, terms: [String], replacements: [String:String], revision: Int = 0, recognitionOnly: Bool? = nil) -> (terms: [String], replacements: [String:String])? {
        guard let change = accepted.first(where: { $0.id == id }), change.revision == revision else { return nil }
        if let expected = change.recognitionOnlyAfter, recognitionOnly != expected { return nil }
        var rules = replacements
        if change.addedRule, let from = change.from {
            guard rules[from] == change.term else { return nil }; rules.removeValue(forKey: from)
        }
        var words = terms
        if change.addedTerm {
            guard words.contains(change.term) else { return nil }
            // Another accepted or manually entered correction may now depend on this term.
            if !rules.values.contains(change.term) { words.removeAll { $0 == change.term } }
        }
        accepted.removeAll { $0.id == id }; return (words,rules)
    }
}
