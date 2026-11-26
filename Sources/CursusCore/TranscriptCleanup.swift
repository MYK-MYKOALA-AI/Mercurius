import Foundation

// Deterministic cleanup that runs on every transcript, online or not, plus the
// guard that decides whether an AI rewrite may replace it.
public enum TranscriptCleanup {
    // Only sounds that are never real words: "er" (ER), "mm" (5 mm) and "ah" stay.
    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "erm", "hmm"]

    // Drops um/uh-style fillers, collapses marked stutters ("I want to, I want to",
    // "the, uh, the") and applies the user's replacements. It works on whole words:
    // a removed word takes its own punctuation and the space before it, and every
    // other character comes back exactly as spoken.
    public static func rules(_ text: String, vocabulary: Vocabulary) -> String {
        // Code, commands, paths and quotes are left exactly as spoken.
        if isTechnical(text) { return vocabulary.apply(text) }
        // A word (any run of non-space characters) and the whitespace before it.
        struct Piece {
            var gap: String, word: String
            var core: String, trail: String   // the word without, and its trailing, prose punctuation
            var deleted = false
            var isFiller = false
        }
        let prose = Set(".,;:!?)\"\u{201d}\u{2026}"), pause = Set(".!?\u{2026}"), sentenceEnd = Set(".!?;:\u{2026}")
        var pieces: [Piece] = [], gap = "", word = ""
        func flush() {
            guard !word.isEmpty else { return }
            var core = Substring(word), trail = ""
            while let last = core.last, prose.contains(last) { trail.insert(last, at: trail.startIndex); core.removeLast() }
            pieces.append(Piece(gap: gap, word: word, core: String(core), trail: trail))
            gap = ""; word = ""
        }
        for c in text { if c.isWhitespace { flush(); gap.append(c) } else { word.append(c) } }
        flush()
        let tail = gap
        guard !pieces.isEmpty else { return "" }

        // Fillers: whole words, lowercase or Capitalised ("HMM" and "uH" are names),
        // with nothing glued on but commas or a pause ("um,", "uh...", "Um.").
        for index in pieces.indices {
            let piece = pieces[index]
            let spelling = piece.core.prefix(1).lowercased() + piece.core.dropFirst()
            guard fillers.contains(spelling), piece.core.dropFirst() == piece.core.lowercased().dropFirst(),
                  piece.trail.allSatisfy({ ",.!?\u{2026}".contains($0) }) else { continue }
            pieces[index].deleted = true; pieces[index].isFiller = true
        }

        // Stutters: one to four ordinary words said again straight after a comma,
        // dash or filler, in one sentence with no negation ("Do not go, go away."
        // keeps both). Letters only: "1, 1", "x --x" and "fooBar, foobar" are real.
        func ordinary(_ piece: Piece) -> Bool {
            guard let first = piece.core.first, first.isLetter, !isNegation(piece.core) else { return false }
            return piece.core.allSatisfy { $0.isLetter || $0 == "'" || $0 == "\u{2019}" }
        }
        // A spaced hyphen may be a minus ("x - x"), so only a long dash marks a stutter.
        func isDash(_ piece: Piece) -> Bool { ["\u{2014}", "\u{2013}"].contains(piece.word) }
        var sentence = [Int](repeating: 0, count: pieces.count), current = 0
        for index in pieces.indices {
            sentence[index] = current
            if pieces[index].trail.contains(where: sentenceEnd.contains) { current += 1 }
        }
        var negated = Set<Int>()
        for index in pieces.indices where isNegation(pieces[index].core) { negated.insert(sentence[index]) }
        var index = 0
        while index < pieces.count {
            var matched = false
            for length in stride(from: 4, through: 1, by: -1) where !matched {
                let first = index..<(index + length)
                guard first.upperBound <= pieces.count, !negated.contains(sentence[index]),
                      first.allSatisfy({ !pieces[$0].deleted && ordinary(pieces[$0]) }),
                      first.dropLast().allSatisfy({ pieces[$0].trail.isEmpty }),
                      ["", ","].contains(pieces[first.upperBound - 1].trail) else { continue }
                var next = first.upperBound, marked = pieces[next - 1].trail == ","
                while next < pieces.count, pieces[next].isFiller || isDash(pieces[next]) {
                    if pieces[next].trail.contains(where: sentenceEnd.contains) { break }
                    marked = true; next += 1
                }
                let second = next..<(next + length)
                guard marked, second.upperBound <= pieces.count,
                      second.allSatisfy({ !pieces[$0].deleted && ordinary(pieces[$0]) && sentence[$0] == sentence[index] }),
                      second.dropLast().allSatisfy({ pieces[$0].trail.isEmpty }),
                      zip(first, second).allSatisfy({ pieces[$0.0].core == pieces[$0.1].core }) else { continue }
                for removed in index..<next { pieces[removed].deleted = true }
                index = next; matched = true
            }
            if !matched { index += 1 }
        }
        guard pieces.contains(where: \.deleted) else { return vocabulary.apply(text) }

        // A removed filler's pause or sentence end moves to the word before it
        // ("ship it, um." -> "ship it.", "no, um… Tuesday" -> "no… Tuesday") unless
        // that word already ends a sentence; its commas go with it.
        var lastKept: Int?
        for index in pieces.indices {
            if !pieces[index].deleted { lastKept = index; continue }
            guard pieces[index].isFiller, let kept = lastKept else { continue }
            let carried = String(pieces[index].trail.filter(pause.contains))
            let core = pieces[kept].core
            guard !carried.isEmpty, !pieces[kept].trail.contains(where: sentenceEnd.contains),
                  !core.isEmpty, core.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "'" || $0 == "\u{2019}" })
            else { continue }
            if pieces[kept].trail.hasSuffix(",") { pieces[kept].word.removeLast(); pieces[kept].trail.removeLast() }
            pieces[kept].word += carried; pieces[kept].trail += carried
        }
        // A comma left at the very end by a removed closing filler goes too.
        if let kept = lastKept, kept < pieces.count - 1, pieces[(kept + 1)...].allSatisfy(\.deleted),
           pieces[kept].trail.hasSuffix(","), pieces[kept].word.count > 1 {
            pieces[kept].word.removeLast()
        }
        // Nothing left but punctuation and dashes: the whole thing was filler.
        let content = pieces.filter { !$0.deleted }.contains { piece in
            !["\u{2014}", "\u{2013}"].contains(piece.word) && piece.word.contains { !".,;:!?\u{2026}\"\u{201c}\u{201d}'".contains($0) } }
        guard content else { return "" }

        // Rebuild: a removed word goes with the whitespace before it; the text's
        // opening whitespace stays at the front. (Text with line breaks is technical.)
        // "Okay. Um, the plan" -> "Okay. The plan": a Capitalised filler that opened a
        // sentence passes its capital to a common word after it, never to a command
        // or name ("Uh swift test").
        var result = "", started = false, capital = false, sentenceStart = true
        for piece in pieces {
            if piece.deleted {
                if piece.isFiller, sentenceStart, piece.core.first?.isUppercase == true { capital = true }
                continue
            }
            result += started ? piece.gap : pieces[0].gap
            if capital, capitalisable.contains(piece.core), let first = piece.word.first {
                result += first.uppercased() + piece.word.dropFirst()
            } else {
                result += piece.word
            }
            started = true; capital = false
            sentenceStart = piece.trail.contains(where: pause.contains)
        }
        result += tail
        return vocabulary.apply(result)
    }
    static let capitalisable: Set<String> = functionWords.union(["this", "these", "those", "there", "here", "hello",
        "hey", "hi", "okay", "ok", "yeah", "yes", "thanks", "please", "what", "when", "where", "why", "how", "let's",
        "maybe", "also", "well", "now", "first", "basically", "actually"])

    // Whether the AI pass could change anything the guard would accept: a filler,
    // a soft phrase word, or a word repeated close by. If not, the call is skipped
    // (measured 2026-10-13): most dictations land about 0.35 s sooner.
    public static func hasRemovable(_ text: String, takeBacks: [String] = []) -> Bool {
        let soft = Set(softPhrases.flatMap { $0 })
        var seen = Set<String>()
        if TakeBack.mentioned(in: tokens(text), phrases: takeBacks) { return true }
        for token in tokens(text) {
            if token.sentenceBefore { seen.removeAll() }
            if fillers.contains(token.word) || soft.contains(token.word) { return true }
            // Any ordinary word said twice in one sentence may be a stutter the guard accepts.
            if token.word.allSatisfy({ $0.isLetter || $0 == "'" }), !seen.insert(token.word).inserted { return true }
        }
        return false
    }

    public enum Verdict: Equatable, Sendable {
        case accepted
        case rejected(String)
    }
    // Fixed rejection codes: never built from transcript or model text, so they
    // are safe to log.
    public static let rejectionCodes: Set<String> = ["empty", "question answered", "too long",
                                                     "added words", "dropped words", "technical text"]
    // Longest input the aligner accepts (a 60-second dictation is about 250 words).
    public static let alignmentLimit = 600
    static let softPhrases: [[String]] = [["you", "know"], ["i", "mean"], ["like"], ["so"], ["actually"], ["basically"]]

    // The real control against a model answering, obeying or rewriting what was
    // said. The model may only remove words and fix punctuation and capitals; it
    // may never add or change a word. Every removed word must be one of:
    //   - a filler sound (um, uh),
    //   - "like", "so", "you know", "I mean" set off by commas as a filler,
    //   - a stutter: ordinary words repeating their neighbour.
    //   - a take-back: at most eight words, then one of the user's take-back
    //     phrases set off by a pause, then what they said instead (TakeBack).
    // Other self-corrections ("three, no, four") are kept: by shape alone they
    // can't be told from "Jordan, sorry, I'm late". Outside a take-back, digits,
    // signs and negations are never removed.
    // Anything else keeps the rule-cleaned text.
    // removeOnly: dotted and path words in a sentence count as prose (isCodeShaped); they keep their
    // bytes and may only gain trailing punctuation. Smart mode calls this without it.
    public static func judge(raw spoken: String, output: String, vocabulary: Vocabulary, removeOnly: Bool = false) -> Verdict {
        // Dictionary fixes are the user's own corrections, so judge against them applied.
        let raw = tokens(vocabulary.apply(spoken))
        let protected = removeOnly ? Set(raw.map(\.word).filter(isProtectedWord)) : []
        var out = tokens(output).map(\.word).map { word in
            guard !protected.isEmpty, !protected.contains(word) else { return word }
            let bare = strippedTrailing(word)
            return protected.contains(bare) ? bare : word
        }
        // A filename ending the sentence: its full stop is sentence punctuation, which may become a question mark.
        if let spokenLast = raw.last?.word, protected.contains(spokenLast), let last = out.last, last != spokenLast,
           strippedTrailing(spokenLast) != spokenLast, strippedTrailing(last) == strippedTrailing(spokenLast), strippedTrailing(last) != last {
            out[out.count - 1] = spokenLast
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Technical text is never rewritten, and prose never gains code characters.
        let rawTechnical = removeOnly ? isCodeShaped(vocabulary.apply(spoken)) : isTechnical(vocabulary.apply(spoken))
        if rawTechnical {
            return trimmed == vocabulary.apply(spoken).trimmingCharacters(in: .whitespacesAndNewlines)
                ? .accepted : .rejected("technical text")
        }
        let outputCode = removeOnly ? withoutProtected(output, protected) : output
        if isTechnical(outputCode) { return .rejected("added words") }
        guard raw.count <= alignmentLimit, out.count <= alignmentLimit else { return .rejected("too long") }
        if trimmed.isEmpty {
            return raw.allSatisfy { fillers.contains($0.word) } ? .accepted : .rejected("empty")
        }
        let rawText = vocabulary.apply(spoken)
        if rawText.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?"), !trimmed.hasSuffix("?") {
            return .rejected("question answered")
        }
        for gap in gaps(raw.map(\.word), out) {
            if !gap.inserted.isEmpty { return .rejected("added words") }
            if !removable(gap.deleted, in: raw, spoken: removeOnly),
               !TakeBack.isTakeBack(gap.deleted, in: raw, phrases: vocabulary.takeBacks) { return .rejected("dropped words") }
        }
        return .accepted
    }

    // Smart mode: the model may reword
    // to keep what the speaker meant, merging a correction into the sentence. It is still
    // refused when it does something no cleanup does:
    //   - answers or obeys the text (a question no longer a question, "Sure, here's…"),
    //   - comes back longer than what was said, or (over eight words) keeps under a quarter of it,
    //   - brings in more than two words the speaker never said (dictionary terms and small
    //     function words don't count), any number they didn't say, or a new "not"/"never".
    public static func judgeSmart(raw spoken: String, output: String, vocabulary: Vocabulary) -> Verdict {
        let said = vocabulary.apply(spoken), trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if isTechnical(said) {
            return trimmed == said.trimmingCharacters(in: .whitespacesAndNewlines) ? .accepted : .rejected("technical text")
        }
        // Prose punctuation (a semicolon, a dash) is fine; code characters the speaker didn't say are not.
        let code = Set("`$|&{}[]<>=\\/*#~^_")
        if trimmed.contains(where: { code.contains($0) && !said.contains($0) }) { return .rejected("added words") }
        let spokenTokens = tokens(said)
        let raw = spokenTokens.map(\.word), out = tokens(output.replacingOccurrences(of: ";", with: ",")).map(\.word)
        guard raw.count <= alignmentLimit, out.count <= alignmentLimit else { return .rejected("too long") }
        if said.contains("?"), !trimmed.contains("?") { return .rejected("question answered") }
        if hasProtectedNegation(spokenTokens, vocabulary: vocabulary)
            || out.contains(where: { isNegation($0) && $0 != "no" }) {
            let strict = judge(raw: spoken, output: output, vocabulary: vocabulary)
            if strict == .accepted { return strict }
            guard !trimmed.isEmpty else { return strict }
            return preservesWords(spokenTokens, output: out, terms: vocabulary.cleanupTerms, identities: vocabulary.terms, takeBacks: vocabulary.takeBacks) ? .accepted : strict
        }
        if trimmed.isEmpty {
            let removable = vocabulary.takeBacks.isEmpty
                ? preservesWords(spokenTokens, output: [], terms: vocabulary.cleanupTerms, identities: vocabulary.terms)
                : raw.allSatisfy { fillers.contains($0) }
            return removable ? .accepted : .rejected("empty")
        }
        if said.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?"), !trimmed.contains("?") {
            return .rejected("question answered")
        }
        let opener = out.prefix(2).joined(separator: " ")
        if ["sure", "certainly", "here's", "here is", "of course", "as an", "i can", "i'm sorry"].contains(where: { opener.hasPrefix($0) }),
           !raw.prefix(2).joined(separator: " ").hasPrefix(String(opener.prefix(4))) {
            return .rejected("question answered")
        }
        // Code-like words and symbols ("fooBar", "iOS", "x - y") come back exactly, never respelled or dropped.
        // ("5pm" is a value a correction may replace; "x-y", "fooBar" and "iOS" are not, though a Dictionary
        // term like "GitHub" or "CursusVox" may be dropped when the speaker takes it back.)
        let edge = CharacterSet(charactersIn: ".,;:!?\"\u{201c}\u{201d}()")
        func core(_ word: String) -> String { word.trimmingCharacters(in: edge) }
        let corrected = !vocabulary.takeBacks.isEmpty && (spokenTokens.enumerated().contains { index, token in
            index > 0 && correctionCues.contains(token.word) && (token.commaBefore || token.sentenceBefore)
        }
            || TakeBack.mentioned(in: tokens(said), phrases: vocabulary.takeBacks))
        let exactNames = Set(vocabulary.terms.flatMap { tokens($0).map { core($0.word) } })
        let exact = raw.map(core).filter { word in
            if corrected, exactNames.contains(word) { return false }
            return word.contains { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "\u{2019}" }
                || word.dropFirst().contains(where: \.isUppercase)
        }
        let outSet = Set(out.map(core))
        if exact.contains(where: { !outSet.contains($0) }) { return .rejected("dropped words") }
        if said.contains("?"), !trimmed.contains("?") { return .rejected("question answered") }
        if vocabulary.takeBacks.isEmpty || !corrected {
            let unchanged = vocabulary.takeBacks.isEmpty ? spokenTokens
                : tokens(rules(said, vocabulary: Vocabulary(terms: [])))
            let aligned = preservesWords(unchanged, output: out, terms: vocabulary.cleanupTerms, identities: vocabulary.terms)
                || (!vocabulary.takeBacks.isEmpty && unchanged.first?.word == "so"
                    && preservesWords(Array(unchanged.dropFirst()), output: out, terms: vocabulary.cleanupTerms, identities: vocabulary.terms))
            return aligned ? .accepted : .rejected("dropped words")
        }
        // With take-backs on, Smart may delete real words;
        // sound-alike Dictionary swaps of real words are allowed. The model judges from context.
        let content = raw.filter { !fillers.contains($0) }
        if out.count > raw.count + 2 { return .rejected("added words") }
        if corrected {
            if content.count > 8, out.count * 4 < content.count { return .rejected("dropped words") }
        } else if out.count * 10 < content.count * 6 { return .rejected("dropped words") }
        // A Dictionary name may come in only in place of words that sound like it ("Grog" → "Grok",
        // "curse this vox" → "CursusVox"); being in the Dictionary is not leave to add it.
        // A Dictionary name not spoken as such must replace its own misheard words: each inserted name
        // claims 1-3 neighbouring spoken words that are gone from the output and spelt close to it.
        // Occurrences are counted, so "Grog … Grog" → "Grog … Grok" works and one "Grog" never pays for two names.
        var left: [String: Int] = [:]
        for word in out { left[core(word).lowercased(), default: 0] += 1 }
        var dropped: [String?] = raw.map { word in
            let key = core(word).lowercased()
            if let n = left[key], n > 0 { left[key] = n - 1; return nil }
            return key
        }
        let names = Set(vocabulary.cleanupTerms.flatMap { tokens($0).map { core($0.word).lowercased() } })
        let knownIdentities = Set(vocabulary.terms.map { tokens($0).map { core($0.word).lowercased() }.joined(separator: " ") })
        let protectedNames = exactIdentityPositions(in: raw, identities: knownIdentities)
        // A name said once may appear once (any capitals); every further copy needs its own misheard words.
        var spokenTimes: [String: Int] = [:]
        // Whole words only: ".grok" or "grok/x" is a different token from the name, not a capital change.
        for word in raw { spokenTimes[word.lowercased(), default: 0] += 1 }
        for word in out {
            let key = word.lowercased()
            guard names.contains(key) else { continue }
            if let n = spokenTimes[key], n > 0 { spokenTimes[key] = n - 1; continue }
            guard let span = soundAlikeSpan(key, dropped: dropped) else { return .rejected("added words") }
            for index in span { dropped[index] = nil }
        }
        let known = Set(raw + functionWords)
        // Dictionary names are vetted above; a spoken one may also come back with its own capitals ("grok" → "Grok").
        let new = out.filter { !known.contains($0) && !names.contains($0.lowercased()) }
        if new.contains(where: { $0.contains(where: \.isNumber) }) { return .rejected("added words") }
        // A "not" never appears from nowhere, and one goes only when the speaker said "no" to take something back.
        let rawNegations = raw.filter(isNegation).count, outNegations = out.filter(isNegation).count
        if outNegations > rawNegations { return .rejected("added words") }
        if outNegations < rawNegations - raw.filter({ $0 == "no" }).count { return .rejected("dropped words") }
        if new.count > (corrected ? 2 : 0) { return .rejected("added words") }
        // Correction permission never allows participants or amounts to trade places.
        let ordinary = functionWords.union(fillers).union(correctionCues).filter { !isNegation($0) }
        var position = 0
        for word in out {
            let name = names.contains(word.lowercased())
            if ordinary.contains(word), !name { continue }
            var next = raw[position...].firstIndex(of: word).map { $0 + 1 }
            if name, word.count >= 3 {
                // Select with the ordered alignment, so an abandoned occurrence cannot claim this one.
                for start in position..<raw.count {
                    if let next, start >= next { break }
                    guard sameInitialSound(word, raw[start]) else { continue }
                    for end in (start + 1)...min(start + 3, raw.count) {
                        let span = Array(raw[start..<end])
                        guard !(start..<end).contains(where: { protectedNames.contains($0) })
                            || span.map({ $0.lowercased() }) == [word.lowercased()] else { continue }
                        guard dictionarySpanMayReplace(span, with: [word], known: knownIdentities) else { continue }
                        let saidName = span.joined().lowercased()
                        if editDistance(saidName, word.lowercased()) * 2 <= word.count {
                            next = min(next ?? end, end)
                        }
                    }
                }
            }
            if let next { position = next; continue }
            if !raw.contains(word), new.contains(word) { continue }
            return .rejected("dropped words")
        }
        return .accepted
    }
    // OFF preserves word order. Each step keeps a word, removes a contextual
    // filler or repeated twin, or replaces one whole Dictionary sound-alike.
    private static func preservesWords(_ raw: [Token], output: [String], terms: [String], identities: [String] = [], takeBacks: [String] = []) -> Bool {
        let soft = softPhrases + ["wait", "instead", "sorry", "rather", "meant"].map { [$0] }
        let names = terms.map { (term: $0, words: tokens($0).map(\.word)) }
        let knownNames = Set((terms + identities).map { tokens($0).map { $0.word.lowercased() }.joined(separator: " ") })
        let words = raw.map(\.word)
        let protectedNames = exactIdentityPositions(in: words, identities: knownNames)
        // A filler between twins does not interrupt a stutter. Sentence breaks do.
        let repeatPositions = raw.indices.filter {
            !fillers.contains(raw[$0].word) || raw[$0].sentenceBefore || raw[$0].sentenceAfter
        }
        let repeatTokens = repeatPositions.map { raw[$0] }
        let repeatStarts = Dictionary(uniqueKeysWithValues: repeatPositions.enumerated().map { ($0.element, $0.offset) })
        let fillerEnds = raw.indices.map { start in
            ((start + 1)...min(start + 2, raw.count)).filter {
                removable(start..<$0, in: raw, soft: soft, repeats: false)
            }
        }
        var reachable = Array(repeating: Array(repeating: false, count: output.count + 1), count: raw.count + 1)
        reachable[0][0] = true
        func matches(_ sequence: [String], at start: Int) -> Bool {
            start >= 0 && start + sequence.count <= output.count
                && output[start..<(start + sequence.count)].elementsEqual(sequence) { $0 == $1 || isAcronym($0, of: $1) }
        }
        for start in raw.indices {
            // Fillers inside a sound-alike do not count as name syllables. The
            // remaining 1-3 words must all be claimed by soundAlikeSpan.
            var replacements: [(end: Int, words: [String])] = []
            var dropped: [String?] = [], end = start
            while end < raw.count, dropped.count < 3 {
                if let fillerEnd = fillerEnds[end].last { end = fillerEnd; continue }
                dropped.append(words[end]); end += 1
                for name in names where !name.words.isEmpty && sameInitialSound(name.term.lowercased(), dropped[0] ?? "") {
                    if name.term.count >= 3,
                       (!(start..<end).contains(where: { protectedNames.contains($0) })
                            || dropped.compactMap({ $0?.lowercased() }) == name.words.map({ $0.lowercased() })),
                       dictionarySpanMayReplace(dropped.compactMap { $0 }, with: name.words, known: knownNames),
                       editDistance(dropped.compactMap { $0 }.joined(), name.term.lowercased()) * 2 <= name.term.count {
                        replacements.append((end, name.words))
                    }
                }
            }
            let takeBackEnds: [Int]
            if !takeBacks.isEmpty, start + 1 < raw.count {
                let limit = min(start + TakeBack.maxSentence + TakeBack.maxPhraseWords + 4, raw.count - 1)
                takeBackEnds = ((start + 1)...limit).filter { TakeBack.isTakeBack(start..<$0, in: raw, phrases: takeBacks) }
            } else { takeBackEnds = [] }
            var repeats: [(end: Int, twins: [[String]])] = []
            if let first = repeatStarts[start] {
                for end in (first + 1)...min(first + 4, repeatTokens.count) where isRepeat(first..<end, in: repeatTokens) {
                    let repeated = repeatTokens[first..<end].map(\.word)
                    let dropped = repeated.map { Optional($0) }
                    let twins = [repeated] + names.filter {
                        dictionarySpanMayReplace(repeated, with: $0.words, known: knownNames)
                            && soundAlikeSpan($0.term, dropped: dropped) == 0..<repeated.count
                    }.map(\.words)
                    repeats.append((repeatPositions[end - 1] + 1, twins))
                }
            }
            for position in 0...output.count where reachable[start][position] {
                if matches([words[start]], at: position) { reachable[start + 1][position + 1] = true }
                for end in fillerEnds[start] + takeBackEnds { reachable[end][position] = true }
                // At least one twin must survive in the output.
                for repeated in repeats where repeated.twins.contains(where: {
                    matches($0, at: position) || matches($0, at: position - $0.count)
                }) {
                    reachable[repeated.end][position] = true
                }
                for replacement in replacements where matches(replacement.words, at: position) {
                    reachable[replacement.end][position + replacement.words.count] = true
                }
            }
        }
        return reachable[raw.count][output.count]
    }
    private static func hasProtectedNegation(_ raw: [Token], vocabulary: Vocabulary) -> Bool {
        let values: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "today", "tomorrow", "yesterday", "tonight", "january", "february", "march", "april", "may", "june",
            "july", "august", "september", "october", "november", "december"]
        let names = Set(vocabulary.cleanupTerms.map { $0.lowercased() })
        func value(_ word: String) -> Bool { word.contains(where: \.isNumber) || values.contains(word.lowercased()) || names.contains(word.lowercased()) }
        let openers = correctionCues.union(functionWords).union(fillers).union(["well", "oh", "okay", "please"])
        let strongPhrases = vocabulary.takeBacks.map(TakeBack.words).filter { $0.count > 1 }
        var markedNos = Set<Int>()
        for phrase in strongPhrases where phrase.count < raw.count {
            for start in 1...(raw.count - phrase.count) where raw[start].commaBefore || raw[start].sentenceBefore {
                let span = start..<(start + phrase.count)
                if raw[span].map(\.word) == phrase {
                    for index in span where raw[index].word == "no" { markedNos.insert(index) }
                }
            }
        }
        for index in raw.indices where isNegation(raw[index].word) {
            guard raw[index].word == "no" else { return true }
            if markedNos.contains(index) { continue }
            guard index > 0, index + 1 < raw.count else { return true }
            let previous = raw[index - 1].word
            let marked = raw[index].commaBefore && !openers.contains(previous)
                && (raw[index].commaAfter || (value(previous) && value(raw[index + 1].word)))
            let actually = index > 1 && previous == "actually" && raw[index - 1].commaBefore
                && value(raw[index - 2].word) && value(raw[index + 1].word)
            if !marked && !actually { return true }
        }
        return false
    }
    private static func dictionarySpanMayReplace(_ source: [String], with target: [String], known: Set<String>) -> Bool {
        let source = source.map { $0.lowercased() }, target = target.map { $0.lowercased() }
        let targetWords = Set(target)
        // A recognition hint cannot rename another exact Dictionary identity or absorb words after an exact term.
        if source.contains(where: { known.contains($0) && !targetWords.contains($0) }) { return false }
        for identity in known where identity.contains(" ") {
            let words = identity.split(separator: " ").map(String.init)
            if words == target || words.count > source.count { continue }
            if (0...(source.count - words.count)).contains(where: { source[$0..<($0 + words.count)].elementsEqual(words) }) { return false }
        }
        if source.contains(where: isNegation) || target.contains(where: isNegation) { return false }
        // A longer name span must improve the match; an equally good shorter span leaves following content intact.
        let joinedTarget = target.joined(), fullDistance = editDistance(source.joined(), target.joined())
        if source.count > 1 {
            for count in 1..<source.count {
                let prefix = source.prefix(count).joined()
                let distance = editDistance(prefix, joinedTarget)
                if sameInitialSound(prefix, joinedTarget), distance * 2 <= joinedTarget.count,
                   distance <= fullDistance { return false }
            }
        }
        if source.count > target.count, !target.isEmpty,
           (0...(source.count - target.count)).contains(where: { source[$0..<($0 + target.count)].elementsEqual(target) }) { return false }
        return true
    }
    private static func exactIdentityPositions(in input: [String], identities: Set<String>) -> Set<Int> {
        let input = input.map { $0.lowercased() }
        var positions = Set<Int>()
        for identity in identities {
            let words = identity.split(separator: " ").map(String.init)
            guard !words.isEmpty, words.count <= input.count else { continue }
            for start in 0...(input.count - words.count) where input[start..<(start + words.count)].elementsEqual(words) {
                positions.formUnion(start..<(start + words.count))
            }
        }
        return positions
    }
    // Phonetic initial equivalence so "coa" -> "Koa", "kaddy" -> "Caddy", "fantom" -> "Phantom", "ex code" -> "Xcode" match.
    static func sameInitialSound(_ a: String, _ b: String) -> Bool {
        let a = a.lowercased(), b = b.lowercased()
        guard let fa = a.first, let fb = b.first else { return false }
        if fa == fb { return true }
        func phoneticInitial(_ s: String) -> Character {
            if s.hasPrefix("ph") { return "f" }
            if s.hasPrefix("kn") || s.hasPrefix("gn") { return "n" }
            if s.hasPrefix("wr") { return "r" }
            if s.hasPrefix("wh") { return "w" }
            if s.hasPrefix("ex") || s.hasPrefix("x") { return "x" }
            switch s.first! {
            case "c", "k", "q": return "k"
            case "s", "z": return "s"
            case "g", "j": return "j"
            default: return s.first!
            }
        }
        return phoneticInitial(a) == phoneticInitial(b)
    }
    // The first 1 to 3 neighbouring spoken words, all gone from the output, spelt close to the term.
    static func soundAlikeSpan(_ term: String, dropped: [String?]) -> Range<Int>? {
        let term = term.lowercased()
        guard term.count >= 3 else { return nil }
        for start in dropped.indices {
            var joined = ""
            for end in start..<min(start + 3, dropped.count) {
                guard let word = dropped[end] else { break }
                joined += word.lowercased()
                if sameInitialSound(joined, term), editDistance(joined, term) * 2 <= term.count { return start..<(end + 1) }
            }
        }
        return nil
    }
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var previous = row[0]; row[0] = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return a.isEmpty ? b.count : row[b.count]
    }
    // A spoken plain word written as an acronym ("ai" → "AI", "nasa" → "NASA"). Short everyday words stay as
    // spoken ("us" never becomes "US"), and technical tokens like "k8s" must come back exactly.
    static let acronymExclusions: Set<String> = ["us", "it", "me", "we", "or", "so", "no", "an", "as", "at", "be", "by", "do",
                                                 "go", "he", "if", "in", "is", "my", "of", "on", "to", "up", "ok", "hi", "am"]
    static func isAcronym(_ written: String, of spoken: String) -> Bool {
        (2...6).contains(spoken.count) && spoken.allSatisfy({ $0.isLetter && $0.isLowercase })
            && written == spoken.uppercased() && !acronymExclusions.contains(spoken)
    }
    // Words that show the speaker corrected themselves, which is what lets Smart reword.
    static let correctionCues: Set<String> = ["no", "wait", "mean", "meant", "actually", "sorry", "rather", "scratch",
                                              "instead", "oops", "correction", "rephrase"]
    // A word as spoken, with the punctuation either side of it in the transcript.
    struct Token: Equatable {
        let word: String
        let commaBefore: Bool    // a comma or dash right before it
        let commaAfter: Bool     // a comma or dash right after it
        let sentenceBefore: Bool // the start of a sentence (or of the text)
        let sentenceAfter: Bool  // the end of a sentence (or of the text)
    }
    // Words as written between spaces, so URLs, identifiers, symbols and numbers
    // stay whole ("https://x.com", "123abc", "¥25", "1,000", ".env", "--"); only
    // punctuation at a word's outer edges is stripped and remembered as pauses.
    static func tokens(_ text: String) -> [Token] {
        let normal = text
        // Prose punctuation only; brackets and braces are code and stay in the word.
        let leading = Set("(\"\u{201c}")
        let trailing = Set(".,;:!?)\"\u{201d}\u{2026}")
        let dashes = Set("\u{2014}\u{2013}-")
        struct Chunk { var word: String; var before: String; var after: String }
        var chunks: [Chunk] = []
        var pending = ""   // punctuation seen since the last word (lone dashes, quotes)
        for raw in normal.split(whereSeparator: \.isWhitespace).map(String.init) {
            var word = Substring(raw)
            var before = "", after = ""
            while let first = word.first, leading.contains(first) { before.append(first); word.removeFirst() }
            while let last = word.last, trailing.contains(last) { after.insert(last, at: after.startIndex); word.removeLast() }
            // A lone long dash, comma, full stop or ellipsis is a pause; any other symbol
            // ("-" as in "x - y", "!", "--", "!=", "[", "()") is a word that must come back exactly.
            if word.isEmpty && raw.allSatisfy({ ",.\u{2026}\"\u{201c}\u{201d}".contains($0) })
                || word.count == 1 && word.allSatisfy(dashes.contains) && raw != "-" {
                pending += raw; continue
            }
            // Ordinary words may change case and surrounding punctuation. Anything
            // else (URLs, code, identifiers, symbols) must come back exactly.
            // An empty remainder ("()") is a symbol, not a plain word.
            let plain = !word.isEmpty && (word.allSatisfy { $0.isLetter || $0 == "'" || $0 == "\u{2019}" }
                || word.allSatisfy(\.isNumber))
            // Plain words compare case- and apostrophe-insensitively; technical ones
            // exactly as written. Surrounding punctuation still marks pauses ("Send $5.").
            // Only a lowercase or Capitalised word may change case; "iOS", "fooBar",
            // "NASA" must come back exactly as spelled.
            let caseFree = word.dropFirst().allSatisfy { !$0.isUppercase }
            let apostrophes = word.replacingOccurrences(of: "\u{2019}", with: "'")
            word = !plain ? Substring(raw) : caseFree ? Substring(apostrophes.lowercased()) : Substring(apostrophes)
            // Punctuation between two words counts as a pause on both sides of it.
            if !chunks.isEmpty { chunks[chunks.count - 1].after += pending } else { before = pending + before }
            pending = ""
            chunks.append(Chunk(word: String(word), before: before, after: after))
        }
        if !chunks.isEmpty { chunks[chunks.count - 1].after += pending }
        func comma(_ gap: String) -> Bool { gap.contains(where: { ",\u{2014}\u{2013}-".contains($0) }) }
        func stop(_ gap: String) -> Bool { gap.contains(where: { ".!?;:\u{2026}".contains($0) }) }
        return chunks.enumerated().map { position, chunk in
            let before = position == 0 ? chunk.before : chunks[position - 1].after + chunk.before
            let after = position + 1 < chunks.count ? chunk.after + chunks[position + 1].before : chunk.after
            return Token(word: chunk.word, commaBefore: comma(before), commaAfter: comma(after),
                         sentenceBefore: position == 0 || stop(before),
                         sentenceAfter: position + 1 == chunks.count || stop(after))
        }
    }

    // One run of differences between two aligned (matching) words.
    struct Gap { let deleted: Range<Int>; let inserted: [String] }

    // Soft fillers in text with no commas, which is how speech usually arrives. The neighbouring
    // words decide: "tell me like how many" loses "like"; "I like you" and "I mean it" never do.
    private static func spokenFiller(_ phrase: [String], at index: Int, in raw: [Token]) -> Bool {
        let previous = index > 0 ? raw[index - 1].word : nil
        let after = index + phrase.count
        let next = after < raw.count ? raw[after].word : nil
        let ending = after == raw.count || raw[after - 1].sentenceAfter
        let starting = raw[index].sentenceBefore || previous.map(openers.contains) == true
        switch phrase {
        case ["like"]:
            if let previous, likeKeepsAfter.contains(previous) { return false }
            return next.map { !likeKeepsBefore.contains($0) } ?? false
        case ["so"]: return starting && next.map { !soKeepsBefore.contains($0) } ?? false
        case ["i", "mean"]: return starting && next.map { !meanKeepsBefore.contains($0) } ?? false
        case ["you", "know"]:
            if let previous, knowKeepsAfter.contains(previous) { return false }
            return ending || (starting && next.map { !knowKeepsBefore.contains($0) } ?? false)
        case ["actually"], ["basically"]: return starting
        default: return false
        }
    }
    private static let openers: Set<String> = ["okay", "ok", "yeah", "right", "well", "so", "like", "hey", "basically", "actually"]
    private static let likeKeepsAfter: Set<String> = ["i'd", "we'd", "you'd", "they'd", "he'd", "she'd", "kids", "i'm", "we're", "you're", "they're", "was", "were", "it's", "that's", "he's", "she's", "i", "we", "you", "they", "he", "she", "it", "who", "people", "would", "could", "should", "might", "do", "does", "did", "don't", "doesn't", "didn't", "not", "really", "also", "just", "still", "look", "looks", "looked", "looking", "sound", "sounds", "sounded", "seem", "seems", "seemed", "feel", "feels", "felt", "something", "anything", "nothing", "stuff", "things", "more", "much", "to", "very"]
    private static let likeKeepsBefore: Set<String> = ["a", "an", "the", "this", "that", "these", "those", "it", "me", "you", "him", "her", "us", "them", "my", "your", "our", "their"]
    private static let soKeepsBefore: Set<String> = ["do", "does", "did", "am", "is", "are", "was", "were", "have", "has", "had", "can", "could", "will", "would", "should", "too", "far", "much", "many", "long", "good", "that", "what", "little", "few", "bad", "great"]
    private static let meanKeepsBefore: Set<String> = ["it", "that", "this", "what", "to", "business", "well", "you", "is"]
    private static let knowKeepsAfter: Set<String> = ["think", "guess", "bet", "hope", "someone", "something", "anyone", "everyone", "nobody", "people", "whether", "do", "does", "did", "don't", "doesn't", "didn't", "what", "if", "how", "who", "as", "when", "would", "should", "could", "will", "let", "now", "because"]
    private static let knowKeepsBefore: Set<String> = ["nothing", "everything", "something", "anything", "everyone", "nobody", "too", "what", "the", "that", "this", "how", "who", "where", "why", "when", "him", "her", "me", "it", "about", "them", "us", "a", "an"]

    private static func removable(_ run: Range<Int>, in raw: [Token], soft: [[String]] = softPhrases,
                                  repeats: Bool = true, spoken: Bool = false) -> Bool {
        if run.isEmpty { return true }
        if repeats && isRepeat(run, in: raw, spoken: spoken) { return true }
        var index = run.lowerBound
        while index < run.upperBound {
            let token = raw[index]
            if fillers.contains(token.word) { index += 1; continue }
            // A soft filler counts only where commas set it off: "So, like, I" not "I like it".
            if let phrase = soft.first(where: { phrase in
                index + phrase.count <= run.upperBound && raw[index..<(index + phrase.count)].map(\.word) == phrase }) {
                let first = raw[index], last = raw[index + phrase.count - 1]
                if last.commaAfter && (first.commaBefore || first.sentenceBefore) { index += phrase.count; continue }
                if spoken, spokenFiller(phrase, at: index, in: raw) { index += phrase.count; continue }
            }
            return false
        }
        return true
    }
    static let functionWords: Set<String> = ["the", "a", "an", "i", "we", "you", "he", "she", "they", "it", "to",
        "and", "but", "or", "so", "of", "in", "on", "at", "for", "with", "is", "was", "are", "be", "that", "this",
        "my", "our", "your", "if", "then", "just", "can", "will", "would", "i'm", "it's"]
    // Text that reads as code, a command, a path or a quotation rather than prose:
    // a line break or tab, a code character, a quote mark (not an apostrophe inside
    // a word), a standalone symbol ("!", "--"), a dotted name or number ("readme.md",
    // ".env", "3.5", "../config") or a flag ("-x"). Cleanup leaves it exactly as spoken.
    // The remove-only rule: like isTechnical, except a filename or path inside a sentence is prose.
    // Quotes, brackets, flags, URLs and line breaks stay code, are never sent and are left as spoken.
    public static func isCodeShaped(_ text: String) -> Bool {
        guard isTechnical(text) else { return false }
        if text.contains(where: { $0.isNewline || $0 == "\t" }) || text.contains("://") { return true }
        return isTechnical(withoutProtected(text, nil))
    }
    private static func strippedTrailing(_ word: String) -> String {
        var bare = Substring(word)
        while let last = bare.last, ".,:!?".contains(last) { bare.removeLast() }
        return String(bare)
    }
    // "README.md?", ".env", "5.5", "src/App.swift", "/tmp/build.", "and/or".
    static func isProtectedWord(_ word: String) -> Bool {
        let bare = strippedTrailing(word)
        guard !bare.contains("://"), !bare.hasPrefix("-") else { return false }
        let dotted = /^\.?[\w-]+(\.[\w-]+)*$/, path = /^[~.]?\/?[\w.-]+(\/[\w.-]+)+\/?$/
        return (bare.contains(".") && bare.wholeMatch(of: dotted) != nil) || bare.wholeMatch(of: path) != nil
    }
    // nil: every protected-looking word. A set: only the input's own, with allowed trailing punctuation.
    private static func withoutProtected(_ text: String, _ only: Set<String>?) -> String {
        guard !text.contains(where: \.isNewline) else { return text }
        return text.split(whereSeparator: \.isWhitespace).map(String.init).filter { word in
            guard let only else { return !isProtectedWord(word) }
            return !only.contains { strippedTrailing($0) == strippedTrailing(word) }
        }.joined(separator: " ")
    }
    public static func isTechnical(_ text: String) -> Bool {
        if text.contains(where: { $0.isNewline || "\t`$|&{}[]<>=\\/*#~^_;\"\u{201c}\u{201d}()".contains($0) }) { return true }
        let proseSentence = text.first(where: { !$0.isWhitespace })?.isUppercase == true
            && text.trimmingCharacters(in: .whitespacesAndNewlines).last.map { ".!?".contains($0) } == true
            && text.split(whereSeparator: \.isWhitespace).count >= 4
        for piece in text.split(whereSeparator: \.isWhitespace) {
            let word = Array(piece)
            for (index, c) in word.enumerated() where "'\u{2018}\u{2019}".contains(c) {
                let inside = index > 0 && index < word.count - 1 && word[index - 1].isLetter && word[index + 1].isLetter
                let pluralPossessive = proseSentence && index > 1 && word[index - 1].lowercased() == "s"
                    && word[..<index].allSatisfy(\.isLetter)
                    && word[(index + 1)...].allSatisfy { ",.!?:;".contains($0) }
                if !inside && !pluralPossessive { return true }
            }
            if !word.contains(where: { $0.isLetter || $0.isNumber }),
               !(word.allSatisfy { ",.\u{2026}".contains($0) } || ["-", "\u{2014}", "\u{2013}"].contains(String(piece))) { return true }
            for index in word.indices.dropFirst().dropLast() where word[index] == "."
                && (word[index - 1].isLetter || word[index - 1].isNumber)
                && (word[index + 1].isLetter || word[index + 1].isNumber) { return true }
            let dots = word.prefix { $0 == "." }.count
            if (1...2).contains(dots), dots < word.count, word[dots].isLetter || word[dots].isNumber { return true }
            if word.first == "-", word.count > 1, word[1].isLetter || word[1] == "-" { return true }
        }
        return false
    }
    static func isNegation(_ word: String) -> Bool {
        // A dash glued on doesn't hide it either: "not—ever", "Don't—".
        let parts = word.split(whereSeparator: { "\u{2014}\u{2013}-".contains($0) })
        if parts.count > 1 || parts.first.map({ $0.count != word.count }) == true {
            return parts.contains { isNegation(String($0)) }
        }
        // Quotes or brackets around it don't change what it means: "Do 'not' go", "[not]".
        let word = word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\u{2018}\"\u{201c}\u{201d}[]{}()"))
        return ["not", "no", "never", "nothing", "none", "nobody", "neither", "nor", "cannot"].contains(word)
            || word.hasSuffix("n't")
    }
    // "the the" or "I want to, I want to": ordinary words repeating their neighbour.
    private static func isRepeat(_ run: Range<Int>, in raw: [Token], spoken: Bool = false) -> Bool {
        let length = run.count
        let words = raw[run].map(\.word)
        // Only ordinary words stutter: numbers, file names and flags repeat for real.
        guard length > 0, words.allSatisfy({ $0.allSatisfy { $0.isLetter || $0 == "'" } }),
              !words.contains(where: isNegation) else { return false }
        // Never inside a sentence that negates: "Do not go, go away."
        var first = run.lowerBound, last = run.upperBound - 1
        while first > 0, !raw[first].sentenceBefore { first -= 1 }
        while last < raw.count - 1, !raw[last].sentenceAfter { last += 1 }
        let small = words.allSatisfy(functionWords.contains)
        // Spoken "the the the" is a stutter even in a sentence with a "nobody" further along.
        let sameSmallWord = spoken && small && Set(words).count == 1
            && (run.upperBound < raw.count && raw[run.upperBound].word == words[0] || run.lowerBound > 0 && raw[run.lowerBound - 1].word == words[0])
        guard sameSmallWord || !raw[first...last].contains(where: { isNegation($0.word) }) else { return false }
        // A bare repeat ("diff Makefile Makefile") may be meant: unless the words are
        // small, a comma or dash must sit between the removed run and its twin.
        // The run and its twin must be in one sentence: "I will. I will." is two.
        func oneSentence(_ span: ClosedRange<Int>) -> Bool {
            span.lowerBound >= span.upperBound || !raw[span.lowerBound..<span.upperBound].contains(where: \.sentenceAfter)
        }
        func repeats(_ twin: Range<Int>, separatedAt boundary: Int) -> Bool {
            guard twin.lowerBound >= 0, twin.upperBound <= raw.count,
                  raw[twin].map(\.word) == words,
                  oneSentence(min(run.lowerBound, twin.lowerBound)...(max(run.upperBound, twin.upperBound) - 1))
            else { return false }
            return small || raw[boundary].commaAfter
        }
        // The kept twin after the run (boundary: the run's last word) or before it.
        if repeats(run.upperBound..<(run.upperBound + length), separatedAt: run.upperBound - 1) { return true }
        if run.lowerBound >= length, repeats((run.lowerBound - length)..<run.lowerBound, separatedAt: run.lowerBound - 1) {
            return true
        }
        // "the the the" -> "the": every removed word equals the kept neighbour.
        if small, Set(words).count == 1 {
            if run.upperBound < raw.count, raw[run.upperBound].word == words[0],
               oneSentence(run.lowerBound...run.upperBound) { return true }
            if run.lowerBound > 0, raw[run.lowerBound - 1].word == words[0],
               oneSentence((run.lowerBound - 1)...(run.upperBound - 1)) { return true }
        }
        return false
    }

    // Aligns the two word lists (longest common subsequence, bounded by
    // alignmentLimit) and returns the runs between matching words.
    static func gaps(_ a: [String], _ b: [String]) -> [Gap] {
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [Gap] = [], i = 0, j = 0, start = 0, inserted: [String] = []
        func close() {
            if start < i || !inserted.isEmpty { result.append(Gap(deleted: start..<i, inserted: inserted)) }
            inserted = []
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] { close(); i += 1; j += 1; start = i }
            else if j >= b.count || (i < a.count && table[i + 1][j] >= table[i][j + 1]) { i += 1 }
            else { inserted.append(b[j]); j += 1 }
        }
        close()
        return result
    }
}
