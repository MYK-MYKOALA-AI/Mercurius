import AppKit

struct InstalledApp: Equatable { let name: String; let bundleID: String }
enum InstalledApps {
    static func list() -> [InstalledApp] {
        let manager = FileManager.default
        let roots = [URL(fileURLWithPath: "/Applications"),URL(fileURLWithPath: "/System/Applications"),manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var found: [String: InstalledApp] = [:]
        for root in roots {
            for url in (try? manager.contentsOfDirectory(at: root,includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent
                found[id] = InstalledApp(name: name,bundleID: id)
            }
        }
        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
