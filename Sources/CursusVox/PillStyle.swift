import AppKit

// Small native presets share the same rendered Koa clips. No new assets or renderer.
struct PillStyle {
    enum Theme: String, CaseIterable {
        case amber, ocean, mint
        var title: String { rawValue.capitalized }
        var color: NSColor {
            switch self {
            case .amber: NSColor(srgbRed: 1, green: 0.55, blue: 0.33, alpha: 1)
            case .ocean: NSColor(srgbRed: 0.36, green: 0.68, blue: 1, alpha: 1)
            case .mint: NSColor(srgbRed: 0.43, green: 0.86, blue: 0.70, alpha: 1)
            }
        }
    }
    enum Motion: String, CaseIterable {
        case gentle, expressive, still
        var title: String { rawValue.capitalized }
        var amount: CGFloat { self == .still ? 0 : self == .gentle ? 0.55 : 1 }
    }
    let theme: Theme
    let motion: Motion
    init(theme: String?, motion: String?) {
        self.theme = Theme(rawValue: theme ?? "") ?? .amber
        self.motion = Motion(rawValue: motion ?? "") ?? .gentle
    }
    static var current: PillStyle {
        PillStyle(theme: UserDefaults.standard.string(forKey: "pillTheme"),
                  motion: UserDefaults.standard.string(forKey: "pillMotion"))
    }
}
