import Foundation

// Phrases a speaker uses to take back what they just said: "book it for Friday,
// no I mean Saturday". The AI may drop the taken-back words and the phrase; the
// guard in TranscriptCleanup.judge checks it dropped nothing else. The user edits
// the list, including how a phrase gets misheard ("no weight" for "no wait").
public enum TakeBack {
    public static let defaults = ["no I mean", "I meant", "scratch that", "no wait", "or rather", "sorry I mean", "no no"]
    // Offered with one click. Not on by default: "I sent it, oops, I forgot the file" isn't a take-back.
    public static let suggested = ["oops", "actually no", "let me rephrase", "correction", "my bad"]
    public static let maxPhrases = 30
    public static let maxPhraseWords = 4
    // The most words one take-back may drop before its phrase: a few words, or
    // one whole sentence when the phrase starts the next one ("…for Friday. No wait.").
    public static let maxDropped = 8
    public static let maxSentence = 25

    // One phrase per line (commas also split). Lines that are empty, too long or
    // contain anything but words are skipped; duplicates are dropped.
    public static func parse(_ text: String) -> [String] {
        var seen = Set<String>(), kept: [String] = []
        for line in text.split(whereSeparator: { $0.isNewline || $0 == "," }) where kept.count < maxPhrases {
            let phrase = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let key = words(phrase)
            guard !key.isEmpty, key.count <= maxPhraseWords,
                  key.allSatisfy({ $0.allSatisfy { $0.isLetter || $0 == "'" } }),
                  seen.insert(key.joined(separator: " ")).inserted else { continue }
            kept.append(phrase)
        }
        return kept
    }

    // A phrase as the guard compares it: lower-case words, punctuation stripped.
    static func words(_ phrase: String) -> [String] {
        phrase.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { $0.isWhitespace || ",.!?;:…—–".contains($0) }).map(String.init)
    }

    public static func mentioned(_ text: String, phrases: [String]) -> Bool {
        mentioned(in: TranscriptCleanup.tokens(text), phrases: phrases)
    }
    // A one-word phrase ("oops") is weak evidence, so it may take back only a couple of words.
    public static let maxDroppedForOneWord = 2

    // Does the text say one of the phrases? Then the AI pass has something to do.
    static func mentioned(in raw: [TranscriptCleanup.Token], phrases: [String], deleting: Range<Int>? = nil) -> Bool {
        let spoken = raw.map(\.word)
        return phrases.map(words).contains { phrase in
            !phrase.isEmpty && spoken.count >= phrase.count
                && (0...(spoken.count - phrase.count)).contains { start in
                    let range = start..<(start + phrase.count)
                    return (deleting.map { $0.overlaps(range) } ?? true) && Array(spoken[range]) == phrase
                }
        }
    }

    // A deleted run the guard may accept: up to eight words, then a take-back
    // phrase set off by a pause, then something said instead. The dropped words
    // stay inside one sentence, apart from the stop right before the phrase
    // ("Friday? No, I mean Saturday."). The aligner may keep the first copy of
    // repeated words ("send it to Tessah, scratch that, send it to Sam" keeps the
    // first "send it to"); the same edit read with the second copy kept is tried too.
    static func isTakeBack(_ run: Range<Int>, in raw: [TranscriptCleanup.Token], phrases: [String]) -> Bool {
        let spoken = raw.map(\.word)
        for shift in 0...min(run.lowerBound, maxSentence) {
            let moved = (run.lowerBound - shift)..<(run.upperBound - shift)
            guard spoken[moved.lowerBound..<run.lowerBound] == spoken[moved.upperBound..<run.upperBound] else { continue }
            if fits(moved, raw: raw, spoken: spoken, phrases: phrases) { return true }
        }
        return false
    }

    private static func fits(_ run: Range<Int>, raw: [TranscriptCleanup.Token], spoken: [String],
                             phrases: [String]) -> Bool {
        guard run.upperBound < raw.count else { return false }   // nothing said instead
        for phrase in phrases.map(words) where !phrase.isEmpty && run.count > phrase.count {
            // "No wait, wait, wait" / "no, no, no": stuttered repeats of the phrase's last word,
            // each set off by a pause, go with it. "no wait, wait till Monday" keeps "wait".
            var end = run.upperBound
            while end - run.lowerBound > phrase.count, Array(spoken[(end - phrase.count)..<end]) != phrase,
                  spoken[end - 1] == phrase.last, raw[end - 1].commaBefore,
                  raw[end - 1].commaAfter || raw[end - 1].sentenceAfter { end -= 1 }
            let start = end - phrase.count
            guard start > run.lowerBound, Array(spoken[start..<end]) == phrase,
                  raw[start].commaBefore || raw[start].sentenceBefore else { continue }
            // The phrase itself stays inside one sentence ("Book Friday, no. Wait for…" is not "no wait").
            if raw[start..<(end - 1)].contains(where: \.sentenceAfter) { continue }
            // The dropped words stay in one sentence, apart from the stop right before the phrase.
            if raw[run.lowerBound..<(start - 1)].contains(where: \.sentenceAfter) { continue }
            // A whole sentence goes only when the phrase stands alone ("No wait. How about…"),
            // never for "I meant to thank you" starting a sentence.
            // Standing alone: a pause after the phrase, or inside it ("No, I mean Saturday").
            let pauseAfter = raw[end - 1].commaAfter || raw[end - 1].sentenceAfter
                || raw[start..<(end - 1)].contains(where: \.commaAfter)
            let wholeSentence = raw[run.lowerBound].sentenceBefore && raw[start - 1].sentenceAfter && pauseAfter
            // Dropping a whole sentence needs the phrase to stand alone: "I meant to thank you"
            // never takes back the sentence before it; "Friday? No, I mean Saturday" drops just "Friday".
            if raw[run.lowerBound].sentenceBefore && raw[start - 1].sentenceAfter && !wholeSentence { continue }
            let limit = phrase.count == 1 ? maxDroppedForOneWord : wholeSentence ? maxSentence : maxDropped
            if start - run.lowerBound <= limit { return true }
        }
        return false
    }
}
