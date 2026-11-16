import Foundation

@MainActor public protocol PolicyClock: AnyObject {
    var now: TimeInterval { get }
}

@MainActor public final class MonotonicClock: PolicyClock {
    public init() {}
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

public enum Binding: String, Sendable {
    case fn, controlOption
    public var displayName: String { self == .fn ? "Fn" : "Control + Option" }
    public func chord(_ key: String) -> String { displayName + " + " + key }
}
public enum Mode: Sendable { case held, toggle }
public enum State: Equatable, Sendable {
    case idle, startingHeld, startingToggle, recordingHeld, recordingToggle
    case finalizing, delivering, recoverableError
}
public enum Authorization: Equatable, Sendable {
    case unknown, authorized, denied
}
public struct Availability: Equatable, Sendable {
    public var frameworkAvailable: Bool
    public var localeSupported: Bool
    public var assetsInstalled: Bool
    public var microphone: Authorization
    public var speech: Authorization
    public init(frameworkAvailable: Bool, localeSupported: Bool, assetsInstalled: Bool,
                microphone: Authorization, speech: Authorization) {
        self.frameworkAvailable = frameworkAvailable
        self.localeSupported = localeSupported
        self.assetsInstalled = assetsInstalled
        self.microphone = microphone
        self.speech = speech
    }
    public var ready: Bool {
        frameworkAvailable && localeSupported && assetsInstalled
        && microphone == .authorized && speech == .authorized
    }
    public var explanation: String {
        if !frameworkAvailable { return "SpeechAnalyzer unavailable" }
        if !localeSupported { return "This language isn't available for on-device speech" }
        if !assetsInstalled { return "Choose your language for on-device speech in Settings" }
        if microphone != .authorized { return "Microphone authorization unavailable" }
        if speech != .authorized { return "Speech authorization unavailable" }
        return "Local recognition available"
    }
}
public enum Classification: Equatable, Sendable {
    case normal, unknown, secure, terminal, remote, elevated, custom
}
public enum InsertionRoute: Equatable, Sendable {
    case unavailable, qualifiedAX, qualifiedClipboard
}
public struct SelectionAnchor: Equatable, Sendable {
    public let location: Int
    public let length: Int
    public init?(location: Int, length: Int) {
        guard location >= 0, length >= 0, location <= Int.max - length else { return nil }
        self.location = location; self.length = length
    }
}
public struct Destination: Equatable, Sendable {
    public var process: String
    public var window: String
    public var element: String
    public var classification: Classification
    public var enabled: Bool
    public var editable: Bool
    public var route: InsertionRoute
    public var selection: SelectionAnchor?
    public init(process: String, window: String, element: String,
                classification: Classification, enabled: Bool, editable: Bool,
                route: InsertionRoute, selection: SelectionAnchor? = nil) {
        self.process = process
        self.window = window
        self.element = element
        self.classification = classification
        self.enabled = enabled
        self.editable = editable
        self.route = route
        self.selection = selection
    }
    public var qualified: Bool {
        classification == .normal && enabled && editable && route != .unavailable
    }
    public func sameIdentity(as other: Destination) -> Bool {
        process == other.process && window == other.window && element == other.element
    }
}
public struct Context: Equatable, Sendable {
    public var destination: Destination?
    public var secureEventInput: Bool
    public var clipboardCounter: Int?
    public init(destination: Destination?, secureEventInput: Bool = false,
                clipboardCounter: Int? = nil) {
        self.destination = destination
        self.secureEventInput = secureEventInput
        self.clipboardCounter = clipboardCounter
    }
    public var secure: Bool {
        secureEventInput || destination?.classification == .secure
    }
}
public struct Listener: Equatable, Sendable {
    public var shortcutsEnabled: Bool
    public var suppressingTapActive: Bool
    public var competingBindingsAcknowledged: Bool
    public init(shortcutsEnabled: Bool = false, suppressingTapActive: Bool = false,
                competingBindingsAcknowledged: Bool = false) {
        self.shortcutsEnabled = shortcutsEnabled
        self.suppressingTapActive = suppressingTapActive
        self.competingBindingsAcknowledged = competingBindingsAcknowledged
    }
    public var selected: Bool {
        shortcutsEnabled && suppressingTapActive && competingBindingsAcknowledged
    }
}
public enum KeyEvent: Sendable {
    case flags(fn: Bool, control: Bool, option: Bool)
    case spaceDown(repeated: Bool), spaceUp, escape(repeated: Bool)
    case otherKeyDown
}
public struct CommitToken: Hashable, Sendable {
    public let serial: UInt64
    public let generation: UInt64
    public init(serial: UInt64, generation: UInt64) {
        self.serial = serial
        self.generation = generation
    }
}
public struct BufferToken: Hashable, Sendable {
    public let serial: UInt64
    public let generation: UInt64
}
public enum Effect: Equatable, Sendable {
    case clipboardWrite(CommitToken, String, expectedCounter: Int?)
    case axInsert(CommitToken, Destination, String)
    case pasteKey(CommitToken, Destination)
}
public enum EffectResult: Equatable, Sendable {
    // An attributable counter must come from a qualified native ownership mechanism.
    // A post-write sample alone is not sufficient; use nil when uncertain.
    case copied(attributableCounter: Int?)
    case axConfirmed
    case axSent
    case pasteSent
    case failed(String)
}
public enum Outcome: Equatable, Sendable {
    case recognized, copied, insertedConfirmed, insertedUnconfirmed, pasteSentUnconfirmed, deliveryBlocked
    public var label: String {
        switch self {
        case .recognized: "Text recognised"
        case .copied: "Copied to clipboard"
        case .insertedConfirmed: "Inserted — readback confirmed"
        case .insertedUnconfirmed: "Insertion submitted — unconfirmed"
        case .pasteSentUnconfirmed: "Paste sent — unconfirmed"
        case .deliveryBlocked: "Delivery blocked"
        }
    }
}
public enum Action: Equatable, Sendable {
    // Only explicit user admission emits startupRequested. Passive discovery is external.
    case startupRequested(UInt64)
    case sampleStartClipboard(UInt64)
    case captureStarted(UInt64)
    case finalizeRequested(UInt64, timed: Bool)
    case closeAdapters(UInt64)
    case bufferGranted(BufferToken, bytes: Int)
    case commitReady(CommitToken)
    case effect(Effect)
    case outcome(UInt64, Outcome)
    case decision(UInt64, [Outcome])
    case status(String)
    case recoveryCleared
}
public enum Event: Sendable {
    case captureLimitReached(UInt64)
    case startupCompleted(UInt64, Availability, acquiredAdapter: Bool)
    case startClipboardSample(UInt64, Int)
    case partial(UInt64, String)
    case final(UInt64, String)
    case recognitionFailed(UInt64, String)
    case observed(Context)
    case interrupted(String)
    case tick
}
public struct Recovery: Equatable, Sendable {
    public let generation: UInt64
    public let text: String
    public let receivedAt: TimeInterval
    public var ownedClipboardCounter: Int?
}
public enum RecoveryAction: Sendable { case copy, paste }
