import Foundation

public struct AppPreset: Codable, Equatable, Sendable {
    public enum Style: String, CaseIterable, Codable, Sendable { case strict, clean, concise, natural }
    public var bundleID: String
    public var engine: RecoveryConfiguration.Engine?
    public var speechModel: String?
    public var cleanupModel: String?
    public var style: Style?
    public init(bundleID: String, engine: RecoveryConfiguration.Engine? = nil, speechModel: String? = nil, cleanupModel: String? = nil, style: Style? = nil) {
        self.bundleID = bundleID; self.engine = engine; self.speechModel = speechModel; self.cleanupModel = cleanupModel; self.style = style
    }
    public static func resolve(bundleID: String?, presets: [AppPreset], global: RecoveryConfiguration, strictApps: Set<String>, literalApps: Set<String>) -> ResolvedAppPreset {
        let preset = presets.first { $0.bundleID == bundleID }
        var config = global
        if let engine = preset?.engine { config.engine = engine }
        if let model = preset?.speechModel { config.speechModel = model }
        if let model = preset?.cleanupModel { config.cleanupModel = model }
        var style = preset?.style ?? (global.smart ? .natural : .clean)
        // Chat and coding apps get text that only loses fillers and gains punctuation; never reworded.
        if preset?.style == nil, let bundleID, literalApps.contains(bundleID) { style = .clean }
        if let bundleID, strictApps.contains(bundleID) { style = .strict }
        if style == .strict { config.cleanupEnabled = false }
        config.smart = style == .natural
        config.writingStyle = style.rawValue
        return ResolvedAppPreset(configuration: config,style: style,cleanupOverride: preset?.cleanupModel != nil,
            speechOverride: preset?.speechModel != nil)
    }
}
public struct ResolvedAppPreset: Equatable, Sendable {
    public let configuration: RecoveryConfiguration
    public let style: AppPreset.Style
    public let cleanupOverride: Bool
    public let speechOverride: Bool
    // A preset naming a model that has gone from the catalogue still dictates, on the global model.
    public func falling(backTo global: RecoveryConfiguration, speechAvailable: (String) -> Bool, cleanupAvailable: (String) -> Bool) -> ResolvedAppPreset {
        var config = configuration
        let speechGone = speechOverride && config.engine == .cloud && !speechAvailable(config.speechModel)
        let cleanupGone = cleanupOverride && config.cleanupEnabled && !cleanupAvailable(config.cleanupModel ?? "")
        if speechGone { config.speechModel = global.speechModel }
        if cleanupGone { config.cleanupModel = global.cleanupModel }
        return ResolvedAppPreset(configuration: config, style: style, cleanupOverride: cleanupOverride && !cleanupGone,
                                 speechOverride: speechOverride && !speechGone)
    }
}
