import AppKit
import ApplicationServices
import Carbon
import CursusCore

// After a paste, the field it went into is watched for a minute. If the user
// fixes one misheard name inside the pasted text ("Vassal" -> "Vercel"), the fix
// is reported so it can join the dictionary. The field's text is read on this
// Mac only, on a background queue; it is never stored, logged or sent anywhere.
// What the watch did (started, skipped and why, learned, stopped) goes to
// learning.jsonl, without any text.
@MainActor final class CorrectionWatch {
    static let window: TimeInterval = 60
    static let interval: TimeInterval = 2
    var learned: ((CorrectionLearner.Correction) -> Void)?
    private nonisolated(unsafe) var element: AXUIElement?
    private var pid: pid_t = 0
    private var app: String?
    private var pasted = ""
    private var until: TimeInterval = 0
    private var checkedAt: TimeInterval = 0
    private var reading = false
    private var session = 0
    // The field's text once the paste landed, and where the pasted text starts in it.
    private var baseline: (text: String, at: Int)?
    private var settled: String?
    private let queue = DispatchQueue(label: "au.com.mykoala.mercurius.correction-watch", qos: .utility)

    // `field` is the exact element the paste was delivered to (NativeContext.deliveredField),
    // so no focus query happens here and a different field can never be watched.
    func start(pasted text: String, field: FieldHandle?, now: TimeInterval) {
        stop()
        let front = NSWorkspace.shared.frontmostApplication
        app = front?.bundleIdentifier
        // A blind paste: the app shows macOS no focused field (many Electron and web apps).
        guard let field else { return log("skipped", "no field visible") }
        guard !IsSecureEventInputEnabled() else { return log("skipped", "secure input") }
        guard !TranscriptCleanup.isCodeShaped(text) else { return log("skipped", "technical text") }
        var owner: pid_t = 0
        guard AXUIElementGetPid(field.element, &owner) == .success, let front, front.processIdentifier == owner
        else { return log("skipped", "field's app isn't frontmost") }
        guard !AICleanup.terminals.contains(front.bundleIdentifier ?? "") else { return log("skipped", "terminal") }
        AXUIElementSetMessagingTimeout(field.element, 0.2)
        element = field.element; pid = owner; pasted = text; until = now + Self.window; checkedAt = now - Self.interval
        log("watching")
    }
    func stop() { element = nil; pasted = ""; baseline = nil; settled = nil; session += 1 }
    private func stop(_ event: String, _ reason: String? = nil) { log(event, reason); stop() }
    private func log(_ event: String, _ reason: String? = nil) {
        DeliveryLog.learning.append(LearningEvent(time: Date(), event: event, reason: reason, app: app))
    }

    func tick(now: TimeInterval) {
        guard let field = element, !reading else { return }
        // No baseline after a minute: the paste never showed up in the field as sent.
        guard now <= until else { return baseline == nil ? stop("no-baseline", "pasted text not found after the caret") : stop("expired") }
        guard now - checkedAt >= Self.interval else { return }
        checkedAt = now
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, !IsSecureEventInputEnabled() else { return }
        reading = true
        let current = session
        nonisolated(unsafe) let target = field
        queue.async { [weak self] in
            let snapshot = Self.read(target)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reading = false
                    guard current == self.session, let snapshot else { return }
                    self.handle(snapshot)
                }
            }
        }
    }

    private func handle(_ snapshot: (text: String, caret: Int?)) {
        guard let before = baseline else {
            // The paste lands a moment after it's sent. The caret then sits right after
            // the pasted text: that both proves the paste went into this field and pins
            // which copy of the words is ours.
            guard let start = Self.pastedStart(in: snapshot.text, pasted: pasted, caret: snapshot.caret) else { return }
            // Learn only when the pasted words appear once: with a second copy an edit's
            // place can't be pinned to ours.
            guard Self.occurrences(of: pasted, in: snapshot.text) == 1 else { return stop("stopped", "pasted text appears twice") }
            baseline = (snapshot.text, start)
            return
        }
        if Self.occurrences(of: pasted, in: snapshot.text) > 1 { return stop("stopped", "pasted text appears twice") }
        // Act only on text that has stayed the same for a poll, so a word half-typed mid-fix ("Vers") is never learned.
        guard snapshot.text == before.text || snapshot.text == settled else { settled = snapshot.text; return }
        switch CorrectionLearner.compare(before: before.text, pastedAt: before.at, pasted: pasted, now: snapshot.text,
                                         isCommonWord: Self.isCommonWord) {
        case let .learned(fix):
            log("learned", fix.addsReplacement ? "name and replacement" : "name only")
            // Keep watching: a second name in the same dictation gets fixed a moment later.
            let length = pasted.count + snapshot.text.count - before.text.count
            let text = Array(snapshot.text)
            if length > 0, before.at + length <= text.count {
                pasted = String(text[before.at..<(before.at + length)]); baseline = (snapshot.text, before.at)
            } else { stop() }
            learned?(fix)
        case let .outside(at): baseline = (snapshot.text, at)
        case .unchanged: break
        case .rewritten: stop("stopped", "edit isn't a name fix")
        }
    }

    // Off the main thread: the field's text and caret (as a character offset), only
    // if it is provably not a password field and not a huge document.
    private nonisolated static func read(_ field: AXUIElement) -> (text: String, caret: Int?)? {
        var subrole: CFTypeRef?
        switch AXUIElementCopyAttributeValue(field, kAXSubroleAttribute as CFString, &subrole) {
        case .success: if subrole as? String == kAXSecureTextFieldSubrole as String { return nil }
        case .noValue, .attributeUnsupported: break   // ordinary fields often have no subrole
        default: return nil                            // can't tell: fail closed
        }
        var count: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
              let characters = count as? Int, characters <= CorrectionLearner.limit else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String, text.count <= CorrectionLearner.limit else { return nil }
        var range: CFTypeRef?
        var caret: Int?
        if AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
           let range, CFGetTypeID(range) == AXValueGetTypeID() {
            var selected = CFRange()
            if AXValueGetValue(range as! AXValue, .cfRange, &selected), selected.length == 0,
               selected.location <= text.utf16.count {
                // AX counts UTF-16 units; the learner counts characters.
                let index = String.Index(utf16Offset: selected.location, in: text)
                caret = text.distance(from: text.startIndex, to: index)
            }
        }
        return (text, caret)
    }

    // Where the paste landed: right before the caret, or, in editors whose caret doesn't report
    // that (Electron apps), the only place those words appear.
    static func pastedStart(in text: String, pasted: String, caret: Int?) -> Int? {
        if let caret, caret >= pasted.count, caret <= text.count,
           Array(text)[(caret - pasted.count)..<caret].elementsEqual(pasted) { return caret - pasted.count }
        guard occurrences(of: pasted, in: text) == 1, let range = text.range(of: pasted) else { return nil }
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }
    static func occurrences(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return text.components(separatedBy: needle).count - 1
    }

    // Ordinary English per the system spell checker, as the user spelled it:
    // "blue" and "Monday" are words, "Vercel" is a name.
    static func isCommonWord(_ word: String) -> Bool {
        let miss = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: "en",
                                                       wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return miss.location == NSNotFound
    }
}

// What a learned fix does to the saved dictionary, kept apart from the UI so it can be tested.
enum LearnedWord {
    static func apply(_ fix: CorrectionLearner.Correction,
                      to saved: (terms: [String], replacements: [String: String]), builtIn: [String])
        -> (terms: [String], replacements: [String: String]) {
        var result = saved
        if fix.addsReplacement && !fix.isCaseOnly { result.replacements[fix.heard.lowercased()] = fix.correct }
        if let index = result.terms.firstIndex(where: { $0.lowercased() == fix.correct.lowercased() }) {
            result.terms[index] = fix.correct   // the user's spelling wins: "github" -> "GitHub"
        } else if !builtIn.contains(where: { $0.lowercased() == fix.correct.lowercased() }),
                  Vocabulary(terms: builtIn + saved.terms).terms.count < Vocabulary.maxTerms {
            result.terms.append(fix.correct)
        }
        return result
    }
}
