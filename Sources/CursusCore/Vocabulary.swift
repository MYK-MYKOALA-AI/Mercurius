import Foundation

// The user's own words: names and terms speech engines tend to mishear. Terms
// are sent to Grok as key terms; replacements fix what still comes back wrong.
public struct Vocabulary: Equatable, Sendable {
    // The personal dictionary is larger than any one provider's speech hints.
    public static let maxTerms = 500
    public static let maxSpeechHints = 100
    public static let maxTermLength = 50
    public static let seed: [String] = []
    public static let seedReplacements: [String: String] = [:]

    public let terms: [String]
    public let replacements: [(from: String, to: String)]
    // Phrases that take back the words before them (TakeBack). Empty: corrections are kept as spoken.
    public let takeBacks: [String]
    public let recognitionOnly: Set<String>
    public var cleanupTerms: [String] { terms.filter { !recognitionOnly.contains($0.lowercased()) } }

    public init(terms: [String], replacements: [String: String] = [:], takeBacks: [String] = [], recognitionOnly: [String] = []) {
        self.recognitionOnly = Set(recognitionOnly.map { $0.lowercased() })
        self.takeBacks = TakeBack.parse(takeBacks.joined(separator: "\n"))
        var seen = Set<String>(), kept: [String] = []
        for raw in terms where kept.count < Self.maxTerms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= Self.maxTermLength, seen.insert(term.lowercased()).inserted else { continue }
            kept.append(term)
        }
        self.terms = kept
        // Longest first, so "super base" wins over "base".
        self.replacements = replacements
            .map { (from: $0.key.trimmingCharacters(in: .whitespaces), to: $0.value) }
            .filter { !$0.from.isEmpty }
            .sorted { $0.from.count > $1.from.count }
    }

    public static func effective(terms: [String], replacements: [String: String], takeBacks: [String] = [], recognitionOnly: [String] = []) -> Vocabulary {
        let hints = Set(recognitionOnly.map { $0.lowercased() })
        var rules = autoReplacements(for: terms.filter { !hints.contains($0.lowercased()) })
        for (from, to) in replacements { rules[from] = to }
        return Vocabulary(terms: terms, replacements: rules, takeBacks: takeBacks, recognitionOnly: recognitionOnly)
    }

    // Derives automatic split-word and exact-casing replacements for CamelCase/compound dictionary terms
    // ("CursusVox" -> "cursus vox", "FastAPI" -> "fast api", "PostHog" -> "post hog") so user-added terms
    // work even when the speech engine splits them into separate words or lowercases them.
    public static func autoReplacements(for terms: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for raw in terms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, !term.contains(" ") else { continue }
            let chars = Array(term)
            guard chars.dropFirst().contains(where: \.isUppercase) else { continue }
            var parts: [String] = []
            var current = ""
            for i in chars.indices {
                let c = chars[i]
                if i > 0, c.isUppercase {
                    let prev = chars[i - 1]
                    let nextLower = (i + 1 < chars.count) && chars[i + 1].isLowercase
                    if prev.isLowercase || (prev.isUppercase && nextLower) {
                        parts.append(current.lowercased())
                        current = ""
                    }
                }
                current.append(c)
            }
            if !current.isEmpty { parts.append(current.lowercased()) }
            if (2...4).contains(parts.count), parts.allSatisfy({ $0.count >= 2 }) {
                out[parts.joined(separator: " ")] = term
            }
        }
        return out
    }

    // Spans where words must stay exactly as spoken: backtick code and quoted text.
    // A replacement inside `echo "super base"` would corrupt the literal (PLAN 21).
    static func protectedSpans(_ text: String) -> [Range<String.Index>] {
        var spans: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char == "`" {
                // A run of backticks is one fence: ```code``` is a single span,
                // not open-close-open around unprotected code.
                var fenceEnd = index
                while fenceEnd < text.endIndex, text[fenceEnd] == "`" { fenceEnd = text.index(after: fenceEnd) }
                let fence = text[index..<fenceEnd]
                if let close = text.range(of: fence, range: fenceEnd..<text.endIndex) {
                    spans.append(index..<close.upperBound); index = close.upperBound
                } else { index = fenceEnd }   // unterminated fence protects nothing after it
                continue
            }
            if char == "\"" || char == "“" {
                let closeMark: Character = char == "“" ? "”" : "\""
                let after = text.index(after: index)
                // Only a quote with a closing partner protects; a stray quote
                // must not switch off every replacement after it.
                if let close = text[after...].firstIndex(of: closeMark) {
                    spans.append(index..<text.index(after: close)); index = text.index(after: close)
                } else { index = after }
                continue
            }
            index = text.index(after: index)
        }
        return spans
    }

    // Whole-word, case-insensitive replacement of each misheard phrase, never
    // inside a protected span.
    public func apply(_ text: String) -> String {
        let spans = Self.protectedSpans(text)
        guard !spans.isEmpty else {
            return replacements.reduce(text) { result, rule in Self.apply(rule, to: result) }
        }
        var result = ""
        var cursor = text.startIndex
        for span in spans {
            result += replacements.reduce(String(text[cursor..<span.lowerBound])) { Self.apply($1, to: $0) }
            result += text[span]
            cursor = span.upperBound
        }
        result += replacements.reduce(String(text[cursor...])) { Self.apply($1, to: $0) }
        return result
    }
    private static func apply(_ rule: (from: String, to: String), to result: String) -> String {
        // Whole words between spaces or punctuation, never inside "superbase.io".
        let escaped = rule.from.map { char in
            char == "'" || char == "’" ? "['’]" : NSRegularExpression.escapedPattern(for: String(char))
        }.joined()
        let pattern = "(?<![^\\s,(\"“])" + escaped
            + "(?=[,.!?;:)\"”]*(?:\\s|$))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return result }
        let range = NSRange(result.startIndex..., in: result)
        return regex.stringByReplacingMatches(in: result, range: range,
                                              withTemplate: NSRegularExpression.escapedTemplate(for: rule.to))
    }

    public func appliedCorrections(in text: String) -> [String] {
        var current = text; var applied: [String] = []
        for rule in replacements {
            let next = Vocabulary(terms: [], replacements: [rule.from: rule.to]).apply(current)
            if next != current { applied.append(rule.from + " → " + rule.to); current = next }
        }
        return applied
    }
    public static func == (lhs: Vocabulary, rhs: Vocabulary) -> Bool {
        lhs.terms == rhs.terms && lhs.replacements.map(\.from) == rhs.replacements.map(\.from)
            && lhs.replacements.map(\.to) == rhs.replacements.map(\.to) && lhs.takeBacks == rhs.takeBacks
            && lhs.recognitionOnly == rhs.recognitionOnly
    }
}
