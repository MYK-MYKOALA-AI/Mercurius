/// Meeting shortcuts remain unavailable until the local capture, library and answer paths qualify.
public enum MeetingCommand: Sendable, Equatable {
    case toggleRecording, suggestAnswer

    public init?(keyCode: Int64) {
        switch keyCode {
        case 46: self = .toggleRecording
        case 35: self = .suggestAnswer
        default: return nil
        }
    }

    public enum Unavailable: Sendable, Equatable {
        case captureAndLibraryNotReady, localAnswerEngineNotReady

        public var message: String {
            switch self {
            case .captureAndLibraryNotReady: "Meeting recording unavailable: local capture and library are not ready"
            case .localAnswerEngineNotReady: "Suggested answers unavailable: no local answer engine is ready"
            }
        }
    }

    public var unavailable: Unavailable {
        switch self {
        case .toggleRecording: .captureAndLibraryNotReady
        case .suggestAnswer: .localAnswerEngineNotReady
        }
    }
}
