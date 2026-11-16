import Testing
import Foundation
@testable import CursusCore

// Opt-in property checks over random dictation (CURSUS_FUZZ=1): the rule pass and the
// guard may only remove fillers, marked stutters, soft phrases and corrections.
@Test func fuzzRulesOnlyRemoveFillersAndStutters() {
    guard ProcessInfo.processInfo.environment["CURSUS_FUZZ"] != nil else { return }
    var rng = SystemRandomNumberGenerator()
    let pool = ["um", "Um", "uh", "the", "I", "want", "to", "not", "go", ".env", ".5", "../config", "()", "fooBar", "no",
                "sorry", "Monday", "Tuesday", "1", "2", "'not'", "don't", "a", "hmm", "HMM", "so", "like", "readme.md", "!=", "--"]
    let seps = [" ", ", ", ". ", "... ", "… ", "? ", "; ", " - ", " — ", "\n", "\n    "]
    let prose = CharacterSet(charactersIn: ".,;:!?…\"“”'")
    func toks(_ s: String) -> [String] {
        s.split(whereSeparator: \.isWhitespace).map { String($0).trimmingCharacters(in: prose).lowercased() }.filter { !$0.isEmpty && $0 != "—" }
    }
    let v = Vocabulary(terms: [])
    var bad = 0
    for _ in 0..<30000 {
        var s = ""
        for i in 0..<Int.random(in: 1...9, using: &rng) {
            if i > 0 { s += seps.randomElement(using: &rng)! }
            s += pool.randomElement(using: &rng)!
        }
        if Bool.random(using: &rng) { s += "." }
        let out = TranscriptCleanup.rules(s, vocabulary: v)
        if TranscriptCleanup.isTechnical(s) {
            if out != s { bad += 1; if bad <= 25 { print("FUZZ IN: \(s)\nFUZZ OUT: \(out)") } }
            continue
        }
        let a = toks(s), b = toks(out)
        // b must be a subsequence of a; every skipped token must be a filler or equal a neighbour.
        var i = 0, ok = true, removed: [Int] = []
        for t in b {
            while i < a.count && a[i] != t { removed.append(i); i += 1 }
            if i == a.count { ok = false; break }
            i += 1
        }
        while i < a.count { removed.append(i); i += 1 }
        let fillers: Set<String> = ["um", "uh", "hmm", "umm", "uhh", "erm"]
        for r in removed where ok {
            let w = a[r]
            if fillers.contains(w) { continue }
            // Only ordinary words stutter: a removed minus or symbol is never a repeat.
            guard w.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "\u{2019}" }) else { ok = false; continue }
            let near = (max(0, r - 4)...min(a.count - 1, r + 4)).contains { $0 != r && a[$0] == w }
            if !near { ok = false }
        }
        // A word that is not plain prose comes back verbatim.
        let inputWords = Set(s.split(whereSeparator: \.isWhitespace).map(String.init))
        for word in out.split(whereSeparator: \.isWhitespace).map(String.init)
            where !word.allSatisfy({ $0.isLetter || $0.isNumber || ",.!?…'\u{2019}".contains($0) }) && !inputWords.contains(word) {
            ok = false
        }
        // Dot-led content tokens and symbols must keep their exact spelling.
        for sym in [".env", ".5", "../config", "()", "!=", "--", "readme.md", "fooBar", "'not'"] {
            if s.components(separatedBy: sym).count != out.components(separatedBy: sym).count, !sym.allSatisfy(\.isLetter) {
                // allowed only if a repeat of that symbol was removed (letters-only rule means symbols never are)
                ok = false
            }
        }
        if !ok { bad += 1; if bad <= 25 { print("FUZZ IN: \(s)\nFUZZ OUT: \(out)") } }
    }
    print("FUZZ BAD \(bad)")
    #expect(bad == 0)
}
@Test func fuzzGuardOnlyAcceptsAllowedDeletions() {
    guard ProcessInfo.processInfo.environment["CURSUS_FUZZ"] != nil else { return }
    var rng = SystemRandomNumberGenerator()
    let pool = ["um", "uh", "the", "I", "want", "to", "not", "go", ".env", ".5", "()", "fooBar", "no", "sorry", "wait",
                "Monday", "Tuesday", "1", "don't", "a", "so", "like", "you", "know", "mean", "actually", "never", "ship", "it"]
    let seps = [" ", ", ", ". ", "... ", "? ", "; ", " - ", " \u{2014} "]
    let v = Vocabulary(terms: [])
    let soft: Set<String> = ["like", "so", "actually", "basically", "you", "know", "i", "mean"]
    var bad = 0, accepted = 0
    for _ in 0..<40000 {
        var s = ""
        for i in 0..<Int.random(in: 2...9, using: &rng) {
            if i > 0 { s += seps.randomElement(using: &rng)! }
            s += pool.randomElement(using: &rng)!
        }
        s += "."
        let words = s.split(separator: " ").map(String.init)
        var keep = words.map { _ in Bool.random(using: &rng) || Bool.random(using: &rng) }
        if !keep.contains(false) { keep[Int.random(in: 0..<keep.count, using: &rng)] = false }
        let out = zip(words, keep).filter(\.1).map(\.0).joined(separator: " ")
        guard !out.isEmpty, TranscriptCleanup.judge(raw: s, output: out, vocabulary: v) == .accepted else { continue }
        accepted += 1
        let prose = CharacterSet(charactersIn: ".,;:!?…")
        let plain = words.map { $0.trimmingCharacters(in: prose).lowercased() }
        var ok = true
        for (i, w) in plain.enumerated() where !keep[i] {
            if ["um", "uh"].contains(w) || soft.contains(w) || w.isEmpty || w == "\u{2014}" { continue }
            if (max(0, i - 4)...min(plain.count - 1, i + 4)).contains(where: { $0 != i && plain[$0] == w }) { continue }
            ok = false
        }
        // Symbols and negations outside a correction are never deleted, even when repeated.
        for (i, w) in plain.enumerated() where !keep[i]
            && [".env", ".5", "()", "-", "not", "don't", "never"].contains(w) { ok = false }
        if !ok { bad += 1; if bad <= 25 { print("JFUZZ IN: \(s)\nJFUZZ OUT: \(out)") } }
    }
    print("JFUZZ accepted \(accepted) bad \(bad)")
    #expect(bad == 0)
}
