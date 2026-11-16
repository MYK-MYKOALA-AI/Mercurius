import Testing
@testable import CursusCore

private let vocabulary = Vocabulary(terms: [], replacements: [:])
private func judged(_ raw: String, _ output: String) -> TranscriptCleanup.Verdict {
    TranscriptCleanup.judge(raw: raw, output: output, vocabulary: vocabulary, removeOnly: true)
}

// Speech engines rarely give commas, so fillers are judged by the words around them.
@Suite struct SpokenFillerTests {
    @Test(arguments: [
        ("so like i was thinking we should probably move the launch to next week you know", "I was thinking we should probably move the launch to next week."),
        ("i mean the main problem is that the popup does not show when i press the key", "The main problem is that the popup does not show when I press the key."),
        ("what i need you to do is like build the feature first and then test it", "What I need you to do is build the feature first and then test it."),
        ("the the the server is down again and nobody told me", "The server is down again and nobody told me."),
        ("okay so basically i think we need like three more days to finish this", "Okay, basically, I think we need three more days to finish this."),
        ("hey can you tell me like how many people signed up yesterday", "Hey, can you tell me how many people signed up yesterday?"),
        ("you know i think it works", "I think it works."),
        ("actually i think it works", "I think it works."),
    ])
    func fillersMayGo(raw: String, output: String) { #expect(judged(raw, output) == .accepted, "\(raw)") }

    @Test(arguments: [
        ("i like you", "I you."),
        ("we really like the plan", "We really the plan."),
        ("it looks like rain today", "It looks rain today."),
        ("it is like a car", "It is a car."),
        ("i would like coffee", "I would coffee."),
        ("do you know the answer", "Do the answer?"),
        ("you know the answer", "The answer."),
        ("i mean it", "It."),
        ("what i mean is simple", "What is simple."),
        ("so far so good", "Far so good."),
        ("so much for that", "Much for that."),
        ("we should go friday actually saturday", "We should go friday saturday."),
        ("that is not actually true", "That is not true."),
        ("do not delete the backup", "Delete the backup."),
        ("i will not not go", "I will not go."),
        ("i'd like to book a table", "I'd to book a table."),
        ("so do i", "Do I."),
        ("you know nothing", "Nothing."),
        ("is this someone you know", "Is this someone?"),
        ("i don't think you know", "I don't think."),
        ("what do you know", "What do?"),
        ("do you know", "Do?"),
        ("it was like everything changed", "It was everything changed."),
        ("you know", ""),
        ("do not go go away", "Do not go away."),
        ("please send the invoice today", "Please send the invoice."),
    ])
    func realWordsStay(raw: String, output: String) { #expect(judged(raw, output) != .accepted, "\(raw)") }

    @Test func modesOtherThanRemoveOnlyAreUnchanged() {
        #expect(TranscriptCleanup.judge(raw: "tell me like how many", output: "Tell me how many?", vocabulary: vocabulary) != .accepted)
    }
}
