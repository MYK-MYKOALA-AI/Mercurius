import Foundation

// The languages someone chose for on-device speech. Apple reserves at most five per app, and
// the recogniser listens in one at a time, so one of them is active.
public struct SpeechLanguageChoice: Equatable, Sendable {
    public static let limit = 5
    public private(set) var chosen: [String]
    public private(set) var active: String?

    public init(chosen: [String] = [], active: String? = nil) {
        var seen = Set<String>()
        self.chosen = Array(chosen.filter { seen.insert($0).inserted }.prefix(Self.limit))
        self.active = active.flatMap { self.chosen.contains($0) ? $0 : nil } ?? self.chosen.first
    }
    // False when already at the limit; nothing changes then.
    @discardableResult public mutating func toggle(_ id: String) -> Bool {
        if let index = chosen.firstIndex(of: id) {
            chosen.remove(at: index)
            if active == id { active = chosen.first }
            return true
        }
        guard chosen.count < Self.limit else { return false }
        chosen.append(id)
        if active == nil { active = id }
        return true
    }
    public mutating func activate(_ id: String) { if chosen.contains(id) { active = id } }

    private static func key(_ id: String) -> String { id.replacingOccurrences(of: "-", with: "_").lowercased() }
    private static func language(_ id: String) -> String { String(key(id).prefix { $0 != "_" }) }

    // What to tick by default: the Mac's own language, the same language in another region, or English.
    public static func suggested(preferred: [String], supported: [String]) -> String? {
        for wanted in preferred {
            if let exact = supported.first(where: { key($0) == key(wanted) }) { return exact }
            if let near = supported.first(where: { language($0) == language(wanted) }) { return near }
        }
        return ["en_AU", "en_US"].lazy.compactMap { wanted in supported.first { key($0) == key(wanted) } }.first
    }
    // Which locales to try for recognition, best first.
    public static func lookupOrder(active: String?, preferred: [String]) -> [String] {
        var seen = Set<String>()
        return ([active].compactMap { $0 } + preferred + ["en-AU", "en-US"]).filter { seen.insert(key($0)).inserted }
    }
}
