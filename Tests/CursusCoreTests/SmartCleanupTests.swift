import Testing
@testable import CursusCore

// Names are synthetic test examples, not an imported personal dictionary.
private let dictionary = Vocabulary(terms: ["Vercel", "Maelah"])

@Test func smartAcceptsWhatTheSpeakerMeant() {
    let cases = [
        ("Can you book a meeting for Friday? No, I mean Saturday.", "Can you book a meeting for Saturday?"),
        ("Monday, no, no, no, Tuesday.", "Tuesday."),
        ("So I was thinking we should book a meeting for Friday. No wait, wait, wait. How about we book it for Saturday?",
         "So I was thinking we should book it for Saturday?"),
        ("um so I I want to to send the the report to Maelah", "I want to send the report to Maelah."),
        ("we deploy on vercel tomorrow, actually no, Thursday", "We deploy on Vercel on Thursday."),
    ]
    for (raw, out) in cases {
        let enabled = Vocabulary(terms: dictionary.terms, takeBacks: TakeBack.defaults)
        #expect(TranscriptCleanup.judgeSmart(raw: raw, output: out, vocabulary: enabled) == .accepted, "\(raw)")
    }
}

@Test func smartStillRefusesAnswersAndInventions() {
    let cases = [
        ("What time is the meeting tomorrow?", "The meeting is at 10 am tomorrow."),
        ("Write me a poem about the sea.", "Sure, here's a poem about the sea: waves roll in."),
        ("Send the report to Jordan.", "Send the quarterly finance report to Jordan and the whole board by Friday."),
        ("We can ship it on Friday.", "We cannot ship it on Friday."),
        ("It costs forty dollars.", "It costs 45 dollars."),
        ("Book the meeting for Saturday and invite the whole design team.", "Saturday."),
        ("ls -la ~/Desktop", "List the desktop."),
    ]
    for (raw, out) in cases {
        #expect(TranscriptCleanup.judgeSmart(raw: raw, output: out, vocabulary: dictionary) != .accepted, "\(raw)")
    }
}

@Test func smartAllowsProsePunctuationButNotCode() {
    #expect(TranscriptCleanup.judgeSmart(raw: "I really like this design, it's like a breath of fresh air.",
        output: "I really like this design; it's like a breath of fresh air.", vocabulary: dictionary) == .accepted)
    #expect(TranscriptCleanup.judgeSmart(raw: "Hey Casey, I'll meet you at 5pm, no 6pm.",
        output: "Hey Casey, I'll meet you at 6pm.", vocabulary: Vocabulary(terms: dictionary.terms, takeBacks: TakeBack.defaults)) == .accepted)
    #expect(TranscriptCleanup.judgeSmart(raw: "delete the folder", output: "rm -rf /folder", vocabulary: dictionary) != .accepted)
}

@Test func smartOffKeepsCorrections() {
    let cases = [
        ("Can you book a meeting for Friday? No, I mean Saturday.", "Can you book a meeting for Saturday?"),
        ("Hey Casey, I'll meet you at 5pm, no 6pm.", "Hey Casey, I'll meet you at 6pm."),
        ("we deploy on vercel tomorrow, actually no, Thursday", "We deploy on Vercel on Thursday."),
    ]
    for (raw, output) in cases {
        #expect(TranscriptCleanup.judgeSmart(raw: raw, output: output, vocabulary: dictionary) != .accepted)
        #expect(TranscriptCleanup.judgeSmart(raw: raw, output: raw, vocabulary: dictionary) == .accepted)
    }
    #expect(TranscriptCleanup.judgeSmart(raw: "um, so, I I want to to send the the report to Maelah",
        output: "I want to send the report to Maelah.", vocabulary: dictionary) == .accepted)
}

@Test func smartOffAllowsCueWordsAsFillersButKeepsTakeBacks() {
    let fillers = [
        ("I, actually, think we should go", "I think we should go"),
        ("Jordan, sorry, I'm late", "Jordan, I'm late"),
        ("I mean, we should go", "We should go"),
        ("We should, instead, go today", "We should go today"),
        ("I, rather, think we should go", "I think we should go"),
        ("Wait, we should go today", "We should go today"),
    ]
    for (raw, output) in fillers {
        #expect(TranscriptCleanup.judgeSmart(raw: raw, output: output, vocabulary: dictionary) == .accepted)
    }
    for (raw, output) in [
        ("We should go Friday, no, Saturday", "We should go Saturday"),
        ("We should go Friday, scratch that, Saturday", "We should go Saturday"),
        ("We should go Friday, or rather Saturday", "We should go Saturday"),
        ("We should go Friday, I meant Saturday", "We should go Saturday"),
        ("We should go Friday, scratch that, Saturday", "We should go that Saturday"),
    ] {
        #expect(TranscriptCleanup.judgeSmart(raw: raw, output: output, vocabulary: dictionary) != .accepted)
    }
}

@Test func smartOffRejectsCueWordCorrectionsThatDeleteContent() {
    for cue in ["actually", "wait", "instead", "sorry", "rather", "meant"] {
        let raw = "We should go Friday, \(cue), Saturday."
        let merged = "We should go Saturday."
        #expect(TranscriptCleanup.judgeSmart(raw: raw, output: merged, vocabulary: dictionary) == .rejected("dropped words"), "\(cue)")
        #expect(TranscriptCleanup.judgeSmart(raw: raw, output: raw, vocabulary: dictionary) == .accepted, "\(cue)")
        #expect(TranscriptCleanup.judgeSmart(raw: raw, output: "We should go Friday, Saturday.",
            vocabulary: dictionary) == .accepted, "\(cue) as filler")
        #expect(TranscriptCleanup.judgeSmart(raw: raw, output: merged,
            vocabulary: Vocabulary(terms: dictionary.terms, takeBacks: TakeBack.defaults)) == .accepted, "\(cue)")
    }
    #expect(TranscriptCleanup.judgeSmart(raw: "We should go Friday, actually, Saturday.",
        output: "We should go Friday, Saturday.", vocabulary: dictionary) == .accepted)
    #expect(TranscriptCleanup.judgeSmart(raw: "We should go Friday, actually, Saturday.",
        output: "We should go actually, Saturday.", vocabulary: dictionary) == .rejected("dropped words"))
    #expect(TranscriptCleanup.judgeSmart(raw: "We should go Friday, Saturday.",
        output: "We should go Saturday.", vocabulary: dictionary) == .rejected("dropped words"))
    #expect(TranscriptCleanup.judgeSmart(raw: "We should ask Grog Friday, actually, Saturday.",
        output: "We should ask Grok Saturday.", vocabulary: Vocabulary(terms: ["Grok"])) == .rejected("dropped words"))
}

// No correction said, so no new words, facts or meaning changes.
@Test func smartNeedsACorrectionToReword() {
    let refused = [
        ("What time is it", "It is noon."),
        ("Tell me the capital of France", "The capital of France is Paris."),
        ("Write a thank you note to Jordan", "Thank you for everything, Jordan."),
        ("Quick question, what time is the meeting? Also send the deck.", "The meeting is at noon. Also send the deck."),
        ("We cannot ship it on Friday.", "We can ship it on Friday."),
        ("I don't want Friday.", "I want Friday."),
        ("We ship it.", "We ship it Friday."),
        ("Thank the team for their hard work on the launch and the late nights, then send the invoice to Jordan.",
         "Then send the invoice to Jordan."),
    ]
    for (raw, out) in refused {
        #expect(TranscriptCleanup.judgeSmart(raw: raw, output: out, vocabulary: dictionary) != .accepted, "\(raw)")
    }
}

// A Dictionary name replaces a sound-alike, never appears from nothing.
@Test func dictionaryNamesOnlyReplaceSoundAlikes() {
    let names = Vocabulary(terms: ["Grok", "CursusVox"])
    #expect(TranscriptCleanup.judgeSmart(raw: "Switch to Grog for speech.", output: "Switch to Grok for speech.", vocabulary: names) == .accepted)
    #expect(TranscriptCleanup.judgeSmart(raw: "Open curse this vox settings.", output: "Open CursusVox settings.", vocabulary: names) == .accepted)
    #expect(TranscriptCleanup.judgeSmart(raw: "Send the report.", output: "Send the Grok report.", vocabulary: names) != .accepted)
    #expect(TranscriptCleanup.judgeSmart(raw: "Send the paper.", output: "Send the Grok.", vocabulary: names) != .accepted)
    // One misheard word stands in for one name, not two.
    #expect(TranscriptCleanup.judgeSmart(raw: "Send the report to Grog.", output: "Send the Grok report to Grok.", vocabulary: names) != .accepted)
    #expect(TranscriptCleanup.judgeSmart(raw: "Ask Grog, then Grog again.", output: "Ask Grok, then Grok again.", vocabulary: names) == .accepted)
    // Round 3: a correction cue never licenses an extra name; occurrences, not word sets, decide what was dropped.
    #expect(TranscriptCleanup.judgeSmart(raw: "Wait, send the report to Grog.", output: "Send the Grok report to Grok.", vocabulary: names) != .accepted)
    #expect(TranscriptCleanup.judgeSmart(raw: "Ask Grog, then Grog again.", output: "Ask Grog, then Grok again.", vocabulary: names) == .accepted)
    // A spoken name keeps its Dictionary capitals.
    #expect(TranscriptCleanup.judgeSmart(raw: "switch to grok for speech", output: "Switch to Grok for speech.", vocabulary: names) == .accepted)
    #expect(TranscriptCleanup.judgeSmart(raw: "send the report to cursusvox", output: "Send the report to CursusVox.", vocabulary: names) == .accepted)
    #expect(TranscriptCleanup.judgeSmart(raw: "send the report to cursusvox", output: "Send the CursusVox report to CursusVox.", vocabulary: names) != .accepted)
    // A name never turns into a file name or other technical token.
    #expect(TranscriptCleanup.judgeSmart(raw: "open grok settings", output: "Open .grok settings.", vocabulary: names) != .accepted)
    let people = Vocabulary(terms: ["Mark", "Mary"])
    for _ in 0..<20 {
        #expect(TranscriptCleanup.judgeSmart(raw: "Send the report to Marc.", output: "Send the report to Mark.", vocabulary: people) == .accepted)
    }
}

@Test func smartOffRequiresContextForSoftFillers() {
    for (raw, output) in [
        ("Let's meet instead of Friday.", "Let's meet of Friday."),
        ("I was tired so I left.", "I was tired I left."),
        ("Please wait for me.", "Please for me."),
        ("I actually think we should go.", "I think we should go."),
        ("I rather think we should go.", "I think we should go."),
        ("Friday, actually, Saturday", "Saturday"),
        ("Friday, actually, Saturday", "Actually, Saturday"),
        ("Send the report.", "Send the final report."),
        ("Jordan called Mary.", "Mary called Jordan."),
    ] {
        #expect(TranscriptCleanup.judgeSmart(raw: raw, output: output, vocabulary: dictionary) != .accepted, "\(raw)")
        #expect(TranscriptCleanup.judgeSmart(raw: raw, output: raw, vocabulary: dictionary) == .accepted, "\(raw)")
    }
    for (raw, output) in [
        ("Um, so, like, I was saying", "I was saying."),
        ("um so like I was saying", "So like I was saying."),
        ("Actually, we should go.", "We should go."),
        ("Jordan, sorry, I'm late.", "Jordan, I'm late."),
        ("I, actually, think we should go.", "I think we should go."),
        ("Wait, we should go today.", "We should go today."),
        ("um uh um uh yes", "Yes."),
        ("I I I want to to send the the report.", "I want to send the report."),
        ("I want to, um, I want to go.", "I want to go."),
        ("the, uh, the report", "The report."),
        ("So, um,", ""),
        ("You know, we should go.", "We should go."),
    ] {
        #expect(TranscriptCleanup.judgeSmart(raw: raw, output: output, vocabulary: dictionary) == .accepted, "\(raw)")
    }
    #expect(TranscriptCleanup.judgeSmart(raw: "the the report", output: "Report.", vocabulary: dictionary) != .accepted)
    for (raw, output) in [
        ("I will. Um. I will.", "I will."),
        ("Do not go, uh, go away.", "Do not go away."),
        ("We need 5, 5 reports.", "We need 5 reports."),
        ("Wait for me.", ""),
    ] {
        #expect(TranscriptCleanup.judgeSmart(raw: raw, output: output, vocabulary: dictionary) != .accepted, "\(raw)")
    }
}

@Test func smartOffAcceptsWholeDictionarySpans() {
    let names = Vocabulary(terms: ["Cursus Vox", "Grok", "CursusVox"])
    for (raw, output) in [
        ("open curse vox now", "Open Cursus Vox now."),
        ("ask grog um Saturday", "Ask Grok Saturday."),
        ("open curse um vox now", "Open Cursus Vox now."),
        ("Ask Grog, then Grog again.", "Ask Grok, then Grok again."),
        ("Open curse this vox settings.", "Open CursusVox settings."),
        ("Ask grog, um, grog Saturday.", "Ask Grok Saturday."),
    ] {
        #expect(TranscriptCleanup.judgeSmart(raw: raw, output: output, vocabulary: names) == .accepted, "\(raw)")
    }
    for (raw, output) in [
        ("Ask Grog Friday, actually, Saturday.", "Ask Grok Saturday."),
        ("Ask Grog.", "Ask Grok and Grok."),
        ("Send the paper.", "Send the Grok."),
        ("open curse vox Friday now", "Open Cursus Vox now."),
    ] {
        #expect(TranscriptCleanup.judgeSmart(raw: raw, output: output, vocabulary: names) != .accepted, "\(raw)")
    }
}

@Test func smartOffAcceptsCaseOnlyAcronymChanges() {
    for (raw, output) in [
        ("we use ai today", "We use AI today."),
        ("ask nasa tomorrow", "Ask NASA tomorrow."),
        ("um ai, ai helps nasa", "AI helps NASA."),
    ] {
        #expect(TranscriptCleanup.judgeSmart(raw: raw, output: output, vocabulary: dictionary) == .accepted, "\(raw)")
    }
    for (raw, output) in [
        ("we use ai today", "We use AI."),
        ("ask nasa tomorrow", "Ask NASA today."),
        ("we use ai today", "We use OpenAI today."),
        ("fooBar runs", "Foobar runs."),
        ("iOS works", "Ios works."),
        ("ask NASA tomorrow", "Ask Nasa tomorrow."),
    ] {
        #expect(TranscriptCleanup.judgeSmart(raw: raw, output: output, vocabulary: dictionary) != .accepted)
    }
}

// Acronyms only for plain spoken words; "us" stays "us", technical tokens stay exact.
@Test func acronymsOnlyForPlainWords() {
    let names = Vocabulary(terms: ["Vercel", "Maelah"])
    #expect(TranscriptCleanup.judgeSmart(raw: "send it to us", output: "Send it to US.", vocabulary: names) != .accepted)
    #expect(TranscriptCleanup.judgeSmart(raw: "deploy to k8s today", output: "Deploy to K8S today.", vocabulary: names) != .accepted)
    #expect(TranscriptCleanup.judgeSmart(raw: "we use ai today", output: "We use AI today.", vocabulary: names) == .accepted)
}

@Test func smartCannotReverseParticipantsOrMoveAmounts() {
    let enabled = Vocabulary(terms: [], takeBacks: TakeBack.defaults)
    for (raw, output) in [
        ("Alice paid Bob.", "Bob paid Alice."),
        ("Pay Alice 5 dollars and Bob 10 dollars.", "Pay Alice 10 dollars and Bob 5 dollars."),
        ("No refunds. Do not ship.", "No refunds. Do ship."),
        ("Wait, Alice paid Bob.", "Wait, Bob paid Alice.")
    ] {
        #expect(TranscriptCleanup.judgeSmart(raw: raw, output: output, vocabulary: enabled) != .accepted)
    }
}

@Test func shortDictionaryTermsDoNotReplacePronouns() {
    #expect(TranscriptCleanup.judgeSmart(raw: "send us um updates", output: "Send UI updates.",
        vocabulary: Vocabulary(terms: ["UI"], takeBacks: [])) != .accepted)
}

@Test func correctedDictionaryOccurrencesKeepTheirOwnSourceOrder() {
    let vocabulary = Vocabulary(terms: ["Grok"], takeBacks: TakeBack.defaults)
    #expect(TranscriptCleanup.judgeSmart(raw: "Ask Grok about grog on Tuesday, no, Wednesday.",
        output: "Ask Grok about Grok on Wednesday.", vocabulary: vocabulary) == .accepted)
    #expect(TranscriptCleanup.judgeSmart(raw: "Ask grog about Grok on Tuesday, no, Wednesday.",
        output: "Ask Grok about Grok on Wednesday.", vocabulary: vocabulary) == .accepted)
    #expect(TranscriptCleanup.judgeSmart(raw: "Grok paid Alice, no, Bob.",
        output: "Bob paid Grok.", vocabulary: vocabulary) != .accepted)
}

@Test func correctedClauseCanAbandonAnEarlierDictionaryOccurrence() {
    let vocabulary = Vocabulary(terms: ["Grok"], takeBacks: TakeBack.defaults)
    for later in ["Grok", "grog"] {
        #expect(TranscriptCleanup.judgeSmart(raw: "Ask Alice about Grok on Tuesday, no, ask Bob about \(later) on Wednesday.",
            output: "Ask Bob about Grok on Wednesday.", vocabulary: vocabulary) == .accepted)
    }
}

@Test func exactDictionaryIdentitiesCannotSupplyOtherNamesOrAbsorbContent() {
    let names = Vocabulary(terms: ["Alice", "Alicia"], takeBacks: TakeBack.defaults)
    #expect(TranscriptCleanup.judgeSmart(raw: "Alice paid Alicia on Tuesday, no, Wednesday.",
        output: "Alicia paid Alice on Wednesday.", vocabulary: names) != .accepted)
    #expect(TranscriptCleanup.judgeSmart(raw: "Send the report to Alicia.", output: "Send the report to Alice.",
        vocabulary: Vocabulary(terms: ["Alice", "Alicia"], takeBacks: [])) != .accepted)
    #expect(TranscriptCleanup.judgeSmart(raw: "Mary am ready.", output: "Mary ready.",
        vocabulary: Vocabulary(terms: ["Mary"], takeBacks: [])) != .accepted)
}

@Test func unrelatedCorrectionCannotRemoveANegation() {
    let enabled = Vocabulary(terms: [], takeBacks: TakeBack.defaults)
    for (raw, output) in [
        ("Wait, no refunds. Do not ship.", "No refunds. Do ship."),
        ("Actually, no refunds. Book Tuesday, no, Wednesday.", "Refunds. Book Wednesday."),
        ("Pay Alice Monday, no, Tuesday.", "No, pay Alice Tuesday."),
        ("Pay Alice Monday, no, Tuesday.", "Do not pay Alice Tuesday.")
    ] {
        #expect(TranscriptCleanup.judgeSmart(raw: raw, output: output, vocabulary: enabled) != .accepted)
    }
    #expect(TranscriptCleanup.judgeSmart(raw: "Do not go, no I mean stay.", output: "Stay.", vocabulary: enabled) == .accepted)
    #expect(TranscriptCleanup.judgeSmart(raw: "No no refunds.", output: "Refunds.", vocabulary: enabled) != .accepted)
    #expect(TranscriptCleanup.judgeSmart(raw: "No refunds.", output: "Refunds.",
        vocabulary: Vocabulary(terms: [], takeBacks: ["no"])) != .accepted)
    #expect(TranscriptCleanup.judgeSmart(raw: "Do not ask Grog, um.", output: "Do not ask Grok.",
        vocabulary: Vocabulary(terms: ["Grok"], takeBacks: [])) == .accepted)
}

@Test func dictionaryCannotSwapWholeNamesSwallowNegationsOrAnswerQuestions() {
    let names = Vocabulary(terms: ["Alice Jones", "Alicia Jones"], takeBacks: TakeBack.defaults)
    #expect(TranscriptCleanup.judgeSmart(raw: "Alice Jones paid Alicia Jones on Tuesday, no, Wednesday.",
        output: "Alicia Jones paid Alice Jones on Wednesday.", vocabulary: names) != .accepted)
    #expect(TranscriptCleanup.judgeSmart(raw: "Can Exampleton not go?", output: "Exampleton go?",
        vocabulary: Vocabulary(terms: ["Exampleton"], takeBacks: [])) != .accepted)
    #expect(TranscriptCleanup.judgeSmart(raw: "Do not ship?", output: "Do not ship.",
        vocabulary: Vocabulary(terms: [], takeBacks: [])) != .accepted)
    #expect(TranscriptCleanup.judgeSmart(raw: "Alice Jones paid Alicia Jones on Tuesday, no, Wednesday.",
        output: "Alice Jones paid Alicia Jones on Wednesday.", vocabulary: names) == .accepted)
}

@Test func dictionarySoundAlikesCannotAbsorbFollowingContentOrIntroduceNegation() {
    let names = Vocabulary(terms: ["Exampleton"], takeBacks: [])
    #expect(TranscriptCleanup.judgeSmart(raw: "Exampleten paid Bob.", output: "Exampleton Bob.", vocabulary: names) != .accepted)
    #expect(TranscriptCleanup.judgeSmart(raw: "Exampleten paid Bob.", output: "Exampleton paid Bob.", vocabulary: names) == .accepted)
    #expect(TranscriptCleanup.judgeSmart(raw: "Note to ship today.", output: "Not to ship today.",
        vocabulary: Vocabulary(terms: ["Not"], takeBacks: TakeBack.defaults)) != .accepted)
}

@Test func retainedNegationAllowsTakeBackAndDictionaryCorrection() {
    let vocabulary = Vocabulary(terms: ["Grok"], takeBacks: TakeBack.defaults)
    #expect(TranscriptCleanup.judgeSmart(raw: "Ask Alice, no I mean email Grog. Do not ship.",
        output: "Email Grok. Do not ship.", vocabulary: vocabulary) == .accepted)
}

@Test func takeBackCannotUseAnotherIdentityAsASurvivingRepeat() {
    let vocabulary = Vocabulary(terms: ["Alice", "Alicia"], takeBacks: TakeBack.defaults)
    #expect(TranscriptCleanup.judgeSmart(raw: "Ask Alice, Alice, Alicia. Book Friday, no I mean Saturday. Do not ship.",
        output: "Ask Alicia. Book Saturday. Do not ship.", vocabulary: vocabulary) != .accepted)
    #expect(TranscriptCleanup.judgeSmart(raw: "Ask Alice, Alice, Alicia.", output: "Ask Alicia.",
        vocabulary: Vocabulary(terms: ["Alice", "Alicia"], takeBacks: [])) != .accepted)
}
