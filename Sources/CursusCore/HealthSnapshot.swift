import Foundation

public enum HealthStatus: String, Codable, Sendable { case ready, needsAttention, checking, unknown }
public enum HealthCheckID: String, Codable, CaseIterable, Sendable {
    case microphoneCapture, transcription
    case microphone, speechPermission, accessibility, inputMonitoring, eventTap, localSpeech, credential, openRouter, elevenLabs
    public var title: String {
        switch self {
        case .microphone: "Microphone permission"
        case .microphoneCapture: "Microphone capture"
        case .transcription: "Recent transcription"
        case .speechPermission: "Speech Recognition permission"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .eventTap: "Keyboard listener"
        case .localSpeech: "On-device speech"
        case .credential: "Provider key"
        case .openRouter: "OpenRouter connection"
        case .elevenLabs: "ElevenLabs connection"
        }
    }
}
public enum HealthFailure: String, Codable, Sendable { case recognitionFailed, microphoneUnavailable, providerUnavailable }
public struct HealthRow: Equatable, Sendable {
    public let id: HealthCheckID
    public let status: HealthStatus
    public let detail: String
    public let checkedAt: Date
    public init(id: HealthCheckID,status: HealthStatus,detail: String,checkedAt: Date) {
        self.id = id; self.status = status; self.detail = detail; self.checkedAt = checkedAt
    }
}
public struct HealthSnapshot: Sendable {
    public let build: String
    public let engine: RecoveryConfiguration.Engine
    public let latestFailure: HealthFailure?
    public let rows: [HealthRow]
    public init(build: String,engine: RecoveryConfiguration.Engine,latestFailure: HealthFailure?,rows: [HealthRow]) {
        self.build = build; self.engine = engine; self.latestFailure = latestFailure; self.rows = rows
    }
    public var diagnostics: String {
        // Details may contain SDK wording. Export only typed status/error fields.
        (["Mercurius build: " + build, "Engine: " + engine.rawValue,
          "Latest failure: " + (latestFailure?.rawValue ?? "none")]
         + rows.map { "\($0.id.rawValue): \($0.status.rawValue) · \($0.checkedAt.ISO8601Format())" }).joined(separator: "\n")
    }
}
public struct HealthChecks: Sendable {
    private var serial: UInt64 = 0
    private var entries: [HealthCheckID: (token: UInt64,row: HealthRow)] = [:]
    public init() {}
    public mutating func invalidate() { serial &+= 1; entries.removeAll() }
    public mutating func begin(_ id: HealthCheckID,now: Date = Date()) -> UInt64 {
        serial &+= 1
        entries[id] = (serial,HealthRow(id: id,status: .checking,detail: "Checking provider metadata",checkedAt: now))
        return serial
    }
    @discardableResult public mutating func complete(_ id: HealthCheckID,token: UInt64,status: HealthStatus,detail: String,now: Date = Date()) -> Bool {
        guard entries[id]?.token == token else { return false }
        entries[id] = (token,HealthRow(id: id,status: status,detail: detail,checkedAt: now)); return true
    }
    public func row(_ id: HealthCheckID,now: Date = Date()) -> HealthRow {
        guard let row = entries[id]?.row, now.timeIntervalSince(row.checkedAt) < 60 else {
            let detail: String
            switch id {
            case .microphoneCapture: detail = "No recent capture test. Use Test microphone; permission alone does not prove capture."
            case .transcription: detail = "No recent successful transcription. Record explicitly; this check never sends audio."
            default: detail = "Not recently checked. Use Check provider."
            }
            return HealthRow(id: id,status: .unknown,detail: detail,checkedAt: now)
        }
        return row
    }
}
