import Foundation
import Testing
@testable import CursusCore

@Test func snippetsPreserveFormattingAndRequireExplicitCompleteCue() throws {
    var book = SnippetBook()
    try book.save(Snippet(cue: "My reply", text: "Hello\n\nThanks, Jordan"), dictionary: [])
    #expect(book.expand(" MY  REPLY ") == "Hello\n\nThanks, Jordan")
    #expect(book.expand("use my reply now") == nil)
    #expect(throws: SnippetBook.Problem.duplicateCue) { try book.save(Snippet(cue: "my reply", text: "Other"), dictionary: []) }
    #expect(throws: SnippetBook.Problem.dictionaryConflict) { try book.save(Snippet(cue: "CursusVox", text: "Other"), dictionary: ["cursusvox"]) }
    let decoded = try JSONDecoder().decode(SnippetBook.self, from: JSONEncoder().encode(book))
    #expect(decoded == book)
    book.remove(book.entries[0].id)
    #expect(book.expand("my reply") == nil)
}
@Test func textCommandsStayExplicitAndDoNotInterpretGeneralInstructions() {
    #expect(WritingCommand.parse("send this to Slack") == nil)
    #expect(WritingCommand.parse("please translate my email") == nil)
    #expect(WritingCommand.parse("translate to French") == .translate("French"))
    #expect(WritingCommand.parse("rewrite concise") == .rewrite(.concise))
    #expect(WritingCommand.parse("search invoice October") == .search("invoice October"))
    #expect(WritingCommand.bullets.localResult(source: "One\n\nTwo", snippets: SnippetBook()) == "- One\n- Two")
}
@Test func recordedCommandsAcceptSentencePunctuationBeforeUserConfirmation() throws {
    for (spoken, shown, parsed) in [
        ("Rewrite, concise.", "Rewrite concise", WritingCommand.rewrite(.concise)),
        ("Translate to, French.", "Translate to French", .translate("French")),
        ("Translate, to French!", "Translate to French", .translate("French")),
        ("Snippet, my.reply.", "Snippet my.reply", .snippet("my.reply")),
        ("Search, C++ examples?", "Search C++ examples", .search("C++ examples")),
        ("Uppercase.", "Uppercase", .uppercase), ("Lowercase!", "Lowercase", .lowercase),
        ("Bullet, list.", "Bullet list", .bullets)
    ] {
        #expect(WritingCommand.spokenInput(spoken) == shown)
        #expect(WritingCommand.parse(shown) == parsed)
    }
    var book = SnippetBook()
    try book.save(Snippet(cue: "my.reply", text: "Hello\n\nThanks"), dictionary: [])
    let command = try #require(WritingCommand.parse(WritingCommand.spokenInput("Snippet, my.reply.")))
    #expect(command.localResult(source: "", snippets: book) == "Hello\n\nThanks")
    #expect(WritingCommand.spokenInput("Please send this.") == "Please send this.")
    #expect(WritingCommand.parse(WritingCommand.spokenInput("Rewrite concise. Search invoice.")) == nil)
}
@Test func typedCommandsKeepLiteralArgumentPunctuation() throws {
    #expect(WritingCommand.parse("search C++?") == .search("C++?"))
    #expect(WritingCommand.parse("snippet my.reply.") == .snippet("my.reply."))
    #expect(WritingCommand.parse("rewrite concise.") == nil)
    var book = SnippetBook()
    try book.save(Snippet(cue: "my.reply.", text: "Literal punctuation"), dictionary: [])
    #expect(WritingCommand.parse("snippet my.reply.")?.localResult(source: "", snippets: book) == "Literal punctuation")
}
@Test func retainedSearchMatchesAcrossFieldsAndRequiresAllTerms() {
    #expect(RetainedTextSearch.matches("café invoice", fields: ["Cafe", "Invoice 12"]))
    #expect(!RetainedTextSearch.matches("invoice missing", fields: ["Invoice 12"]))
    #expect(!RetainedTextSearch.matches(" ", fields: ["Anything"]))
}

@Test func secretShapedCapitalizedNamesNeverBecomeRepeatedTerms() {
    let terms = RepeatedTerms.terms(in: "PasswordExample SecretAlpha CredentialDemo PlainName")
    #expect(!terms.contains("PasswordExample"))
    #expect(!terms.contains("SecretAlpha"))
    #expect(!terms.contains("CredentialDemo"))
    #expect(terms.contains("PlainName"))
}

@Test func previewRejectsLateOrChangedSourceAndNeverLosesOriginal() {
    var preview = WritingPreviewState()
    let first = preview.begin(source: "First")
    let second = preview.begin(source: "Second")
    let accepted1 = !preview.receive("Old", generation: first, currentSource: "First")
    #expect(accepted1)
    let accepted2 = !preview.receive("New", generation: second, currentSource: "Edited")
    #expect(accepted2)
    #expect(preview.original == "Second" && preview.output == nil)
    let accepted3 = preview.receive("New", generation: second, currentSource: "Second")
    #expect(accepted3)
    #expect(preview.usable(currentSource: "Second"))
    #expect(!preview.usable(currentSource: "Changed"))
    preview.clear()
    let accepted4 = !preview.receive("Late", generation: second, currentSource: "Second")
    #expect(accepted4)
}
@Test func equalLengthSelectionEditsStillRefuseReplacement() {
    let range = SelectionAnchor(location: 0, length: 3)
    #expect(!WritingPreviewState.sameSelection(original: "cat", current: "dog", expected: range, observed: range))
    #expect(!WritingPreviewState.sameSelection(original: "cat", current: "cat", expected: range, observed: SelectionAnchor(location: 1, length: 3)))
    #expect(WritingPreviewState.sameSelection(original: "cat", current: "cat", expected: range, observed: range))
}

@Test func invalidSavedSnippetsFailInsteadOfSilentlyOverwriting() throws {
    let id = UUID().uuidString
    let bad = Data("{\"entries\":[{\"id\":\"\(id)\",\"cue\":\"same\",\"text\":\"A\"},{\"id\":\"\(UUID().uuidString)\",\"cue\":\"SAME\",\"text\":\"B\"}]}".utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(SnippetBook.self, from: bad) }
}

@Test func writingUsagePreservesLegacyOperationDecoding() throws {
    enum LegacyOperation: String, Decodable { case speech, cleanup, retry, reClean, migration }
    struct LegacyEvent: Decodable { let operation: LegacyOperation }
    var event = UsageEvent(provider: "fixture", model: "fixture/model", operation: .reClean)
    event.writingAction = "translation"
    let data = try JSONEncoder().encode(event)
    #expect(try JSONDecoder().decode(LegacyEvent.self, from: data).operation == .reClean)
    #expect(try JSONDecoder().decode(UsageEvent.self, from: data).operationLabel == "translation")
}

@Test func commandCaptureKeepsMicrophoneOwnershipThroughRepeatedFinalization() {
    var state = CommandCaptureState()
    let began = state.begin(); let ready = state.ready(); let finished = state.finish()
    #expect(began && ready && finished && state.busy)
    let repeated = state.finish(); let overlapping = state.begin()
    #expect(!repeated && !overlapping && state.phase == .finalizing)
    state.reset()
    #expect(!state.busy)
}

@Test func commandInterruptionResetsEveryActivePhase() {
    for phase in [CommandCaptureState.Phase.starting, .recording, .finalizing] {
        var state = CommandCaptureState()
        state.begin()
        if phase != .starting { state.ready() }
        if phase == .finalizing { state.finish() }
        state.reset()
        let lateReady = state.ready(); let lateFinish = state.finish()
        #expect(!state.busy && !lateReady && !lateFinish)
    }
}

@Test func stopDuringCommandStartupRejectsTheLateReadyCallback() {
    var state = CommandCaptureState()
    state.begin()
    let stop = state.stop()
    #expect(stop == .cancelStartup && !state.busy)
    let delayedReady = state.ready()
    #expect(!delayedReady && state.phase == .idle)
    state.begin(); state.ready()
    let finish = state.stop(); let repeatStop = state.stop()
    #expect(finish == .finalize && repeatStop == .ignored && state.busy)
}

// Dictation-side expansion: only a recording that is exactly one cue expands. Everything else is left
// to be delivered as spoken, so a snippet can never rewrite an ordinary sentence.
@Test func onlyAWholeRecordingOfExactlyOneCueExpands() throws {
    var book = SnippetBook()
    try book.save(Snippet(cue: "my reply", text: "Thanks — I'll get back to you today."), dictionary: [])
    try book.save(Snippet(cue: "address", text: "12 Example St, Sydney NSW 2000"), dictionary: [])

    #expect(book.expansion(forTranscript: "my reply") == "Thanks — I'll get back to you today.")
    // Cue matching is the same normalisation as the explicit command: case and spacing do not matter.
    #expect(book.expansion(forTranscript: "  My   Reply  ") == "Thanks — I'll get back to you today.")
    // A cue inside a sentence is never expanded.
    #expect(book.expansion(forTranscript: "could you send my reply please") == nil)
    #expect(book.expansion(forTranscript: "my reply and then the address") == nil)
    // Nothing said, nothing to expand; an unknown cue is left alone.
    #expect(book.expansion(forTranscript: "") == nil)
    #expect(book.expansion(forTranscript: "   ") == nil)
    #expect(book.expansion(forTranscript: "something else entirely") == nil)
    // An empty book never changes dictation.
    #expect(SnippetBook().expansion(forTranscript: "my reply") == nil)
}

// The dictation rule's two safeguards. Technical text is preserved verbatim by policy, and a cue the
// dictionary also owns belongs to the dictionary — the explicit command refuses that conflict too.
@Test func dictationExpansionRespectsTechnicalTextAndDictionaryConflicts() throws {
    var book = SnippetBook()
    try book.save(Snippet(cue: "foo/bar", text: "snippet wins here"), dictionary: [])
    try book.save(Snippet(cue: "address", text: "12 Example St, Sydney NSW 2000"), dictionary: [])

    // A plain whole-cue recording expands.
    #expect(book.dictationExpansion(forSpoken: "address", cleaned: "address", dictionary: []) == "12 Example St, Sydney NSW 2000")
    // Technical text is never rewritten, even when it matches a saved cue exactly.
    #expect(TranscriptCleanup.isTechnical("foo/bar"))
    #expect(book.dictationExpansion(forSpoken: "foo/bar", cleaned: "foo/bar", dictionary: []) == nil)
    // A cue that is also a dictionary term stays with the dictionary.
    #expect(book.dictationExpansion(forSpoken: "address", cleaned: "address", dictionary: ["Address"]) == nil)
    // The raw guard is separate from the match: a technical transcript that is not a cue is untouched either way.
    #expect(book.dictationExpansion(forSpoken: "let x = 1", cleaned: "let x = 1", dictionary: []) == nil)
    // And the plain matcher, used by the explicit command path, still ignores the dictionary argument by default.
    #expect(book.expansion(forTranscript: "address") == "12 Example St, Sydney NSW 2000")
    #expect(book.expansion(forTranscript: "address", dictionary: ["address"]) == nil)
}
