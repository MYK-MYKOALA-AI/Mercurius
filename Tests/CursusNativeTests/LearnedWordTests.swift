import Testing
import CursusCore
@testable import CursusVox

@Test func aLearnedFixAddsTheReplacementAndTheTerm() {
    let saved = LearnedWord.apply(.init(heard: "Vassal", correct: "Vercel"),
                                  to: (terms: ["Maelah"], replacements: [:]), builtIn: Vocabulary.seed)
    #expect(saved.replacements == ["vassal": "Vercel"])
    #expect(saved.terms == ["Maelah", "Vercel"])
}

@Test func aCaseFixUpdatesTheSpellingWithoutAReplacement() {
    let saved = LearnedWord.apply(.init(heard: "maelah", correct: "Maelah"),
                                  to: (terms: ["maelah"], replacements: [:]), builtIn: Vocabulary.seed)
    #expect(saved.replacements.isEmpty)
    #expect(saved.terms == ["Maelah"])
}

@Test func aFullDictionaryStillLearnsTheReplacement() {
    let full = (1...Vocabulary.maxTerms).map { "Word\($0)x" }
    let saved = LearnedWord.apply(.init(heard: "Vassal", correct: "Vercel"),
                                  to: (terms: full, replacements: [:]), builtIn: [])
    #expect(saved.terms.count == Vocabulary.maxTerms)
    #expect(saved.replacements["vassal"] == "Vercel")
}

@MainActor @Test func commonWordsAreRecognisedByTheSpellChecker() {
    #expect(CorrectionWatch.isCommonWord("blue"))
    // Brand names can enter Apple's dictionary or the user's learned words.
    #expect(!CorrectionWatch.isCommonWord("qzxqzxqzx"))
}

@MainActor @Test func thePasteIsFoundEvenWhenTheCaretDoesNotSayWhere() {
    #expect(CorrectionWatch.pastedStart(in: "Note: hello there", pasted: "hello there", caret: 17) == 6)
    #expect(CorrectionWatch.pastedStart(in: "Note: hello there", pasted: "hello there", caret: 0) == 6)
    #expect(CorrectionWatch.pastedStart(in: "Note: hello there", pasted: "hello there", caret: nil) == 6)
    #expect(CorrectionWatch.pastedStart(in: "hi hi", pasted: "hi", caret: nil) == nil)
    #expect(CorrectionWatch.pastedStart(in: "hi hi", pasted: "hi", caret: 5) == 3)
    #expect(CorrectionWatch.pastedStart(in: "nothing", pasted: "hello", caret: nil) == nil)
}
