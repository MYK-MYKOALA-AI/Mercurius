import Foundation
import Testing
import CursusCore
@testable import CursusVox

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("cursusvox-log-\(UUID().uuidString)")
}
private let record = DeliveryRecord(time: Date(timeIntervalSince1970: 0), engine: "grok",
    speechModel: "x-ai/grok-stt-1.0", speechMs: 2130, fallback: nil, cleanupModel: "openai/gpt-oss-120b",
    cleanupMs: 370, cleanupNote: nil, app: "com.tinyspeck.slackmacgap", classification: "normal",
    editable: true, outcome: "pasted", reason: nil)

@Test func dailyCostsIncludeSpeechCleanupRetriesAndDiscards() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day = Application.dayKey(now)
    let both = DeliveryRecord.addToDay(speech: 0.02, cleanup: 0.003, count: true,
        day: day, total: 0.1, dictations: 2, now: now)
    #expect(abs(both.total - 0.123) < 0.000001)
    #expect(both.dictations == 3)
    let retried = DeliveryRecord.addToDay(speech: 0.012, cleanup: nil, count: true,
        day: day, total: 0, dictations: 0, now: now)
    #expect(retried.cost == 0.012)
    #expect(retried.dictations == 1)
    let discarded = DeliveryRecord.addToDay(speech: 0.02, cleanup: nil, count: false,
        day: day, total: 0, dictations: 0, now: now)
    #expect(discarded.cost == 0.02)
    #expect(discarded.dictations == 0)
    for outcome in ["retried", "discarded"] {
        let billed = DeliveryRecord(time: now, engine: "grok", outcome: outcome, costUSD: retried.cost)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(billed)) as? [String: Any])
        #expect(object["costUSD"] as? Double == 0.012)
        #expect(Set(object.keys).isDisjoint(with: ["text", "raw", "transcript", "before", "cleaned"]))
    }
}

@Test func dailyCostsResetAndSeparateChargesFromDeliveries() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let next = DeliveryRecord.addToDay(speech: 0.012, cleanup: nil, count: true,
        day: Application.dayKey(now.addingTimeInterval(-86400)), total: 1, dictations: 20, now: now)
    #expect(next.total == 0.012)
    #expect(next.dictations == 1)
    let ignored = DeliveryRecord.addToDay(speech: nil, cleanup: nil, count: false,
        day: next.day, total: next.total, dictations: next.dictations, now: now)
    #expect(ignored.cost == nil)
    #expect(ignored.total == next.total)
    #expect(ignored.dictations == next.dictations)
    let local = DeliveryRecord.addToDay(speech: nil, cleanup: nil, count: true,
        day: next.day, total: next.total, dictations: next.dictations, now: now)
    #expect(local.cost == nil)
    #expect(local.total == next.total)
    #expect(local.dictations == 2)
}

@Test func retryLogUsesTheSelectedEngineAndKeepsBlankChargesPrivate() throws {
    for oneStep in [false, true] {
        let retried = DeliveryRecord.retry(oneStep: oneStep, heardSpeech: true, cost: 0.012)
        #expect(retried.engine == (oneStep ? "gemini" : "grok"))
        #expect(retried.speechModel == (oneStep ? CloudSpeech.oneStepModel : CloudSpeech.model))
        #expect(retried.outcome == "retried")
        let blank = DeliveryRecord.retry(oneStep: oneStep, heardSpeech: false, cost: 0.012)
        #expect(blank.costUSD == 0.012)
        #expect(blank.outcome == "discarded")
        #expect(blank.reason == "no speech")
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(blank)) as? [String: Any])
        #expect(Set(object.keys).isDisjoint(with: ["text", "raw", "transcript", "before", "cleaned"]))
    }
}

@Test func liveLogEngineAgreesWithRetryAndRespectsOnDeviceFallback() {
    for oneStep in [false, true] {
        #expect(DeliveryRecord.engineName(backend: .cloud, oneStep: oneStep)
            == DeliveryRecord.retry(oneStep: oneStep, heardSpeech: true, cost: nil).engine)
        #expect(DeliveryRecord.engineName(backend: .apple, oneStep: oneStep) == "on-device")
    }
}

@Test func homeDailySummaryOmitsZeroDictationsButKeepsBilledWork() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day = Application.dayKey(now)
    let billed = DeliveryRecord.addToDay(speech: 0.012, cleanup: nil, count: false,
        day: nil, total: 0, dictations: 0, now: now)
    #expect(DeliveryRecord.daySummary(day: billed.day, total: billed.total, words: billed.words, now: now)
        == "Today $0.012")
    #expect(DeliveryRecord.daySummary(day: day, total: 0, words: 1, now: now) == "Today $0.000 · 1 word today")
    #expect(DeliveryRecord.daySummary(day: day, total: 0.012, words: 2, now: now) == "Today $0.012 · 2 words today")
    #expect(DeliveryRecord.daySummary(day: day, total: 0.012, words: 120, allTimeWords: 1_234, now: now)
        == "Today $0.012 · 120 words today · 1,234 all-time")
    #expect(DeliveryRecord.wordsFooter(today: 120, allTime: 1_234, day: day, now: now) == "120 words today · 1,234 all-time")
    #expect(DeliveryRecord.daySummary(day: day, total: 0, words: 0, now: now) == nil)
    #expect(DeliveryRecord.daySummary(day: day, total: 0, words: 0, allTimeWords: 50, now: now)
        == "Today $0.000 · 50 all-time")
    #expect(DeliveryRecord.daySummary(day: nil, total: 0.012, words: 1, now: now) == nil)
    #expect(DeliveryRecord.daySummary(day: Application.dayKey(now.addingTimeInterval(-86400)),
        total: 0.012, words: 1, now: now) == nil)
}

@Test func dictationCountWaitsForOneSuccessfulDeliveryPerRecording() throws {
    let now = Date()
    let recognized = DeliveryRecord.addToDay(speech: 0.012, cleanup: 0.003, count: false,
        day: nil, total: 0, dictations: 0, now: now)
    #expect(recognized.total == 0.015)
    #expect(recognized.dictations == 0)
    for results: [EffectResult] in [[], [.failed("cancelled")]] {
        #expect(!DeliveryRecord.didDeliver(results))
    }
    for result: EffectResult in [.copied(attributableCounter: nil), .pasteSent, .axSent, .axConfirmed] {
        #expect(DeliveryRecord.didDeliver([result]))
    }
    var ledger = RecordingLedger()
    ledger.register(1)
    ledger.record(1, .copied(attributableCounter: nil))
    ledger.record(1, .pasteSent)
    let finished = ledger.finished(1, inFlight: false)
    let entry = try #require(finished)
    let delivered = DeliveryRecord.addToDay(speech: nil, cleanup: nil,
        count: DeliveryRecord.didDeliver(entry.results), day: recognized.day,
        total: recognized.total, dictations: recognized.dictations, now: now)
    #expect(delivered.total == recognized.total)
    #expect(delivered.dictations == 1)
    #expect(ledger.finished(1, inFlight: false) == nil)
}

@Test func ledgerKeepsLateBilledFactsUntilCancellationSettles() {
    var ledger = RecordingLedger()
    ledger.register(1)
    #expect(ledger.finished(1, inFlight: true, failure: "cancelled") == nil)
    ledger.recognized(LocalSpeech.Facts(generation: 1, raw: "synthetic", engine: .cloud, speechMillis: 1,
        fallback: nil, cleanup: nil, at: 0, speechCost: 0.012))
    let ready = ledger.delivered(inFlight: { _ in false })
    #expect(ready.count == 1)
    #expect(ready.first?.1.facts?.speechCost == 0.012)
    #expect(ready.first?.1.attempted == false)
    #expect(ledger.delivered(inFlight: { _ in false }).isEmpty)
}

@Test func deliveryLogWritesOnePrivateLinePerRecordingWithoutText() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = DeliveryLog(directory: directory)
    log.append(record); log.append(record)
    let content = try String(contentsOf: log.file, encoding: .utf8)
    let lines = content.split(separator: "\n")
    #expect(lines.count == 2)
    let object = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
    #expect(object["engine"] as? String == "grok")
    #expect(object["outcome"] as? String == "pasted")
    // The record type has no field that could carry transcript or field text.
    let keys = Set(object.keys)
    #expect(keys.isDisjoint(with: ["text", "raw", "cleaned", "transcript", "before"]))
    let mode = try FileManager.default.attributesOfItem(atPath: log.file.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
}

@Test func deliveryLogRotatesAtOneMegabyte() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = DeliveryLog(directory: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: DeliveryLog.rotateAt).write(to: log.file)
    log.append(record)
    let rotated = log.file.appendingPathExtension("1")
    #expect(FileManager.default.fileExists(atPath: rotated.path))
    let fresh = try String(contentsOf: log.file, encoding: .utf8)
    #expect(fresh.split(separator: "\n").count == 1)
}

@Test func deliveryLogTightensLoosePermissionsOnExistingAndRotatedFiles() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = DeliveryLog(directory: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("{}\n".utf8).write(to: log.file)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.file.path)
    log.append(record)
    #expect(try FileManager.default.attributesOfItem(atPath: log.file.path)[.posixPermissions] as? Int == 0o600)
    try Data(repeating: 0x41, count: DeliveryLog.rotateAt).write(to: log.file)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.file.path)
    log.append(record)
    let rotated = log.file.appendingPathExtension("1")
    #expect(try FileManager.default.attributesOfItem(atPath: rotated.path)[.posixPermissions] as? Int == 0o600)
    #expect(try FileManager.default.attributesOfItem(atPath: log.file.path)[.posixPermissions] as? Int == 0o600)
}

@Test func recordingsThatNeverReachDeliveryAreLoggedAsDiscarded() {
    #expect(DeliveryRecord.discardReason(results: [], heard: .silence, failure: nil) == "no speech")
    #expect(DeliveryRecord.discardReason(results: [], heard: .speech, failure: nil) == "cancelled")
    #expect(DeliveryRecord.discardReason(results: [], heard: .nothing, failure: nil) == "stopped before a transcript")
    #expect(DeliveryRecord.discardReason(results: [], heard: .nothing, failure: "Microphone failed") == "Microphone failed")
    #expect(DeliveryRecord.discardReason(results: [.copied(attributableCounter: nil)], heard: .speech, failure: nil) == nil)
    #expect(DeliveryRecord.outcome([.copied(attributableCounter: 3), .pasteSent]) == "pasted")
    #expect(DeliveryRecord.outcome([.copied(attributableCounter: nil), .failed("x")]) == "copied")
    #expect(DeliveryRecord.outcome([.failed("x")]) == "failed")
}

@Test func everyRecordingIsLoggedExactlyOnce() {
    var tracker = RecordingLogTracker()
    #expect(tracker.settled() == nil)
    // Normal: start, settle, settle again.
    #expect(tracker.started(1) == nil)
    #expect(tracker.settled() == 1)
    #expect(tracker.settled() == nil)
    // The next recording starts before the last one settled on screen.
    #expect(tracker.started(2) == nil)
    #expect(tracker.started(3) == 2)
    // A start-up that fails synchronously is still logged when idle is seen.
    #expect(tracker.settled() == 3)
    #expect(tracker.started(4) == nil)
    #expect(tracker.started(5) == 4)
    #expect(tracker.settled() == 5)
}

@Test func ledgerWaitsForEachRecordingsOwnDeliveries() {
    var ledger = RecordingLedger()
    let context = Context(destination: nil)
    ledger.register(1); ledger.register(2)
    ledger.delivering(1, context: context, app: "a", facts: nil)
    ledger.record(1, .copied(attributableCounter: nil))
    // Recording 1 ends while its paste is still running: nothing logged yet.
    #expect(ledger.finished(1, inFlight: true) == nil)
    // Recording 2 runs meanwhile; its results never mix into recording 1.
    ledger.record(2, .failed("x"))
    #expect(ledger.delivered(inFlight: { $0 == 1 }).isEmpty)
    ledger.record(1, .pasteSent)
    let ready = ledger.delivered(inFlight: { _ in false })
    #expect(ready.map(\.0) == [1])
    #expect(ready.first?.1.results == [.copied(attributableCounter: nil), .pasteSent])
    #expect(ledger.finished(2, inFlight: false)?.results == [.failed("x")])
}

@Test func ledgerNeverReopensALoggedRecordingAndMarksRefusals() {
    var ledger = RecordingLedger()
    ledger.register(1)
    let facts = LocalSpeech.Facts(generation: 1, raw: "heard", engine: .cloud, speechMillis: 1, fallback: nil,
                                  cleanup: nil, at: 0)
    ledger.delivering(1, context: Context(destination: nil, secureEventInput: true), app: nil, facts: facts)
    let entry = ledger.finished(1, inFlight: false)
    #expect(entry?.attempted == true)
    #expect(entry?.results.isEmpty == true)
    #expect(DeliveryRecord.outcome([]) == "refused")
    // Copy last for recording 1 later: no entry (and no transcript) is kept.
    ledger.delivering(1, context: Context(destination: nil), app: nil, facts: facts)
    ledger.record(1, .copied(attributableCounter: nil))
    #expect(ledger.finished(1, inFlight: false) == nil)
    #expect(ledger.delivered(inFlight: { _ in false }).isEmpty)
}

@Test func ledgerIgnoresRecordingsItWasNotToldAbout() {
    var ledger = RecordingLedger()
    for generation in UInt64(2)...40 { ledger.register(generation); _ = ledger.finished(generation, inFlight: false) }
    let facts = LocalSpeech.Facts(generation: 1, raw: "heard", engine: .cloud, speechMillis: 1, fallback: nil,
                                  cleanup: nil, at: 0)
    ledger.delivering(1, context: Context(destination: nil), app: nil, facts: facts)
    ledger.record(1, .copied(attributableCounter: nil))
    #expect(ledger.finished(1, inFlight: false) == nil)
}

@Test func failureReasonSurvivesWhileTheLogWaitsForDelivery() {
    var ledger = RecordingLedger()
    ledger.register(7)
    ledger.delivering(7, context: Context(destination: nil), app: nil, facts: nil)
    #expect(ledger.finished(7, inFlight: true, failure: "Microphone disconnected") == nil)
    let ready = ledger.delivered(inFlight: { _ in false })
    #expect(ready.first?.1.failure == "Microphone disconnected")
}

@Test func recordingLogKeepsTheAdmittedOneStepMode() throws {
    var ledger = RecordingLedger()
    var selectedOneStep = true
    ledger.register(1, oneStep: selectedOneStep)
    selectedOneStep = false
    ledger.register(2, oneStep: selectedOneStep)
    let facts = LocalSpeech.Facts(generation: 1, raw: "synthetic words", engine: .cloud,
                                 speechMillis: 1, fallback: nil, cleanup: nil, at: 0)
    ledger.recognized(facts)
    ledger.delivering(1, context: Context(destination: nil), app: nil, facts: facts)
    #expect(ledger.finished(1, inFlight: true) == nil)
    // Repeated admission and a later engine setting cannot rewrite the snapshot.
    ledger.register(1, oneStep: selectedOneStep)
    let delivered = ledger.delivered(inFlight: { _ in false })
    let first = try #require(delivered.first?.1)
    #expect(DeliveryRecord.engineName(backend: facts.engine, oneStep: first.oneStep) == "gemini")
    #expect(first.attempted && first.facts == facts)
    selectedOneStep = true
    let finished = ledger.finished(2, inFlight: false, failure: "cancelled")
    let second = try #require(finished)
    #expect(DeliveryRecord.engineName(backend: .cloud, oneStep: second.oneStep) == "grok")
    #expect(second.facts == nil && second.failure == "cancelled")
    #expect(DeliveryRecord.engineName(backend: .apple, oneStep: first.oneStep) == "on-device")
}

@Test func spokenWordsUseWordBoundariesAndIgnorePunctuation() {
    #expect(DeliveryRecord.wordCount("") == 0)
    #expect(DeliveryRecord.wordCount("  \n … !!! 👋 ") == 0)
    #expect(DeliveryRecord.wordCount("Hello, world!\nThree more words.") == 5)
    #expect(DeliveryRecord.wordCount("I can't deploy 42 builds.") == 5)
}

@Test func spokenWordsAccumulateOnlyOnceAfterSuccessfulDelivery() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let raw = "um send this no wait send that"
    var ledger = RecordingLedger()
    ledger.register(1)
    ledger.recognized(LocalSpeech.Facts(generation: 1, raw: raw, engine: .apple,
        speechMillis: 1, fallback: nil, cleanup: nil, at: 0))
    ledger.record(1, .copied(attributableCounter: nil))
    ledger.record(1, .pasteSent)
    #expect(ledger.finished(1, inFlight: true) == nil)
    let finished = ledger.finished(1, inFlight: false)
    let entry = try #require(finished)
    let delivered = DeliveryRecord.addToDay(speech: nil, cleanup: nil,
        count: DeliveryRecord.didDeliver(entry.results), day: Application.dayKey(now),
        total: 0, dictations: 2, words: 10, allTimeWords: 100,
        spokenWords: DeliveryRecord.wordCount(entry.facts?.raw ?? ""), now: now)
    #expect(delivered.words == 17)
    #expect(delivered.allTimeWords == 107)
    #expect(ledger.finished(1, inFlight: false) == nil)
    for results: [EffectResult] in [[], [.failed("cancelled")]] {
        let refused = DeliveryRecord.addToDay(speech: 0.01, cleanup: nil,
            count: DeliveryRecord.didDeliver(results), day: delivered.day, total: delivered.total,
            dictations: delivered.dictations, words: delivered.words, allTimeWords: delivered.allTimeWords,
            spokenWords: 7, now: now)
        #expect(refused.words == 17)
        #expect(refused.allTimeWords == 107)
    }
    let nextDay = DeliveryRecord.addToDay(speech: nil, cleanup: nil, count: true,
        day: delivered.day, total: delivered.total, dictations: delivered.dictations,
        words: delivered.words, allTimeWords: delivered.allTimeWords, spokenWords: 3,
        now: now.addingTimeInterval(86400))
    #expect(nextDay.words == 3)
    #expect(nextDay.allTimeWords == 110)
}

@Test func recoveryCountsOnceEvenAfterTheDeliveryLogClosed() {
    var counter = RecordingWordCounter()
    let facts = LocalSpeech.Facts(generation: 8, raw: "three spoken words", engine: .apple,
        speechMillis: 1, fallback: nil, cleanup: nil, at: 10)
    counter.recognized(facts)
    let failed = counter.delivered(8, result: .failed("clipboard unavailable"))
    #expect(failed == nil)
    let recovered = counter.delivered(8, result: .copied(attributableCounter: nil))
    #expect(recovered == 3)
    counter.recognized(facts)
    let pasted = counter.delivered(8, result: .pasteSent)
    #expect(pasted == nil)
    counter.purge(now: 611)
    let expired = counter.delivered(8, result: .copied(attributableCounter: nil))
    #expect(expired == nil)
}

@Test func wordCounterKeepsValidRecoveryAfterDelayedCleanup() {
    var counter = RecordingWordCounter()
    counter.recognized(LocalSpeech.Facts(generation: 9, raw: "three spoken words", engine: .apple,
        speechMillis: 1, fallback: nil, cleanup: nil, at: 100))
    // Cleanup completes at 105; policy recovery remains valid until 705.
    counter.purge(now: 701, recovering: 9)
    let recovered = counter.delivered(9, result: .copied(attributableCounter: nil))
    #expect(recovered == 3)
    counter.purge(now: 706)
    let expired = counter.delivered(9, result: .pasteSent)
    #expect(expired == nil)
}

@Test func freshRecoveryDeliveryIDsKeepOneOriginalWordCount() {
    var counter = RecordingWordCounter()
    counter.recognized(LocalSpeech.Facts(generation: 8, raw: "three spoken words", engine: .apple,
        speechMillis: 1, fallback: nil, cleanup: nil, at: 100))
    counter.bindDelivery(10, to: 8)
    counter.purge(now: 701, recovering: 10)
    let failed = counter.delivered(10, result: .failed("synthetic refusal"))
    #expect(failed == nil)
    counter.bindDelivery(11, to: 8)
    let recovered = counter.delivered(11, result: .copied(attributableCounter: 1))
    #expect(recovered == 3)
    counter.bindDelivery(12, to: 8)
    let repeated = counter.delivered(12, result: .axConfirmed)
    #expect(repeated == nil)
    #expect(counter.delivered(8, result: .pasteSent) == nil)
}
@Test func recoveredRecognitionCountsRawWordsOnceAndExpires() {
    var counter = RecordingWordCounter()
    counter.recognized(20, raw: "five words before any cleanup", at: 100)
    let words = counter.delivered(20, result: .copied(attributableCounter: 1))
    #expect(words == 5)
    counter.bindDelivery(21, to: 20)
    #expect(counter.delivered(21, result: .pasteSent) == nil)
    counter.recognized(22, raw: "expired words", at: 100)
    counter.bindDelivery(23, to: 22); counter.purge(now: 701)
    #expect(counter.delivered(23, result: .copied(attributableCounter: 2)) == nil)
}

@Test func validHistoryKeepsAnUncountedRecordingAcrossTheRawFactDeadline() {
    var counter = RecordingWordCounter()
    counter.recognized(8, raw: "three spoken words", at: 100)
    counter.purge(now: 701, preserving: [8])
    counter.bindDelivery(10, to: 8)
    let recovered = counter.delivered(10, result: .copied(attributableCounter: 1))
    #expect(recovered == 3)
    counter.purge(now: 706)
    #expect(counter.delivered(8, result: .pasteSent) == nil)
}

@Test func asynchronousRecleanKeepsTheLiveWordCountIdentity() {
    var current = HistoryEntry(text: "Send these three words.", at: Date(), raw: "um send these three words")
    let captured = current
    var counter = RecordingWordCounter()
    current.wordCountGeneration = 1
    counter.recognized(1, raw: current.raw!, at: 0)
    #expect(counter.delivered(1, result: .copied(attributableCounter: 1)) == 5)
    let completed = HistoryEntry(text: "Send these three words.", at: captured.at,
        raw: captured.raw, wordCountGeneration: captured.wordCountGeneration, id: captured.id)
    current.applyReclean(completed)
    #expect(current.wordCountGeneration == 1)
    if let original = current.wordCountGeneration { counter.bindDelivery(2, to: original) }
    else { counter.recognized(2, raw: current.raw!, at: 0) }
    #expect(counter.delivered(2, result: .copied(attributableCounter: 2)) == nil)
}

@MainActor @Test func retryPanelKeepsStableHistoryIdentityAcrossRecleanBillingChanges() {
    var entry = HistoryEntry(text: "Send these three words.", at: Date(), raw: "um send these three words", usageRecordingID: UUID())
    let id = entry.id
    entry.usageRecordingID = UUID()
    #expect(Application.recoveryEntryIndex([entry], id: id, text: entry.text) == 0)
    #expect(Application.recoveryEntryIndex([entry], id: id, text: "older offered text") == nil)
    #expect(Application.recoveryEntryIndex([entry], id: UUID(), text: entry.text) == nil)
}

@Test func wordsFooterExpiresTheDailyCountWithoutChangingLifetimeTotal() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let previous = Application.dayKey(now.addingTimeInterval(-86400))
    #expect(DeliveryRecord.wordsFooter(today: 120, allTime: 1_234, day: previous, now: now) == "1,234 all-time")
    #expect(DeliveryRecord.wordsFooter(today: 120, allTime: 0, day: nil, now: now) == nil)
    #expect(DeliveryRecord.wordsFooter(today: 120, allTime: 1_234, day: Application.dayKey(now), now: now)
        == "120 words today · 1,234 all-time")
}
