import Foundation

// Turns a pasted list (or an AI's answer to "list the names and jargon I use")
// into dictionary additions: one term per line or comma, "misheard → correct"
// for a known mishearing. Bullets, numbering, bold and "(notes)" are ignored.
public struct DictionaryImport: Equatable, Sendable {
    public struct Replacement: Equatable, Sendable { public let from: String; public let to: String }
    public var newTerms: [String] = []
    public var newReplacements: [Replacement] = []
    public var alreadyHave: [String] = []
    public var tooLong: [String] = []
    public var overLimit: [String] = []
    public var skipped: [String] = []   // lines that read as sentences or code
    public init() {}

    // What the user changed in an edited copy of their list, applied to the saved
    // list as it is now: words added elsewhere meanwhile (a learned word) survive.
    public static func applyEdit(from original: String, to edited: String, builtIn: Vocabulary,
                                 saved: (terms: [String], replacements: [String: String]))
        -> (terms: [String], replacements: [String: String])? {
        let before = parse(original, existing: builtIn), after = parse(edited, existing: builtIn)
        guard after.overLimit.isEmpty, after.tooLong.isEmpty, after.skipped.isEmpty else { return nil }
        let keptTerms = Set(after.newTerms)
        let keptPairs = Dictionary(after.newReplacements.map { ($0.from, $0.to) }, uniquingKeysWith: { $1 })
        var result = saved
        // A term the user removed or respelled ("vercel" -> "Vercel") goes; the new spelling is added below.
        let keptLower = Set(after.newTerms.map { $0.lowercased() })
        for term in before.newTerms where !keptTerms.contains(term) {
            // Respelled: drop exactly the old spelling. Deleted: drop it in any case ("github" learned as "GitHub").
            if keptLower.contains(term.lowercased()) { result.terms.removeAll { $0 == term } }
            else { result.terms.removeAll { $0.lowercased() == term.lowercased() } }
        }
        for pair in before.newReplacements where keptPairs[pair.from] == nil { result.replacements[pair.from] = nil }
        let had = Set(before.newTerms)
        var added = DictionaryImport()
        added.newTerms = after.newTerms.filter { !had.contains($0) }
        // Only pairs the user added or changed: an unchanged pair never overwrites one learned meanwhile.
        let hadPairs = Dictionary(before.newReplacements.map { ($0.from, $0.to) }, uniquingKeysWith: { $1 })
        added.newReplacements = after.newReplacements.filter { hadPairs[$0.from] != $0.to }
        result = added.merged(into: result)
        let unique = Set((builtIn.terms + result.terms).map { $0.lowercased() })
        guard unique.count <= Vocabulary.maxTerms else { return nil }   // would go over the limit
        return result
    }

    public static func parse(_ text: String, existing: Vocabulary) -> DictionaryImport {
        var result = DictionaryImport()
        var known = Set(existing.terms.map { $0.lowercased() })
        let knownFrom = Set(existing.replacements.map { $0.from.lowercased() })
        var room = Vocabulary.maxTerms - existing.terms.count
        var pairTerms: [String] = []
        // A pair's correct spelling takes a slot only if one is free: the replacement
        // works without it, so a full list never loses a word to a pair.
        func addTerm(_ term: String, optional: Bool = false) {
            if known.contains(term.lowercased()) { return }
            guard term.count <= Vocabulary.maxTermLength else { if !optional { result.tooLong.append(term) }; return }
            guard room > 0 else { if !optional { result.overLimit.append(term) }; return }
            known.insert(term.lowercased()); result.newTerms.append(term); room -= 1
        }
        for line in text.components(separatedBy: .newlines) {
            let cleaned = clean(line)
            guard !cleaned.isEmpty else { continue }
            // "Here are the terms:" is a heading, not a term.
            if line.trimmingCharacters(in: .whitespaces).hasSuffix(":") {
                result.skipped.append(line.trimmingCharacters(in: .whitespaces)); continue
            }
            if let arrow = ["→", "->", "=>"].first(where: { cleaned.contains($0) }) {
                let parts = cleaned.components(separatedBy: arrow).map(clean)
                guard parts.count == 2, isTerm(parts[0]), isTerm(parts[1]) else { result.skipped.append(cleaned); continue }
                guard parts[0].count <= Vocabulary.maxTermLength, parts[1].count <= Vocabulary.maxTermLength else {
                    result.tooLong.append(cleaned); continue
                }
                if !knownFrom.contains(parts[0].lowercased()),
                   !result.newReplacements.contains(where: { $0.from == parts[0].lowercased() }) {
                    result.newReplacements.append(Replacement(from: parts[0].lowercased(), to: parts[1]))
                }
                pairTerms.append(parts[1])
                continue
            }
            let items = cleaned.contains(",") ? cleaned.components(separatedBy: ",").map(clean) : [cleaned]
            for item in items where !item.isEmpty {
                if item.count > Vocabulary.maxTermLength, !item.contains(" ") { result.tooLong.append(item); continue }
                guard isTerm(item) else { result.skipped.append(item); continue }
                if known.contains(item.lowercased()) {
                    if existing.terms.contains(where: { $0.lowercased() == item.lowercased() }) { result.alreadyHave.append(item) }
                    continue
                }
                addTerm(item)
            }
        }
        // Pair targets last, so they only use slots the listed words left free.
        for term in pairTerms { addTerm(term, optional: true) }
        return result
    }

    // The additions applied to what the user already has saved.
    public func merged(into saved: (terms: [String], replacements: [String: String]))
        -> (terms: [String], replacements: [String: String]) {
        var replacements = saved.replacements
        for pair in newReplacements { replacements[pair.from] = pair.to }
        var terms = saved.terms
        for term in newTerms where !terms.contains(where: { $0.lowercased() == term.lowercased() }) { terms.append(term) }
        return (terms, replacements)
    }

    // "1. **Vercel** (company)" -> "Vercel".
    static func clean(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        if let range = text.range(of: #"^(?:[-*•–]|\d+[.)])\s*"#, options: .regularExpression) { text.removeSubrange(range) }
        text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        if let range = text.range(of: #"\s*\([^)]*\)\s*$"#, options: .regularExpression) { text.removeSubrange(range) }
        return text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"“”'.;:")))
    }
    // A name or term: at most four words, mostly letters. Technical spellings the
    // user actually dictates (C#, foo/bar, @handle, Node.js, GPT-5) are terms too;
    // only characters that would make the line code or markup reject it.
    static func isTerm(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        guard (1...4).contains(words.count), text.contains(where: \.isLetter),
              !text.contains(where: { "\\|$<>={}[]()".contains($0) }) else { return false }
        // Paths and addresses are not terms: no leading slash, no "..", at most
        // one slash between alphanumerics, and "@" only as a leading handle.
        guard !text.hasPrefix("/"), !text.contains("..") else { return false }
        if text.contains("@") {
            guard text.hasPrefix("@"), text.filter({ $0 == "@" }).count == 1, words.count == 1 else { return false }
        }
        if text.contains("/") {
            let parts = text.split(separator: "/")
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        }
        return text.allSatisfy { $0.isLetter || $0.isNumber || " '’.&+-#/@_".contains($0) }
    }
}

// Learns from the user's own fix: when a word CursusVox pasted is changed to a
// similar-looking name ("Vassal" -> "Vercel", "Casey" -> "Katie"), or up to three
// pasted words become one name ("super base" -> "Supabase"), the fix can join the
// dictionary. Only an edit inside the pasted text counts; rewrites, deletions,
// edits elsewhere in the field and swaps for ordinary words are ignored.
public enum CorrectionLearner {
    public struct Correction: Equatable, Sendable {
        public let heard: String
        public let correct: String
        // A replacement is saved only when the misheard word isn't itself an ordinary
        // word: "vassal" or "sync" must never be rewritten everywhere. The name alone
        // still becomes a Grok key term.
        public var addsReplacement: Bool
        public var isCaseOnly: Bool { heard.lowercased() == correct.lowercased() }
        public init(heard: String, correct: String, addsReplacement: Bool = true) {
            self.heard = heard; self.correct = correct; self.addsReplacement = addsReplacement
        }
    }
    public enum Outcome: Equatable, Sendable {
        case learned(Correction)
        case unchanged
        case outside(at: Int)   // the edit didn't touch the pasted text, now at this offset: keep watching
        case rewritten    // the pasted text changed in a way that isn't a fix: stop
    }
    public static let limit = 20_000

    // `before` is the field's text once the paste landed and `pastedAt` the
    // character offset where the pasted text starts in it (from the caret, so a
    // copy of the same words elsewhere in the field never counts); `now` is the
    // field's text later. `isCommonWord` says whether a word is ordinary English
    // (the app asks the system spell checker).
    public static func compare(before: String, pastedAt pastedStart: Int, pasted: String, now: String,
                               isCommonWord: (String) -> Bool = { _ in false }) -> Outcome {
        let old = Array(before), new = Array(now), said = Array(pasted)
        let pastedEnd = pastedStart + said.count
        guard old.count <= limit, new.count <= limit, !said.isEmpty, pastedStart >= 0, pastedEnd <= old.count,
              Array(old[pastedStart..<pastedEnd]) == said else { return .rewritten }
        if old == new { return .unchanged }
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        // Widen the change to whole words, but only where it touches one: a word
        // typed after the pasted text is a separate edit.
        func solid(_ text: [Character], _ index: Int) -> Bool { index >= 0 && index < text.count && !text[index].isWhitespace }
        let touchesLeft = solid(old, prefix) && prefix < old.count - suffix || solid(new, prefix) && prefix < new.count - suffix
        let touchesRight = solid(old, old.count - suffix - 1) && old.count - suffix - 1 >= prefix
            || solid(new, new.count - suffix - 1) && new.count - suffix - 1 >= prefix
        if touchesLeft { while prefix > 0, !old[prefix - 1].isWhitespace { prefix -= 1 } }
        if touchesRight { while suffix > 0, !old[old.count - suffix].isWhitespace { suffix -= 1 } }
        let changedEnd = old.count - suffix
        // An edit before the pasted text moves it; one after it doesn't.
        if changedEnd <= pastedStart { return .outside(at: pastedStart + new.count - old.count) }
        if prefix >= pastedEnd { return .outside(at: pastedStart) }
        guard prefix >= pastedStart, changedEnd <= pastedEnd else { return .rewritten }
        let was = words(String(old[prefix..<changedEnd])), now = words(String(new[prefix..<(new.count - suffix)]))
        guard (1...3).contains(was.count), (1...3).contains(now.count) else { return .rewritten }
        let heard = was.joined(separator: " "), correct = now.joined(separator: " ")
        // "Maelah" -> "Maelah's" or "Vassal" -> "Vassals" extends a word; it isn't a fix.
        // ("maela" -> "Maelah" is still a fix: only grammatical endings count as extending.)
        func extended(_ long: String, _ short: String) -> Bool {
            let long = long.lowercased().replacingOccurrences(of: "\u{2019}", with: "'"), short = short.lowercased()
            return long.count > short.count && long.hasPrefix(short)
                && ["'s", "s", "es", "ed", "d", "ing", "'"].contains(String(long.dropFirst(short.count)))
        }
        let extends = extended(correct, heard) || extended(heard, correct)
        // One word may start with any letter if it sounds close ("Casey" -> "Katie"); a run
        // of words must always spell close to the name ("super base" -> "Supabase"). Either
        // way the fix must be a name, with a capital: "as well" -> "aswel" is a typo, not a name.
        let sameStart = heard.first?.lowercased() == correct.first?.lowercased()
        let looseMatch = was.count > 1 || now.count > 1 || !sameStart
        guard !extends, was.allSatisfy({ $0.count >= 2 }), heard.count <= Vocabulary.maxTermLength,
              correct.count >= 3, correct.count <= Vocabulary.maxTermLength,
              was.allSatisfy({ $0.allSatisfy { $0.isLetter || $0 == "'" } }), correct.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "'" || $0 == " " }),
              !looseMatch || close(heard, correct) && correct.contains(where: \.isUppercase),
              !isCommonWord(correct) else { return .rewritten }
        let caseOnly = heard.lowercased() == correct.lowercased()
        // A run of words is specific enough to replace everywhere; one ordinary word never is.
        let replaces = !caseOnly && (was.count > 1 || !isCommonWord(heard))
        return .learned(Correction(heard: heard, correct: correct, addsReplacement: replaces))
    }

    // Whether a learned word goes straight into the dictionary. A name has a capital; "ANDimprovements"
    // and "onmykoala" are slips of the keyboard, which only ever wait in the inbox.
    public static func isSafeToAdopt(_ term: String) -> Bool {
        guard term.contains(where: \.isUppercase) else { return false }
        return term.range(of: #"[A-Z]{2,}[a-z]{3,}"#, options: .regularExpression) == nil
    }
    // A slip of the keyboard, not a name: an ordinary word with two letters swapped or one letter
    // doubled or dropped ("This" -> "Thsi", "Okay" -> "Okayy"), or several words run together with no
    // capital inside ("on my koala" -> "Onmykoala"). "Cory" -> "Kora" is none of these.
    public static func isKeyboardSlip(heard: String, correct: String, isCommonWord: (String) -> Bool) -> Bool {
        let words = heard.split(whereSeparator: \.isWhitespace)
        if words.count > 1, !correct.contains(" "), !correct.dropFirst().contains(where: \.isUppercase) { return true }
        guard words.count == 1, isCommonWord(heard) else { return false }
        let a = Array(heard.lowercased()), b = Array(correct.lowercased())
        if a.count == b.count {
            let diff = a.indices.filter { a[$0] != b[$0] }
            return diff.count == 2 && diff[1] == diff[0] + 1 && a[diff[0]] == b[diff[1]] && a[diff[1]] == b[diff[0]]
        }
        let (long, short) = a.count > b.count ? (a, b) : (b, a)
        guard long.count == short.count + 1 else { return false }
        for index in long.indices where Array(long[..<index] + long[(index + 1)...]) == short {
            let neighbourSame = (index > 0 && long[index - 1] == long[index]) || (index + 1 < long.count && long[index + 1] == long[index])
            if neighbourSame || long.count == a.count { return true }
        }
        return false
    }
    // A word said often that is close to one already saved ("DeepSeq", "DeepSeek") is a mishearing to fix, not a new word.
    public static func isNewWord(_ term: String, existing: [String]) -> Bool {
        isSafeToAdopt(term) && !existing.contains { $0.caseInsensitiveCompare(term) == .orderedSame || close(term, $0) }
    }
    // Spelled close: at most a third of the letters differ (at least two may), comparing
    // letters only, with the common sound-alike spellings folded ("c"/"k", "ph"/"f", "y"/"i").
    static func close(_ heard: String, _ correct: String) -> Bool {
        func key(_ text: String) -> [Character] {
            var folded = text.lowercased().filter(\.isLetter)
            for (from, to) in [("ph", "f"), ("ck", "k"), ("c", "k"), ("y", "i"), ("z", "s")] {
                folded = folded.replacingOccurrences(of: from, with: to)
            }
            return Array(folded)
        }
        let a = key(heard), b = key(correct)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return distance(a, b) <= max(2, max(a.count, b.count) / 3)
    }
    // Levenshtein distance.
    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]; row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?…\"“”()")) }.filter { !$0.isEmpty }
    }
}

// Names the user keeps saying that the dictionary doesn't have yet. Dictation text
// is erased after 10 minutes; only the name-like words from each one are kept, in
// memory, for a day. They're offered on the Dictionary page and, unless Settings
// turns it off, added on their own (autoAdd).
public enum RepeatedTerms {
    public static let textLifetime: TimeInterval = 10 * 60
    public static let namesLifetime: TimeInterval = 24 * 60 * 60
    public static let minimumCount = 3
    public struct Suggestion: Equatable, Sendable {
        public let term: String; public let count: Int
        public init(term: String, count: Int) { self.term = term; self.count = count }
    }

    // The name-like words in one dictation. A name has a capital letter; "I", "OK"
    // and two-letter words aren't worth a slot. Code and commands give none.
    public static func names(in text: String) -> [String] {
        guard !TranscriptCleanup.isTechnical(text) else { return [] }
        return CorrectionLearner.words(text).filter { word in
            word.count >= 3 && word.count <= Vocabulary.maxTermLength && word.contains(where: \.isUppercase) && word.allSatisfy { $0.isLetter || $0 == "'" }
        }
    }

    // Everything worth remembering from one dictation: names, plus code-shaped
    // tokens (get_code, getCode, k8s, GPT-5) that `names` and the technical-text
    // gate can never see. Code tokens are read from the raw words, so a transcript
    // full of code still yields the identifiers said in it. Only the tokens are
    // kept, never the text around them.
    private static func secretShaped(_ word: String) -> Bool {
        ["secret", "token", "password", "passwd", "credential", "apikey", "api_key"].contains { word.lowercased().contains($0) }
    }
    public static func terms(in text: String) -> [String] {
        var found = names(in: text).filter { !secretShaped($0) }
        for raw in text.split(whereSeparator: { $0.isWhitespace || ",;:!?\"“”()".contains($0) }) {
            let word = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".'"))
            guard word.count >= 2, word.count <= Vocabulary.maxTermLength else { continue }
            let codeShaped = word.contains("_")
                || (word.contains(where: \.isLowercase) && word.contains(where: \.isUppercase))
                || (word.contains(where: \.isLetter) && word.contains(where: \.isNumber))
            // A learned term is sent to cloud engines on every dictation; a
            // secret-shaped token must never be captured, let alone sent.
            guard codeShaped, !secretShaped(word), word.allSatisfy({ $0.isLetter || $0.isNumber || "_-".contains($0) }),
                  !found.contains(where: { $0.lowercased() == word.lowercased() }) else { continue }
            found.append(word)
        }
        return found
    }

    public static func suggest(_ texts: [String], existing: Vocabulary, limit: Int = 8,
                               isCommonWord: (String) -> Bool = { _ in false }) -> [Suggestion] {
        suggest(names: texts.map(names(in:)), existing: existing, limit: limit, isCommonWord: isCommonWord)
    }

    public static func suggest(names seen: [[String]], existing: Vocabulary, limit: Int = 8,
                               isCommonWord: (String) -> Bool = { _ in false }) -> [Suggestion] {
        let known = Set(existing.terms.map { $0.lowercased() } + existing.replacements.map { $0.to.lowercased() })
        var counts: [String: (spelling: String, count: Int, dictations: Int)] = [:]
        for words in seen {
            var inThis = Set<String>()
            for word in words where !known.contains(word.lowercased()) {
                let key = word.lowercased()
                let entry = counts[key] ?? (spelling: word, count: 0, dictations: 0)
                counts[key] = (entry.spelling, entry.count + 1, entry.dictations + (inThis.insert(key).inserted ? 1 : 0))
            }
        }
        // Three times in one breath must not teach the dictionary a word the
        // engine itself may have invented: a term earns its slot across at
        // least two separate dictations.
        return counts.values
            .filter { $0.count >= minimumCount && $0.dictations >= 2 && !isCommonWord($0.spelling) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.spelling < $1.spelling }
            .prefix(limit).map { Suggestion(term: $0.spelling, count: $0.count) }
    }

    // The names to add to the dictionary now. `added` holds every name added this way
    // before (lowercased), so one the user then removed is never added again.
    public static func autoAdd(names seen: [[String]], existing: Vocabulary, added: Set<String>,
                               isCommonWord: (String) -> Bool = { _ in false }) -> [String] {
        suggest(names: seen, existing: existing, limit: Vocabulary.maxTerms, isCommonWord: isCommonWord)
            .map(\.term).filter { !added.contains($0.lowercased()) }
    }
}
