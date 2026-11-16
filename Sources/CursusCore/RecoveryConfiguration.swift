import Foundation

public struct RecoveryConfiguration: Codable, Equatable, Sendable {
    public enum Engine: String, Codable, Sendable { case local, cloud, oneStep, elevenLabs }
    public var engine: Engine
    public var speechModel: String
    public var cleanupModel: String?
    public var cleanupEnabled: Bool
    public var writingStyle: String? = nil
    public var smart: Bool
    public init(engine: Engine, speechModel: String, cleanupModel: String? = nil, cleanupEnabled: Bool = false, smart: Bool = true) {
        self.engine = engine; self.speechModel = speechModel; self.cleanupModel = cleanupModel
        self.cleanupEnabled = cleanupEnabled; self.smart = smart
    }
    // A recording recovered without its stored settings (an unreadable outbox index) must not inherit
    // the current engine: that could upload audio the user recorded on-device after they switched to a
    // cloud engine, without them choosing to. On-device with no AI cleanup is the only mode that sends
    // neither audio nor text, so it is the default for a recording whose engine is unknown. Only the
    // explicit "use current engine" action opts such a recording into the current configuration.
    public static let recovered = RecoveryConfiguration(engine: .local, speechModel: "", cleanupEnabled: false)
    public static func retryConfiguration(stored: RecoveryConfiguration?, current: RecoveryConfiguration,
                                          useCurrent: Bool) -> RecoveryConfiguration {
        if useCurrent { return current }
        return stored ?? recovered
    }
}
