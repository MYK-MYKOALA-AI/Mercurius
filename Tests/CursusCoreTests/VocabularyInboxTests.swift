import Foundation
import Testing
@testable import CursusCore

struct VocabularyInboxTests {
    @Test func suggestionsNeedApprovalIgnoreSurvivesAndPendingExpires() throws {
        var inbox = VocabularyInbox(); let now = Date(timeIntervalSince1970: 100)
        inbox.suggest(term: "FixtureName",from: "fixture name",source: .correction,now: now)
        #expect(inbox.pending.count == 1)
        let id = try #require(inbox.pending.first?.id); inbox.ignore(id)
        inbox.suggest(term: "FixtureName",from: "fixture name",source: .correction,now: now)
        #expect(inbox.pending.isEmpty); inbox.restore(id, now: now)
        inbox.suggest(term: "FixtureName",from: "fixture name",source: .correction,now: now)
        inbox.purge(now: now.addingTimeInterval(30*86400)); #expect(inbox.pending.isEmpty)
        #expect(try JSONDecoder().decode(VocabularyInbox.self,from: JSONEncoder().encode(inbox)) == inbox)
    }
    @Test func fullDictionaryAndConflictingRulesArePreserved() throws {
        var inbox = VocabularyInbox(); inbox.suggest(term: "NewName",from: "new name",source: .correction)
        let id = try #require(inbox.pending.first?.id)
        #expect(inbox.accept(id,terms: (0..<500).map { "Word\($0)" },replacements: [:]) == nil)
        #expect(inbox.accept(id,terms: [],replacements: ["new name":"Existing"]) == nil)
        #expect(inbox.pending.count == 1)
    }
    @Test func undoCannotOverwriteLaterChanges() throws {
        var inbox = VocabularyInbox(); inbox.suggest(term: "NewName",from: "new name",source: .correction)
        let id = try #require(inbox.pending.first?.id)
        let accepted = inbox.accept(id,terms: ["Existing"],replacements: [:],revision: 1)
        let saved = try #require(accepted)
        let change = try #require(inbox.accepted.first?.id)
        #expect(inbox.undo(change,terms: saved.terms,replacements: ["new name":"Edited"],revision: 1) == nil)
        #expect(inbox.undo(change,terms: saved.terms,replacements: saved.replacements,revision: 2) == nil)
        let result = inbox.undo(change,terms: saved.terms,replacements: saved.replacements,revision: 1)
        let undone = try #require(result)
        #expect(undone.terms == ["Existing"]); #expect(undone.replacements.isEmpty)
    }
    @Test func pendingBoundAndCorrectionExplanationRespectLiterals() {
        var inbox = VocabularyInbox()
        for i in 0..<120 { inbox.suggest(term: "Name\(i)",from: nil,source: .repeated) }
        #expect(inbox.pending.count == 100)
        let vocabulary = Vocabulary(terms: [],replacements: ["fixture name":"FixtureName"])
        #expect(vocabulary.appliedCorrections(in: "Use fixture name").count == 1)
        #expect(vocabulary.appliedCorrections(in: "Say \"fixture name\" and `fixture name`").isEmpty)
    }
}

@Test func approvalSeparatesHintsFromReplacementsAndExpiresAtAction() throws {
    let now = Date(); var inbox = VocabularyInbox()
    inbox.suggest(term: "FixtureName", from: "fixture name", source: .correction, now: now)
    let id = try #require(inbox.pending.first?.id)
    let accepted = inbox.accept(id, terms: [], replacements: [:], approval: .hintOnly, now: now)
    let hint = try #require(accepted)
    #expect(hint.terms == ["FixtureName"]); #expect(hint.replacements.isEmpty)
    #expect(inbox.accepted.first?.addedRule == false)
    inbox.suggest(term: "OtherName", from: "other name", source: .correction, now: now)
    let expired = try #require(inbox.pending.first?.id)
    #expect(inbox.accept(expired, terms: hint.terms, replacements: [:], now: now.addingTimeInterval(30*86400)) == nil)
}
@Test func restoreRequeuesWithoutApprovalAndPreservesIgnoredChoiceWhenFull() throws {
    var inbox = VocabularyInbox(); let now = Date()
    inbox.suggest(term: "RestoredName", from: nil, source: .repeated, now: now)
    let id = try #require(inbox.pending.first?.id); inbox.ignore(id)
    for i in 0..<100 { inbox.suggest(term: "Name\(i)", from: nil, source: .repeated, now: now) }
    let full = inbox.restore(id, now: now)
    #expect(!full); #expect(inbox.ignored.count == 1)
    inbox.ignore(try #require(inbox.pending.first?.id))
    let restored = inbox.restore(id, now: now.addingTimeInterval(1))
    #expect(restored)
    #expect(inbox.pending.contains { $0.id == id }); #expect(inbox.accepted.isEmpty)
}

@Test func recognitionOnlyApprovalStaysOutOfTheEffectiveCleanupPipeline() throws {
    var inbox = VocabularyInbox()
    inbox.suggest(term: "FixtureName", from: "fixture name", source: .correction)
    let id = try #require(inbox.pending.first?.id)
    let accepted = inbox.accept(id, terms: [], replacements: [:], approval: .hintOnly)
    let saved = try #require(accepted)
    let hints = Vocabulary.effective(terms: saved.terms, replacements: saved.replacements, recognitionOnly: ["FixtureName"])
    #expect(hints.terms == ["FixtureName"]); #expect(hints.cleanupTerms.isEmpty)
    #expect(TranscriptCleanup.rules("use fixture name", vocabulary: hints) == "use fixture name")
    #expect(TranscriptCleanup.judgeSmart(raw: "use fixture name", output: "Use FixtureName.", vocabulary: hints) != .accepted)
    let replacement = Vocabulary.effective(terms: saved.terms, replacements: ["fixture name":"FixtureName"])
    #expect(TranscriptCleanup.rules("use fixture name", vocabulary: replacement) == "use FixtureName")
}

@Test func recognitionOnlyExactIdentityCannotSupplyAnotherCleanupName() {
    let vocabulary = Vocabulary(terms: ["Alice", "Alicia"], takeBacks: [], recognitionOnly: ["Alice"])
    #expect(TranscriptCleanup.judgeSmart(raw: "Ask Alice.", output: "Ask Alicia.", vocabulary: vocabulary) != .accepted)
}

@Test func undoReplacementApprovalRestoresThePriorHintOnlyMode() throws {
    var inbox = VocabularyInbox()
    inbox.suggest(term: "FooBar", from: "foo bar", source: .correction)
    let hintID = try #require(inbox.pending.first?.id)
    let approvedHint = inbox.accept(hintID, terms: [], replacements: [:], revision: 1, approval: .hintOnly, wasRecognitionOnly: false)
    let hint = try #require(approvedHint)
    inbox.suggest(term: "FooBar", from: "foe bar", source: .correction)
    let ruleID = try #require(inbox.pending.first?.id)
    let approvedRule = inbox.accept(ruleID, terms: hint.terms, replacements: hint.replacements, revision: 2,
        approval: .hintAndReplacement, wasRecognitionOnly: true)
    let rule = try #require(approvedRule), change = try #require(inbox.accepted.last)
    inbox = try JSONDecoder().decode(VocabularyInbox.self, from: JSONEncoder().encode(inbox))
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(inbox)) as! [String:Any]
    legacy["accepted"] = (legacy["accepted"] as! [[String:Any]]).map { entry in
        var entry = entry; entry.removeValue(forKey: "recognitionOnlyBefore"); entry.removeValue(forKey: "recognitionOnlyAfter"); return entry
    }
    let older = try JSONDecoder().decode(VocabularyInbox.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(older.accepted.last?.recognitionOnlyBefore == nil)
    #expect(change.recognitionOnlyBefore == true); #expect(change.recognitionOnlyAfter == false)
    #expect(inbox.undo(change.id, terms: rule.terms, replacements: rule.replacements, revision: 2, recognitionOnly: true) == nil)
    let undone = inbox.undo(change.id, terms: rule.terms, replacements: rule.replacements, revision: 2, recognitionOnly: false)
    let restored = try #require(undone)
    let vocabulary = Vocabulary.effective(terms: restored.terms, replacements: restored.replacements,
        recognitionOnly: change.recognitionOnlyBefore == true ? [change.term] : [])
    #expect(vocabulary.apply("foo bar and foe bar") == "foo bar and foe bar")
    #expect(vocabulary.cleanupTerms.isEmpty)
}

@Test func vocabularyEqualityIncludesRecognitionOnlyClassification() {
    let eligible = Vocabulary(terms: ["FixtureName"])
    let hintOnly = Vocabulary(terms: ["FixtureName"], recognitionOnly: ["FixtureName"])
    #expect(eligible.cleanupTerms == ["FixtureName"])
    #expect(hintOnly.cleanupTerms.isEmpty)
    #expect(eligible != hintOnly)
}

// `ignored` used to grow for the life of the install inside a single UserDefaults value.
@Test func ignoredSuggestionsStayBoundedAndKeepTheNewest() throws {
    var inbox = VocabularyInbox(); let now = Date()
    let limit = VocabularyInbox.ignoredLimit
    for i in 0..<(limit + 25) {
        inbox.suggest(term: "Name\(i)", from: nil, source: .repeated, now: now)
        let id = try #require(inbox.pending.last?.id)
        inbox.ignore(id)
    }
    inbox.purge(now: now)
    #expect(inbox.ignored.count == limit)
    #expect(inbox.ignored.last?.term == "Name\(limit + 24)")
    #expect(!inbox.ignored.contains { $0.term == "Name0" })
}
