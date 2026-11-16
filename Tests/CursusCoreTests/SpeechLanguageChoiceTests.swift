import Testing
@testable import CursusCore

@Suite struct SpeechLanguageChoiceTests {
    @Test func theMacsLanguageIsSuggested() {
        let supported = ["en_AU", "en_US", "fr_FR", "de_DE"]
        #expect(SpeechLanguageChoice.suggested(preferred: ["fr-FR"], supported: supported) == "fr_FR")
        #expect(SpeechLanguageChoice.suggested(preferred: ["fr-CA"], supported: supported) == "fr_FR")
        #expect(SpeechLanguageChoice.suggested(preferred: ["en-AU", "en-US"], supported: supported) == "en_AU")
        #expect(SpeechLanguageChoice.suggested(preferred: ["fj-FJ"], supported: supported) == "en_AU")
        #expect(SpeechLanguageChoice.suggested(preferred: ["fj-FJ"], supported: ["de_DE"]) == nil)
    }
    @Test func severalLanguagesUpToAppleLimit() {
        var choice = SpeechLanguageChoice()
        for id in ["a", "b", "c", "d", "e"] { let added = choice.toggle(id); #expect(added) }
        let sixth = choice.toggle("f")
        #expect(!sixth)
        #expect(choice.chosen.count == 5)
        #expect(choice.active == "a")
    }
    @Test func removingTheActiveLanguageMovesToTheNext() {
        var choice = SpeechLanguageChoice(chosen: ["a", "b"], active: "b")
        choice.toggle("b")
        #expect(choice.active == "a")
        choice.toggle("a")
        #expect(choice.active == nil)
    }
    @Test func savedValuesAreSanitised() {
        let choice = SpeechLanguageChoice(chosen: ["a", "a", "b"], active: "gone")
        #expect(choice.chosen == ["a", "b"]); #expect(choice.active == "a")
        var other = choice; other.activate("zzz"); #expect(other.active == "a")
    }
    @Test func lookupPrefersTheChosenLanguageThenFallsBack() {
        #expect(SpeechLanguageChoice.lookupOrder(active: "fr_FR", preferred: ["en-AU"]) == ["fr_FR", "en-AU", "en-US"])
        #expect(SpeechLanguageChoice.lookupOrder(active: nil, preferred: ["en_US"]) == ["en_US", "en-AU"])
    }
}
