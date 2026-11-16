import Foundation
import Testing
import CursusCore
@testable import CursusVox

@MainActor @Test func cancelledCleanupKeepsCostsAndTheAdmittedAppStyle() async throws {
    let speech = LocalSpeech(credentialRead: { nil }, credentialAuthorize: { nil })
    defer { speech.shutdown() }
    let channel = AsyncStream<Void>.makeStream()
    var selected = CleanupContext(app: "Terminal", bundleID: "com.apple.Terminal", style: .strict)
    var recorded: [LocalSpeech.Facts] = []
    speech.recordedFacts = { recorded.append($0) }
    speech.cleanup = { raw, _, _, context in
        channel.continuation.yield(())
        // Model completion can arrive even though the caller has cancelled.
        try? await Task.sleep(for: .seconds(1))
        #expect(context.app == "Terminal")
        #expect(context.bundleID == "com.apple.Terminal")
        #expect(context.style == .strict)
        #expect(selected.style == .smart)
        return CleanupOutcome(text: raw, model: "synthetic-model", millis: 1, note: nil, cost: 0.003)
    }
    let admitted = selected
    let task = Task {
        await speech.finishRecognized(LocalSpeech.Facts(generation: 1, raw: "synthetic words", engine: .cloud,
            speechMillis: 1, fallback: nil, cleanup: nil, at: 0, speechCost: 0.012),
            context: admitted, budget: 1, isCurrent: { !Task.isCancelled })
    }
    for await _ in channel.stream { break }
    selected = CleanupContext(app: "Slack", bundleID: "com.tinyspeck.slackmacgap", style: .smart)
    task.cancel()
    #expect(await task.value == nil)
    #expect(recorded.count == 1)
    #expect(recorded.first?.speechCost == 0.012)
    #expect(recorded.first?.cleanup?.cost == 0.003)
    #expect(speech.lastFacts == recorded.first)
}

@MainActor @Test func cancelledRecognitionIsBilledWithoutRunningCleanup() async {
    let speech = LocalSpeech(credentialRead: { nil }, credentialAuthorize: { nil })
    defer { speech.shutdown() }
    var count = 0
    speech.cleanup = { raw, _, _, _ in
        Issue.record("A cancelled recording must not start cleanup")
        return CleanupOutcome(text: raw, model: nil, millis: 0, note: nil)
    }
    speech.recordedFacts = { facts in count += 1; #expect(facts.speechCost == 0.012) }
    let text = await speech.finishRecognized(LocalSpeech.Facts(generation: 1, raw: "synthetic words", engine: .cloud,
        speechMillis: 1, fallback: nil, cleanup: nil, at: 0, speechCost: 0.012),
        context: CleanupContext(), budget: 1, isCurrent: { false })
    #expect(text == nil)
    #expect(count == 1)
}

@MainActor @Test func transientCommandFactsAreNeverRetainedByTheRecorder() async {
    let speech = LocalSpeech(credentialRead: { nil }, credentialAuthorize: { nil }, retention: .transient)
    defer { speech.shutdown() }
    let result = await speech.finishRecognized(LocalSpeech.Facts(generation: 1, raw: "rewrite concise", engine: .apple,
        speechMillis: 1, fallback: nil, cleanup: nil, at: 0), context: CleanupContext(), budget: 1, isCurrent: { true })
    #expect(result == "rewrite concise")
    #expect(speech.lastFacts == nil)
    speech.close(1)
    #expect(speech.lastFacts == nil)
}
