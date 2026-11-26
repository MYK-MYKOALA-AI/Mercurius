import Foundation

public enum Quality {
    public static let referencePhrases = [
        "Please write the meeting notes and send the summary after lunch tomorrow.",
        "The next appointment is on Tuesday at ten thirty in the morning.",
        "I will bring three notebooks two pens and a bottle of water.",
        "Our project needs a clear plan before we start building the new app.",
        "Jordan and Alex will review the first version together on Friday afternoon.",
        "Open the settings page and check that the microphone permission is enabled.",
        "The total price is twenty five dollars and delivery costs five dollars.",
        "This sentence should end with a full stop and the next begins here.",
        "I said blue actually I meant green please keep all these spoken words.",
        "Keep the original text available until I copy it or clear the session."
    ]
    public static func words(_ text: String) -> [String] {
        let normalized = text.precomposedStringWithCanonicalMapping.lowercased()
        let replaced = String(String.UnicodeScalarView(normalized.unicodeScalars.map {
            CharacterSet.punctuationCharacters.contains($0) ? Unicode.Scalar(32)! : $0
        }))
        return replaced.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
    public static func edits(reference: [String], hypothesis: [String]) -> Int {
        var previous = Array(0...hypothesis.count)
        for (i, word) in reference.enumerated() {
            var row = [i + 1]
            for (j, candidate) in hypothesis.enumerated() {
                row.append(min(row[j] + 1, previous[j + 1] + 1,
                               previous[j] + (word == candidate ? 0 : 1)))
            }
            previous = row
        }
        return previous[hypothesis.count]
    }
    public struct Score: Equatable, Sendable {
        public let referenceWords: Int
        public let editCount: Int
        public var wer: Double { referenceWords == 0 ? 0 : Double(editCount) / Double(referenceWords) }
        public var meetsTarget: Bool { referenceWords >= 100 && wer <= 0.20 }
    }
    // Missing/error hypotheses are nil and contribute every reference word as deletions.
    // This method retains aggregate counts only; it does not log or persist hypotheses.
    public static func score(_ hypotheses: [String?]) -> Score {
        var count = 0
        var distance = 0
        for (index, phrase) in referencePhrases.enumerated() {
            let reference = words(phrase)
            let hypothesis = index < hypotheses.count ? words(hypotheses[index] ?? "") : []
            count += reference.count
            distance += edits(reference: reference, hypothesis: hypothesis)
        }
        return Score(referenceWords: count, editCount: distance)
    }
}
