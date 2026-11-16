import Foundation
import CursusCore

// What each recording's deliveries actually did, kept per generation, so its
// log line is written only after its own deliveries finish and never from a
// later recording's state.
struct RecordingLedger {
    struct Entry {
        var results: [EffectResult] = []
        var target: Destination?
        var secure = false
        var app: String?
        var facts: LocalSpeech.Facts?
        var oneStep = false       // engine mode captured when recording is admitted
        var attempted = false     // reached delivery, even if the policy refused it
        var failure: String?      // why the recording ended badly, kept while its log line waits
    }
    private var entries: [UInt64: Entry] = [:]
    private var awaiting: Set<UInt64> = []
    // Only recordings registered when they start are tracked, until they are
    // logged. A later Copy last or Paste last for an old recording is ignored, so
    // no entry (and no transcript) outlives its recording.
    private var open: Set<UInt64> = []
    mutating func register(_ generation: UInt64, oneStep: Bool = false) {
        guard open.insert(generation).inserted else { return }
        entries[generation] = Entry(oneStep: oneStep)
    }
    private func isClosed(_ generation: UInt64) -> Bool { !open.contains(generation) }
    private mutating func close(_ generation: UInt64) { open.remove(generation) }

    mutating func recognized(_ facts: LocalSpeech.Facts) {
        guard !isClosed(facts.generation) else { return }
        entries[facts.generation, default: Entry()].facts = facts
    }

    mutating func delivering(_ generation: UInt64, context: Context, app: String?, facts: LocalSpeech.Facts?) {
        guard !isClosed(generation) else { return }
        var entry = entries[generation] ?? Entry()
        entry.attempted = true
        entry.target = context.destination; entry.secure = context.secure; entry.app = app
        if let facts { entry.facts = facts }
        entries[generation] = entry
    }
    mutating func record(_ generation: UInt64, _ result: EffectResult) {
        guard !isClosed(generation) else { return }
        entries[generation, default: Entry()].results.append(result)
    }
    // The recording ended. Returns its entry to log now, or nil while one of
    // its deliveries is still running (it is logged by delivered(_:inFlight:)).
    mutating func finished(_ generation: UInt64, inFlight: Bool, failure: String? = nil) -> Entry? {
        guard !isClosed(generation) else { return nil }
        if let failure { entries[generation, default: Entry()].failure = failure }
        guard !inFlight else { awaiting.insert(generation); return nil }
        awaiting.remove(generation)
        close(generation)
        return entries.removeValue(forKey: generation) ?? Entry()
    }
    // A delivery finished; returns entries that were waiting for it.
    mutating func delivered(inFlight: (UInt64) -> Bool) -> [(UInt64, Entry)] {
        let ready = awaiting.filter { !inFlight($0) }
        awaiting.subtract(ready)
        ready.forEach { close($0) }
        return ready.sorted().map { ($0, entries.removeValue(forKey: $0) ?? Entry()) }
    }
}

// Numeric accounting survives log closure so a later recovery can count once.
// Entries expire with the recovery window and never retain transcript text.
struct RecordingWordCounter {
    private struct Entry { var words: Int; var at: TimeInterval; var counted = false }
    private var entries: [UInt64: Entry] = [:]
    private var deliverySources: [UInt64: UInt64] = [:]

    mutating func recognized(_ facts: LocalSpeech.Facts) {
        recognized(facts.generation, raw: facts.raw, at: facts.at)
    }
    mutating func recognized(_ generation: UInt64, raw: String, at: TimeInterval) {
        guard entries[generation] == nil else { return }
        entries[generation] = Entry(words: DeliveryRecord.wordCount(raw), at: at)
    }
    mutating func bindDelivery(_ delivery: UInt64, to recording: UInt64) {
        guard let entry = entries[recording], !entry.counted else { return }
        deliverySources[delivery] = recording
    }

    mutating func delivered(_ generation: UInt64, result: EffectResult) -> Int? {
        let recording = deliverySources[generation] ?? generation
        guard DeliveryRecord.didDeliver([result]), var entry = entries[recording], !entry.counted else { return nil }
        entry.counted = true
        entries[recording] = entry
        deliverySources = deliverySources.filter { $0.value != recording }
        return entry.words
    }

    mutating func purge(now: TimeInterval, recovering: UInt64? = nil, preserving: Set<UInt64> = []) {
        let original = recovering.map { deliverySources[$0] ?? $0 }
        entries = entries.filter { $0.key == original || preserving.contains($0.key) || now - $0.value.at < Policy.recoveryLifetime }
        deliverySources = deliverySources.filter { entries[$0.value] != nil }
    }
}
