import Testing
@testable import CursusCore

// Names and locations below are authored examples, not imported personal data.
private let existing = Vocabulary(terms: ["Supabase", "Grok"], replacements: ["super base": "Supabase"])

@Test func importReadsAnAIAnswerWithBulletsNumbersAndPairs() {
    let answer = """
    Here are the terms:
    1. Vercel
    - **Maelah**
    • Riverton (suburb)
    * vassal → Vercel
    2) kora -> Kora
    Supabase
    superlongnamethatgoesonandonandonandonandonandonandonandon
    """
    let result = DictionaryImport.parse(answer, existing: existing)
    #expect(result.newTerms == ["Vercel", "Maelah", "Riverton", "Kora"])
    #expect(result.newReplacements.map(\.from) == ["vassal", "kora"])
    #expect(result.newReplacements.map(\.to) == ["Vercel", "Kora"])
    #expect(result.alreadyHave == ["Supabase"])
    #expect(result.tooLong.count == 1)
    #expect(result.overLimit.isEmpty)
    #expect(result.skipped == ["Here are the terms:"])
}

@Test func importSplitsCommaListsAndDeduplicates() {
    let result = DictionaryImport.parse("Vercel, Comet, vercel,  ,Maelah", existing: existing)
    #expect(result.newTerms == ["Vercel", "Comet", "Maelah"])
}

@Test func importStopsAtTheTermLimit() {
    let count = Vocabulary.maxTerms + 20
    let many = (1...count).map { "Name\($0)x" }.joined(separator: "\n")
    let result = DictionaryImport.parse(many, existing: existing)
    #expect(result.newTerms.count == Vocabulary.maxTerms - existing.terms.count)
    #expect(result.overLimit.count == count - (Vocabulary.maxTerms - existing.terms.count))
}

@Test func dictionaryImportAndEditRetainWordsBeyondSpeechHintLimit() throws {
    let listed = (1...150).map { "Project\($0)x" }.joined(separator: "\n")
    let imported = DictionaryImport.parse(listed, existing: existing)
    #expect(imported.newTerms.count == 150)
    #expect(imported.overLimit.isEmpty)
    let saved = imported.merged(into: (terms: [], replacements: [:]))
    let edited = try #require(DictionaryImport.applyEdit(from: listed, to: listed + "\nExtraProject",
        builtIn: existing, saved: saved))
    #expect(edited.terms.count == 151)
    #expect(edited.terms.last == "ExtraProject")
}

@Test func importNeverTakesCodeOrSentences() {
    let result = DictionaryImport.parse("rm -rf /\nI often talk about my cats and dogs at work\nVercel", existing: existing)
    #expect(result.newTerms == ["Vercel"])
    #expect(result.skipped.count == 2)
}

@Test func mergingAnImportKeepsWhatWasThere() {
    let result = DictionaryImport.parse("Vercel\nvassal → Vercel", existing: existing)
    let merged = result.merged(into: (terms: ["Grok"], replacements: ["old": "Old"]))
    #expect(merged.terms == ["Grok", "Vercel"])
    #expect(merged.replacements == ["old": "Old", "vassal": "Vercel"])
}

// The pasted text's offset is taken as its last occurrence in `before`, as the caret would show.
private func compare(_ before: String, _ pasted: String, _ now: String,
                     common: Set<String> = ["blue", "red", "Monday", "monday", "sync", "vassal", "Vassal", "Super Base"])
    -> CorrectionLearner.Outcome {
    let at = before.range(of: pasted, options: .backwards).map { before.distance(from: before.startIndex, to: $0.lowerBound) } ?? -1
    return CorrectionLearner.compare(before: before, pastedAt: at, pasted: pasted, now: now,
                                     isCommonWord: { common.contains($0) })
}

@Test func aFixInsideThePastedTextIsLearned() {
    #expect(compare("Notes: Deploy it on Vassal tonight.", "Deploy it on Vassal tonight.",
                    "Notes: Deploy it on Vercel tonight.")
            == .learned(.init(heard: "Vassal", correct: "Vercel", addsReplacement: false)))   // "vassal" is a real word
    #expect(compare("ping maela about it", "ping maela about it", "ping Maelah about it")
            == .learned(.init(heard: "maela", correct: "Maelah", addsReplacement: true)))
    #expect(compare("push it to github today", "push it to github today", "push it to GitHub today")
            == .learned(.init(heard: "github", correct: "GitHub", addsReplacement: false)))
}

@Test func editsOutsideThePastedTextAreIgnoredAndWatchingGoesOn() {
    // Sol r1: typing "Vercel" after the pasted text must not teach "Vassal -> Vercel".
    #expect(compare("Deploy on Vassal", "Deploy on Vassal", "Deploy on Vassal Vercel") == .outside(at: 0))
    // An edit before the pasted text moves it along.
    #expect(compare("Title\nDeploy on Vassal", "Deploy on Vassal", "New title\nDeploy on Vassal") == .outside(at: 10))
    #expect(compare("same", "same", "same") == .unchanged)
}

@Test func rewritesDeletionsAndOrdinaryWordsAreNotLearned() {
    let cases: [(String, String)] = [
        ("Deploy it on Vassal tonight.", "Deploy it tonight."),                   // deletion
        ("Deploy it on Vassal tonight.", "Ship the build on Friday instead."),    // rewrite
        ("Deploy it on Vassal tonight.", "Deploy it on Vercel or Netlify tonight."),
        ("I want the red one.", "I want the blue one."),                          // a change of mind
        ("Deploy it on Vassal tonight.", "Deploy it on V tonight."),              // too short
        ("Call me at 5.", "Call me at 6."),                                       // numbers
        ("we ship on monday", "we ship on Monday"),                               // Haiku r1: a capital, not a name
        ("copy the sync folder", "copy the Syncthing folder")                    // different first letter? no: same "s"
    ]
    for (pasted, now) in cases.dropLast() {
        #expect(compare(pasted, pasted, now) == .rewritten, "\(now)")
    }
    // Haiku r1: a real word heard ("sync") never becomes a global replacement.
    #expect(compare("copy the sync folder", "copy the sync folder", "copy the Syncthing folder")
            == .learned(.init(heard: "sync", correct: "Syncthing", addsReplacement: false)))
}

@Test func aPairNeverTakesTheLastSlotFromAWord() {
    // A full personal list keeps every explicit word ahead of optional pair targets.
    let builtIn = Vocabulary(terms: Vocabulary.seed)
    let words = (1...(Vocabulary.maxTerms - builtIn.terms.count)).map { "Word\($0)x" }
    let box = (["vassal → Vercel"] + words).joined(separator: "\n")
    let result = DictionaryImport.parse(box, existing: builtIn)
    #expect(result.overLimit.isEmpty)
    #expect(result.newTerms == words)
    #expect(result.newReplacements.map(\.to) == ["Vercel"])
}

@Test func namesSaidThreeTimesInADayAreSuggested() {
    let day = ["Ping Maelah about the Vercel deploy.", "Vercel is down again.", "Ask Maelah to check Vercel.",
               "The deploy is fine.", "The team is fine. The end.", "Maelah said yes.", "Grok works, Grok works, Grok."]
    let common: Set = ["the", "ask", "ping"]
    let suggestions = RepeatedTerms.suggest(day, existing: existing, isCommonWord: { common.contains($0.lowercased()) })
    #expect(suggestions == [.init(term: "Maelah", count: 3), .init(term: "Vercel", count: 3)])
}

@Test func codeAndKnownWordsAreNeverSuggested() {
    let day = Array(repeating: "Run `Makefile` with Supabase", count: 4) + Array(repeating: "Supabase rocks", count: 4)
    #expect(RepeatedTerms.suggest(day, existing: existing).isEmpty)
}

@Test func onlyThePastedCopyCountsWhenTheSameWordsAppearTwice() {
    // Sol r2: the paste is the FIRST copy (caret after it); editing the older second copy teaches nothing.
    let before = "Deploy on Vassal. Deploy on Vassal."
    let first = CorrectionLearner.compare(before: before, pastedAt: 0, pasted: "Deploy on Vassal.",
                                          now: "Deploy on Vassal. Deploy on Vercel.")
    #expect(first == .outside(at: 0))
    let ours = CorrectionLearner.compare(before: before, pastedAt: 0, pasted: "Deploy on Vassal.",
                                         now: "Deploy on Vercel. Deploy on Vassal.")
    #expect(ours == .learned(.init(heard: "Vassal", correct: "Vercel")))
    // A wrong offset never matches.
    #expect(CorrectionLearner.compare(before: before, pastedAt: 3, pasted: "Deploy on Vassal.", now: before) == .rewritten)
}

@Test func extendingAWordIsNotAFix() {
    // Haiku r2: "Maelah" -> "Maelah's" must not rewrite every later "Maelah".
    #expect(compare("ping Maelah about it", "ping Maelah about it", "ping Maelah's about it") == .rewritten)
    #expect(compare("ship to Vassal", "ship to Vassal", "ship to Vassals") == .rewritten)
}

@Test func pairsLongerThanATermAreRejected() {
    let long = String(repeating: "x", count: 51)
    let result = DictionaryImport.parse("vassal → \(long)", existing: existing)
    #expect(result.newReplacements.isEmpty)
    #expect(result.tooLong.count == 1)
}

@Test func savingAnEditKeepsWordsAddedMeanwhile() {
    let builtIn = Vocabulary(terms: Vocabulary.seed)
    let shown = "Vercel\nMaelah"
    // While the user edits (deleting Maelah, adding Kora), a learned word arrives.
    let saved = (terms: ["Vercel", "Maelah", "Riverton"], replacements: ["vassal": "Vercel"])
    let updated = DictionaryImport.applyEdit(from: shown, to: "Vercel\nKora", builtIn: builtIn, saved: saved)
    #expect(updated?.terms == ["Vercel", "Riverton", "Kora"])
    #expect(updated?.replacements == ["vassal": "Vercel"])
    // Removing a pair line removes the replacement.
    let pairs = DictionaryImport.applyEdit(from: "vassal → Vercel", to: "", builtIn: builtIn,
                                           saved: (terms: ["Vercel"], replacements: ["vassal": "Vercel"]))
    #expect(pairs?.replacements.isEmpty == true)
    // Going over the limit refuses the save.
    let full = (terms: (1...(Vocabulary.maxTerms - builtIn.terms.count)).map { "Word\($0)x" }, replacements: [String: String]())
    #expect(DictionaryImport.applyEdit(from: "", to: "Extraname", builtIn: builtIn, saved: full) == nil)
}

@Test func theFastPathSeesALongRepeat() {
    // Sol r2: a nine-word repeat in one sentence must still reach the AI pass.
    #expect(TranscriptCleanup.hasRemovable(
        "Please send the final invoice to our Australian customer, Please send the final invoice to our Australian customer."))
}

@Test func namesOutliveTheTextTheyCameFrom() {
    #expect(RepeatedTerms.textLifetime == 600)
    #expect(RepeatedTerms.names(in: "Ping Maelah about the Vercel deploy, OK?") == ["Ping", "Maelah", "Vercel"])
    #expect(RepeatedTerms.names(in: "run `make` in Vercel").isEmpty)
    let seen = [["Maelah", "Vercel"], ["Vercel"], ["Maelah", "Vercel"], ["Maelah"]]
    #expect(RepeatedTerms.suggest(names: seen, existing: Vocabulary(terms: []))
            == [.init(term: "Maelah", count: 3), .init(term: "Vercel", count: 3)])
}

@Test func savingRespellsATermAndNeverRevertsALearnedPair() {
    let builtIn = Vocabulary(terms: [])
    let shown = "maezza → Maela\nvercel"
    // Learned meanwhile: the pair now points to "Maelah".
    let saved = (terms: ["vercel", "Maela", "Maelah"], replacements: ["maezza": "Maelah"])
    let result = DictionaryImport.applyEdit(from: shown, to: "maezza → Maela\nVercel", builtIn: builtIn, saved: saved)
    #expect(result?.replacements["maezza"] == "Maelah")
    #expect(result?.terms.contains("Vercel") == true)
    #expect(result?.terms.contains("vercel") == false)
}

@Test func soundAlikeAndMultiWordFixesAreLearned() {
    // Fixes with a different first letter or several words were dropped.
    #expect(compare("ask Catie to join", "ask Catie to join", "ask Katie to join")
            == .learned(.init(heard: "Catie", correct: "Katie", addsReplacement: true)))
    #expect(compare("we use super base now", "we use super base now", "we use Supabase now")
            == .learned(.init(heard: "super base", correct: "Supabase", addsReplacement: true)))
    #expect(compare("ping fill ip today", "ping fill ip today", "ping Phillip today")
            == .learned(.init(heard: "fill ip", correct: "Phillip", addsReplacement: true)))
}

@Test func unlikeWordsAndLongRunsAreStillNotLearned() {
    let cases: [(String, String)] = [
        ("ask Bob to join", "ask Katie to join"),                   // different start, not close
        ("deploy on the box", "deploy Docker"),                     // a run that doesn't spell the name
        ("we use a super big base now", "we use Supabase now"),     // four words into one
        ("we use super base now", "we use Super Base now"),         // two words stay two
        ("me as well", "me aswel"),                                 // Sol r1: a typo, not a name
        ("ask Catie to join", "ask katie to join"),                  // no capital: not a name
    ]
    for (pasted, now) in cases { #expect(compare(pasted, pasted, now) == .rewritten, "\(now)") }
}

@Test func closeSpellingFoldsSoundAlikes() {
    #expect(CorrectionLearner.close("Catie", "Katie"))
    #expect(CorrectionLearner.close("super base", "Supabase"))
    #expect(!CorrectionLearner.close("Bob", "Katie"))
    #expect(CorrectionLearner.distance(Array("kitten"), Array("sitting")) == 3)
    #expect(CorrectionLearner.distance([], Array("abc")) == 3)
}

@Test func technicalTermsImportAndCodeTokensAreCaptured() {
    // The jargon dictation gets wrong must not be silently dropped on import.
    let result = DictionaryImport.parse("C#\nfoo/bar\n@handle\nNode.js\nk8s\nGPT-5", existing: Vocabulary(terms: []))
    #expect(Set(result.newTerms) == ["C#", "foo/bar", "@handle", "Node.js", "k8s", "GPT-5"])
    #expect(result.skipped.isEmpty)
    // Code-shaped tokens are captured for learning even though names() ignores them.
    let terms = RepeatedTerms.terms(in: "call get_code then getCode for k8s and GPT-5")
    #expect(terms.contains("get_code") && terms.contains("getCode"))
    #expect(terms.contains("k8s") && terms.contains("GPT-5"))
    // Paths, addresses and secret-shaped tokens are never terms.
    let rejected = DictionaryImport.parse("/etc/passwd\n../../config\na@b.com\nfollow me @handle", existing: Vocabulary(terms: []))
    #expect(rejected.newTerms.isEmpty)
    #expect(RepeatedTerms.terms(in: "rotate aws_secret_key and the password_reset_token for get_code")
            == ["get_code"])
    // Three times in a single dictation teaches nothing; across two it does.
    #expect(RepeatedTerms.suggest(names: [["Vercel", "Vercel", "Vercel"]], existing: Vocabulary(terms: [])).isEmpty)
    #expect(RepeatedTerms.suggest(names: [["Vercel"], ["Vercel", "Vercel"]], existing: Vocabulary(terms: []))
            == [.init(term: "Vercel", count: 3)])
}

@Test func namesSaidOftenAreAddedOnceAndNotAgainAfterRemoval() {
    let seen = [["Maelah"], ["Maelah", "Vercel"], ["Maelah"], ["Vercel"]]
    #expect(RepeatedTerms.autoAdd(names: seen, existing: existing, added: []) == ["Maelah"])
    #expect(RepeatedTerms.autoAdd(names: seen, existing: existing, added: ["maelah"]).isEmpty)
    #expect(RepeatedTerms.autoAdd(names: seen, existing: existing, added: [], isCommonWord: { $0 == "Maelah" }).isEmpty)
}

@Test func dictionarySupportsMultiwordNamesAndApostrophes() {
    let parsed = DictionaryImport.parse("Ari'El Meadow\nmy widget -> MyWidget", existing: existing)
    #expect(parsed.newTerms.contains("Ari'El Meadow"))
    #expect(parsed.newTerms.contains("MyWidget"))
    #expect(parsed.newReplacements.first?.from == "my widget")
    #expect(parsed.skipped.isEmpty)
}

@Test func fixesCanBeSeveralWordsOrHoldDigits() {
    guard case let .learned(fix) = compare("use opus now", "use opus now", "use Opus5 now") else { Issue.record("digit not learned"); return }
    #expect(fix.correct == "Opus5")
    guard case let .learned(two) = compare("ask tee code now", "ask tee code now", "ask T3 Code now") else { Issue.record("not learned"); return }
    #expect(two.correct == "T3 Code")
    #expect(compare("the cat sat", "the cat sat", "the dog sat") == .rewritten)
}
@Test func onlyRealLookingWordsAreAdoptedAutomatically() {
    for good in ["Koa", "KoraTalks", "MyKoala", "T3 Code", "FreeBSD", "OpenRouter", "NASA"] { #expect(CorrectionLearner.isSafeToAdopt(good), "\(good)") }
    for bad in ["ANDimprovements", "onmykoala", "lowercase"] { #expect(!CorrectionLearner.isSafeToAdopt(bad), "\(bad)") }
}
@Test func wordsCloseToSavedOnesAreTreatedAsMishearings() {
    let saved = ["DeepSeek", "Falah", "OpenRouter"]
    #expect(!CorrectionLearner.isNewWord("DeepSeq", existing: saved))
    #expect(!CorrectionLearner.isNewWord("Fala", existing: saved))
    #expect(!CorrectionLearner.isNewWord("deepseek", existing: saved))
    #expect(CorrectionLearner.isNewWord("Hermione", existing: saved))
}

@Test func keyboardSlipsAreNotNames() {
    let common: (String) -> Bool = { ["this", "okay", "cody", "on", "my", "koala"].contains($0.lowercased()) }
    #expect(CorrectionLearner.isKeyboardSlip(heard: "This", correct: "Thsi", isCommonWord: common))
    #expect(CorrectionLearner.isKeyboardSlip(heard: "Okay", correct: "Okayy", isCommonWord: common))
    #expect(CorrectionLearner.isKeyboardSlip(heard: "on my koala", correct: "Onmykoala", isCommonWord: common))
    #expect(!CorrectionLearner.isKeyboardSlip(heard: "Cory", correct: "Kora", isCommonWord: common))
    #expect(!CorrectionLearner.isKeyboardSlip(heard: "Versel", correct: "Vercel", isCommonWord: common))
    #expect(!CorrectionLearner.isKeyboardSlip(heard: "open router", correct: "OpenRouter", isCommonWord: common))
    #expect(!CorrectionLearner.isKeyboardSlip(heard: "Fala", correct: "Falah", isCommonWord: common))
}
