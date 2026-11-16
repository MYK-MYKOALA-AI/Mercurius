import Testing
@testable import CursusCore

private let on = Vocabulary(terms: [], takeBacks: TakeBack.defaults + ["oops", "no weight"])
private let off = Vocabulary(terms: [])

@Test func takenBackWordsMayBeDropped() {
    let cases = [
        ("Can you book a meeting for Friday? No, I mean Saturday.", "Can you book a meeting for Saturday?"),
        ("Send it to Tessah, scratch that, send it to Sam.", "Send it to Sam."),
        ("It costs 30, no wait, 40 dollars.", "It costs 40 dollars."),
        ("Meet at the cafe, no weight, at the office.", "Meet at the office."),
        ("Call me Tuesday, oops, Wednesday.", "Call me Wednesday."),
        // Sam, 2026-10-13: a whole sentence taken back, the phrase stuttered.
        ("So I was thinking we should book a meeting for Friday. No wait, wait, wait. How about we book it for Saturday?",
         "How about we book it for Saturday?"),
    ]
    for (raw, out) in cases {
        #expect(TranscriptCleanup.judge(raw: raw, output: out, vocabulary: on) == .accepted, "\(raw)")
        // With take-backs off the same edit is refused: corrections stay as spoken.
        #expect(TranscriptCleanup.judge(raw: raw, output: out, vocabulary: off) == .rejected("dropped words"), "\(raw)")
    }
}

@Test func takeBacksNeverCoverOtherEdits() {
    let refused = [
        // No phrase: an ordinary "no" or "sorry" is not a take-back.
        ("Sam, sorry, I'm late.", "I'm late."),
        ("Friday, no, Saturday.", "Saturday."),
        // The phrase must be set off by a pause, not part of a sentence.
        ("That is what I meant yesterday.", "Yesterday."),
        // Nothing said instead.
        ("Book it for Friday. Scratch that.", "Book it for Friday."),
        // More than eight words taken back.
        ("Please send the full quarterly report to the whole team today, scratch that, tomorrow.", "Please tomorrow."),
        // Dropped words may not reach into an earlier sentence.
        ("Keep this. Book Friday, no I mean Saturday.", "Saturday."),
        ("Keep this sentence. And this one. No wait, how about Saturday?", "How about Saturday?"),
        // A whole sentence is at most 25 words.
        ("So I was thinking that we really should try to book a meeting with the whole team for Friday morning at nine or maybe ten or eleven. No wait. Saturday.", "Saturday."),
        // Words after the phrase must stay.
        ("Call me Tuesday, no wait, Wednesday at noon.", "Call me Wednesday."),
        // And nothing may be added or changed.
        ("Call me Tuesday, no wait, Wednesday.", "Call me Thursday."),
    ]
    for (raw, out) in refused {
        #expect(TranscriptCleanup.judge(raw: raw, output: out, vocabulary: on) != .accepted, "\(raw)")
    }
}

@Test func aTakeBackPhraseMeansTheAIPassRuns() {
    let text = "Book it for Friday, no I mean Saturday."
    #expect(!TranscriptCleanup.hasRemovable("Book it for Friday, scratch Saturday."))
    #expect(TranscriptCleanup.hasRemovable(text, takeBacks: TakeBack.defaults))
}

@Test func phrasesAreParsedFromTheBox() {
    let box = "oops\n  no   wait \nNo wait\nscratch that, my bad\n\nthis phrase is far too long\nuse `code`"
    #expect(TakeBack.parse(box) == ["oops", "no wait", "scratch that", "my bad"])
    #expect(Vocabulary(terms: [], takeBacks: ["oops", "OOPS", ""]).takeBacks == ["oops"])
}

// Review round 3 (Sol, Haiku): edits the user never took back stay refused.
@Test func takeBacksNeverEatRealWords() {
    let vocabulary = Vocabulary(terms: [], takeBacks: TakeBack.defaults + ["oops"])
    let refused = [
        ("Thanks for the help yesterday. I meant to thank you again.", "To thank you again."),
        ("Send it Friday, no wait, wait till Monday.", "Till Monday."),
        ("Book Friday, no wait. No refunds on Saturday.", "Refunds on Saturday."),
        ("I sent it, oops, I forgot the file.", "I forgot the file."),
    ]
    for (raw, out) in refused {
        #expect(TranscriptCleanup.judge(raw: raw, output: out, vocabulary: vocabulary) != .accepted, "\(raw)")
    }
    // Sam, 2026-10-13: "Monday, no, no, no, Tuesday."
    #expect(TranscriptCleanup.judge(raw: "Monday, no, no, no, Tuesday.", output: "Tuesday.", vocabulary: vocabulary) == .accepted)
    #expect(TranscriptCleanup.judge(raw: "Call me Tuesday, oops, Wednesday.", output: "Call me Wednesday.",
                                    vocabulary: vocabulary) == .accepted)
    #expect(TakeBack.mentioned("Can you book a meeting for Friday? No, I mean Saturday.", phrases: TakeBack.defaults))
}

// Review round 4.
@Test func takeBackPhrasesStayInOneSentence() {
    let vocabulary = Vocabulary(terms: [], takeBacks: TakeBack.defaults)
    #expect(TranscriptCleanup.judge(raw: "Book Friday, no. Wait for the confirmation on Saturday.",
                                    output: "For the confirmation on Saturday.", vocabulary: vocabulary) != .accepted)
    #expect(TranscriptCleanup.judge(raw: "Lunch at noon. Friday. No, I mean Saturday.",
                                    output: "Lunch at noon. Saturday.", vocabulary: vocabulary) == .accepted)
    #expect(TranscriptCleanup.judge(raw: "Thanks for the help. I meant to thank you again.",
                                    output: "To thank you again.", vocabulary: vocabulary) != .accepted)
}
