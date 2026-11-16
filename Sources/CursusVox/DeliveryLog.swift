import Foundation
import CursusCore
import os

// One line per recording: which engine ran, how long each stage took, and where
// the text went. It never contains transcript or field text.
struct DeliveryRecord: Codable, Equatable {
    var time: Date
    var engine: String            // "grok", "gemini" or "on-device"
    var speechModel: String? = nil
    var speechMs: Int? = nil
    var fallback: String? = nil   // why the selected engine wasn't the one used
    var cleanupModel: String? = nil  // nil: rule pass only
    var cleanupMs: Int? = nil
    var cleanupNote: String? = nil
    var app: String? = nil        // bundle identifier
    var classification: String? = nil
    var editable: Bool? = nil
    var outcome: String           // pasted, copied, refused, failed, discarded, retried
    var reason: String? = nil     // why it wasn't pasted
    var costUSD: Double? = nil    // speech + cleanup, as OpenRouter charged

    static func addToDay(speech: Double?, cleanup: Double?, count: Bool,
                         day: String?, total: Double, dictations: Int, words: Int = 0,
                         allTimeWords: Int = 0, spokenWords: Int = 0, now: Date)
        -> (cost: Double?, day: String, total: Double, dictations: Int, words: Int, allTimeWords: Int) {
        let today = Application.dayKey(now)
        let total = day == today ? total : 0
        let dictations = day == today ? dictations : 0
        let words = day == today ? words : 0
        let cost = (speech ?? 0) + (cleanup ?? 0)
        let added = count ? max(0, spokenWords) : 0
        return (cost > 0 ? cost : nil, today, total + cost, dictations + (count ? 1 : 0),
                words + added, max(0, allTimeWords) + added)
    }

    static func retry(oneStep: Bool, heardSpeech: Bool, cost: Double?, model: String? = nil, direct: Bool = false, now: Date = Date()) -> Self {
        Self(time: now, engine: direct ? "elevenlabs-direct" : engineName(backend: .cloud, oneStep: oneStep),
             speechModel: model ?? (oneStep ? CloudSpeech.oneStepModel : CloudSpeech.model),
             outcome: heardSpeech ? "retried" : "discarded", reason: heardSpeech ? nil : "no speech", costUSD: cost)
    }

    static func engineName(backend: SpeechBackend, oneStep: Bool) -> String {
        backend == .apple ? "on-device" : oneStep ? "gemini" : "grok"
    }

    // unknown: some of today's charges weren't reported, so the total is a floor ("+ unknown").
    static func daySummary(day: String?, total: Double, words: Int, allTimeWords: Int = 0,
                           unknown: Bool = false, now: Date = Date()) -> String? {
        guard day == Application.dayKey(now), words > 0 || total > 0 || unknown || allTimeWords > 0 else { return nil }
        let cost = String(format: "Today $%.3f", total) + (unknown ? " + unknown" : "")
        var parts = [cost]
        if words > 0 { parts.append("\(words.formatted()) word\(words == 1 ? "" : "s") today") }
        if allTimeWords > 0 { parts.append("\(allTimeWords.formatted()) all-time") }
        return parts.joined(separator: " · ")
    }
    // Word counts for a footer that already has a usage cost line from the ledger.
    static func wordsFooter(today: Int, allTime: Int, day: String?, now: Date = Date()) -> String? {
        let today = day == Application.dayKey(now) ? max(0, today) : 0
        let allTime = max(0, allTime)
        guard today > 0 || allTime > 0 else { return nil }
        var parts: [String] = []
        if today > 0 { parts.append("\(today.formatted()) word\(today == 1 ? "" : "s") today") }
        if allTime > 0 { parts.append("\(allTime.formatted()) all-time") }
        return parts.joined(separator: " · ")
    }

    // Count the speech result without retaining text. One-step engines may already remove fillers.
    static func wordCount(_ transcript: String) -> Int {
        var count = 0
        transcript.enumerateSubstrings(in: transcript.startIndex..., options: [.byWords, .substringNotRequired]) {
            _, _, _, _ in count += 1
        }
        return count
    }

    static func didDeliver(_ results: [EffectResult]) -> Bool {
        ["pasted", "copied"].contains(outcome(results))
    }

    enum Heard { case nothing, silence, speech }
    // Why a recording ended without any delivery, or nil if something was delivered.
    static func discardReason(results: [EffectResult], heard: Heard, failure: String?) -> String? {
        guard results.isEmpty else { return nil }
        if let failure { return failure }
        switch heard {
        case .nothing: return "stopped before a transcript"
        case .silence: return "no speech"
        case .speech: return "cancelled"
        }
    }
    static func outcome(_ results: [EffectResult]) -> String {
        if results.contains(where: { [.pasteSent, .axSent, .axConfirmed].contains($0) }) { return "pasted" }
        if results.contains(where: { if case .copied = $0 { true } else { false } }) { return "copied" }
        // Reached delivery but nothing was written: secure input, Copy Off, or a refused target.
        return results.isEmpty ? "refused" : "failed"
    }
}

// What "Learn from my corrections" did after a paste, so a fix that wasn't learned
// can be explained. Events and reasons only: never the field's, the pasted or the
// corrected text.
struct LearningEvent: Codable, Equatable {
    var time: Date
    var event: String           // watching, skipped, no-baseline, learned, stopped, expired, auto-added
    var reason: String? = nil
    var app: String? = nil      // bundle identifier
}

final class DeliveryLog: @unchecked Sendable {
    static let rotateAt = 1024 * 1024
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Mercurius", isDirectory: true)
    static let shared = DeliveryLog(directory: directory)
    static let learning = DeliveryLog(directory: directory, name: "learning.jsonl")
    private let logger = Logger(subsystem: "au.com.mykoala.mercurius", category: "delivery")
    private let lock = NSLock()
    let file: URL
    init(directory: URL, name: String = "deliveries.jsonl") { file = directory.appendingPathComponent(name) }

    func append(_ event: LearningEvent) {
        logger.info("learning event=\(event.event, privacy: .public) reason=\(event.reason ?? "-", privacy: .public) app=\(event.app ?? "-", privacy: .public)")
        write(event)
    }

    func append(_ record: DeliveryRecord) {
        logger.info("""
            delivery engine=\(record.engine, privacy: .public) speechMs=\(record.speechMs ?? -1) \
            cleanup=\(record.cleanupModel ?? "rules", privacy: .public) cleanupMs=\(record.cleanupMs ?? -1) \
            app=\(record.app ?? "-", privacy: .public) outcome=\(record.outcome, privacy: .public) \
            reason=\(record.reason ?? "-", privacy: .public)
            """)
        write(record)
    }

    private func write(_ record: some Encodable) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        lock.withLock {
            let manager = FileManager.default
            try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.deletingLastPathComponent().path)
            let owner: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
            if let size = (try? manager.attributesOfItem(atPath: file.path))?[.size] as? Int, size + line.count > Self.rotateAt {
                let old = file.appendingPathExtension("1")
                try? manager.removeItem(at: old)
                try? manager.moveItem(at: file, to: old)
                try? manager.setAttributes(owner, ofItemAtPath: old.path)
            }
            if !manager.fileExists(atPath: file.path) {
                manager.createFile(atPath: file.path, contents: nil, attributes: owner)
            }
            // A file left by an older build or another tool may be readable by others.
            guard (try? manager.setAttributes(owner, ofItemAtPath: file.path)) != nil else { return }
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
    }
}
