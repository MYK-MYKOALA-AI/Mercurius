import Foundation

public enum CleanupStyle: Sendable { case smart, strict }

public enum AppCleanup {
    public static func style(bundleID: String?, strictApps: Set<String>, defaultSmart: Bool) -> CleanupStyle {
        if let bundleID, !bundleID.isEmpty, strictApps.contains(bundleID) { return .strict }
        return defaultSmart ? .smart : .strict
    }

    // Bundle identifiers are case-sensitive. Keep saved order and bound the editor's input.
    public static func parseApps(_ text: String) -> [String] {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")
        var seen: Set<String> = []
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let id = line.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, id.utf8.count <= 255, id.allSatisfy(allowed.contains), seen.insert(id).inserted else { return nil }
            return id
        }.prefix(100).map { $0 }
    }
}
