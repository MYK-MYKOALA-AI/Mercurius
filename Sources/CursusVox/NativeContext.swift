import AppKit
import ApplicationServices
import Carbon
import CursusCore
import CursusPlatform

private struct AXTextPort: TextInsertionPort {
    let field: AXUIElement
    let window: AXUIElement
    let deadline: ObservationDeadline
    private func prepare(_ element: AXUIElement) -> Bool {
        let remaining = deadline.remaining()
        guard remaining > 0 else { return false }
        return AXUIElementSetMessagingTimeout(element, Float(min(0.05, remaining))) == .success
    }
    var isFocused: Bool {
        guard !IsSecureEventInputEnabled(), AXIsProcessTrusted() else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(field, &pid) == .success, CursusProcessSameUser(pid),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        let app = AXUIElementCreateApplication(pid)
        guard prepare(app) else { return false }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFEqual(field, focused), deadline.remaining() > 0 else { return false }
        guard prepare(app) else { return false }
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
              let focusedWindow, CFEqual(window, focusedWindow), deadline.remaining() > 0 else { return false }
        return !IsSecureEventInputEnabled() && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }
    var selectedRange: CFRange? {
        guard prepare(field) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID(), deadline.remaining() > 0 else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return range
    }
    func replaceSelectedText(_ text: String) -> Bool {
        guard prepare(field) else { return false }
        return AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }
    func string(in range: CFRange) -> String? {
        guard prepare(field) else { return nil }
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(field,
            kAXStringForRangeParameterizedAttribute as CFString, parameter, &result) == .success,
              deadline.remaining() > 0 else { return nil }
        return result as? String
    }
}

// An Accessibility element handed between actors; it is only read, never mutated.
struct FieldHandle: @unchecked Sendable { let element: AXUIElement }

actor NativeContext {
    private nonisolated let executor = AXExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    // Injection supplies immutable observations, never native mutation handles.
    private let observation: (@Sendable (ObservationDeadline) -> Context)?
    init(observation: (@Sendable (ObservationDeadline) -> Context)? = nil) { self.observation = observation }
    private var identities = ElementIdentities<AXUIElement>(equal: { CFEqual($0, $1) })
    private var processKey = ""
    private var observer: AXObserver?
    private var observedApp: AXUIElement?
    private var registeredNotifications: [String] = []
    private var notificationInfo: UnsafeMutableRawPointer?
    private let notifications = FocusNotifications()
    private var focusedField: AXUIElement?
    private var focusedWindow: AXUIElement?
    private var ownedClipboardCounter: Int?
    private var restoreSnapshot: ClipboardSnapshot?
    private var restoreEnabled = true

    // The field a paste was just delivered to, only if it is still the observed focused
    // field with the same identity; the correction watcher reads exactly that field.
    func deliveredField(_ target: Destination) -> FieldHandle? {
        guard let focusedField, identities.identity(focusedField) == target.element else { return nil }
        return FieldHandle(element: focusedField)
    }

    // The text cursor of the last observed field, in AX screen coordinates (top-left origin), so the
    // popup can sit beside it. nil for password fields, without AX trust, or when nothing is known.
    func caretRect() -> CGRect? {
        guard let field = focusedField, AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return nil }
        let deadline = ObservationDeadline()
        guard attribute(field, kAXSubroleAttribute, deadline) as? String != kAXSecureTextFieldSubrole as String else { return nil }
        func bounds(_ location: Int, _ length: Int) -> CGRect? {
            var range = CFRange(location: location, length: length)
            guard let parameter = AXValueCreate(.cfRange, &range), prepare(field, deadline) else { return nil }
            var raw: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(field, kAXBoundsForRangeParameterizedAttribute as CFString,
                    parameter, &raw) == .success, let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
            var rect = CGRect.zero
            guard AXValueGetValue(raw as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }
            return rect
        }
        if let raw = attribute(field, kAXSelectedTextRangeAttribute, deadline), CFGetTypeID(raw) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(raw as! AXValue, .cfRange, &range), range.location >= 0 {
                // Some editors give no box for an empty selection; the character before the caret then marks the line.
                if let rect = bounds(range.location, range.length) ?? (range.location > 0 ? bounds(range.location - 1, 1) : nil) {
                    return rect
                }
            }
        }
        // No caret box: a small field's own frame still says where typing happens. A large text view doesn't.
        var origin = CGPoint.zero, size = CGSize.zero
        guard let position = attribute(field, kAXPositionAttribute, deadline), CFGetTypeID(position) == AXValueGetTypeID(),
              let extent = attribute(field, kAXSizeAttribute, deadline), CFGetTypeID(extent) == AXValueGetTypeID(),
              AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(extent as! AXValue, .cgSize, &size),
              size.height > 0, size.height <= 120 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // Off: the transcript stays on the clipboard after an automatic paste.
    func setRestoreEnabled(_ value: Bool) { restoreEnabled = value }
    // Paste last copies explicitly, then pastes; save the clipboard for that copy too.
    private var restoreNextCopy = false
    func armRestoreForNextCopy() { restoreNextCopy = true }
    func disarmRestoreForNextCopy() { restoreNextCopy = false }
    private var closed = false
    private let notificationNames = [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification]

    func setChanged(_ callback: (@Sendable () -> Void)?) { notifications.set(callback) }
    private func prepare(_ element: AXUIElement, _ deadline: ObservationDeadline) -> Bool {
        let remaining = deadline.remaining()
        guard remaining > 0 else { return false }
        return AXUIElementSetMessagingTimeout(element, Float(min(0.05, remaining))) == .success
    }
    private func readAttribute(_ element: AXUIElement, _ name: String,
                               _ deadline: ObservationDeadline) -> (AXError, CFTypeRef?) {
        guard prepare(element, deadline) else { return (.cannotComplete, nil) }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard deadline.remaining() > 0 else { return (.cannotComplete, nil) }
        return (status, status == .success ? value : nil)
    }
    private func attribute(_ element: AXUIElement, _ name: String, _ deadline: ObservationDeadline) -> CFTypeRef? {
        readAttribute(element, name, deadline).1
    }
    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func identity(_ element: AXUIElement) -> String { identities.identity(element) }
    func snapshot() -> Context {
        focusedField = nil; focusedWindow = nil
        let deadline = ObservationDeadline()
        let secure = IsSecureEventInputEnabled()
        guard !closed else { return Context(destination: nil, secureEventInput: secure) }
        guard observation != nil || !secure else { return Context(destination: nil, secureEventInput: secure) }
        var result = observation?(deadline) ?? destinationSnapshot(deadline)
        result.clipboardCounter = nil
        result.secureEventInput = result.secureEventInput || IsSecureEventInputEnabled()
        if deadline.remaining() <= 0 { return Context(destination: nil, secureEventInput: result.secureEventInput) }
        return result
    }
    private func destinationSnapshot(_ deadline: ObservationDeadline) -> Context {
        var result = Context(destination: nil, secureEventInput: IsSecureEventInputEnabled())
        guard !result.secureEventInput, AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              CursusProcessSameUser(app.processIdentifier) else { return result }
        let key = "\(app.processIdentifier):\(app.launchDate?.timeIntervalSince1970 ?? -1)"
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        if key != processKey {
            detach(deadline); processKey = key; identities.removeAll()
            enableManualAccessibility(axApp, deadline)
            attach(axApp, pid: app.processIdentifier, deadline: deadline)
        }
        var observed = focus(axApp, pid: app.processIdentifier, deadline)
        if case .absent = observed {
            // Chromium builds its tree on demand after the switch; ask once more.
            enableManualAccessibility(axApp, deadline)
            Thread.sleep(forTimeInterval: min(0.05, max(0, deadline.remaining() - 0.05)))
            observed = focus(axApp, pid: app.processIdentifier, deadline)
        }
        // A focused element seen without its window can't be checked properly
        // (it might be a password field): copy only, never a blind paste.
        if case .incomplete = observed { return result }
        var field: AXUIElement?, window: AXUIElement?
        if case let .field(f, w) = observed { field = f; window = w }
        if let field, let window {
            let role = attribute(field, kAXRoleAttribute, deadline) as? String
            let subrole = attribute(field, kAXSubroleAttribute, deadline) as? String
            let classification = NativeTargets.classify(bundleID: app.bundleIdentifier, name: app.localizedName,
                role: role, subrole: subrole)
            let windowID = identity(window); let fieldID = identity(field)
            guard !windowID.isEmpty, !fieldID.isEmpty else { return result }
            let range = AXTextPort(field: field, window: window, deadline: deadline).selectedRange
            // Web and Electron editors often report no settable value yet accept
            // Cmd-V, so any of these signals counts as a text input.
            let editable = NativeTargets.isEditable(role: role, subrole: subrole,
                editableAncestor: attribute(field, "AXEditableAncestor", deadline) != nil,
                valueSettable: isSettable(field, kAXValueAttribute, deadline),
                insertionPoint: range != nil)
            result.destination = Destination(process: key, window: windowID, element: fieldID,
                classification: classification, enabled: true, editable: editable,
                route: NativeTargets.route(classification: classification),
                selection: range.flatMap { SelectionAnchor(location: $0.location, length: $0.length) })
        } else {
            let classification = NativeTargets.classifyAppLevel(bundleID: app.bundleIdentifier, name: app.localizedName)
            result.destination = Destination(process: key, window: NativeTargets.appLevelElement,
                element: NativeTargets.appLevelElement, classification: classification, enabled: true,
                editable: true, route: NativeTargets.route(classification: classification))
        }
        guard deadline.remaining() > 0,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              NSWorkspace.shared.frontmostApplication?.launchDate == app.launchDate,
              !IsSecureEventInputEnabled() else {
            return Context(destination: nil, secureEventInput: IsSecureEventInputEnabled())
        }
        focusedField = field; focusedWindow = window
        return result
    }
    private enum Focus { case field(AXUIElement, AXUIElement), absent, incomplete }
    // .absent: the app reports no focused element at all (blind paste allowed).
    // .incomplete: an element is focused but its window or owner can't be confirmed.
    private func focus(_ axApp: AXUIElement, pid: pid_t, _ deadline: ObservationDeadline) -> Focus {
        let (status, value) = readAttribute(axApp, kAXFocusedUIElementAttribute, deadline)
        guard let f = element(value) else {
            // Only a definite "nothing focused" allows a blind paste; a timeout or
            // other error means we couldn't look, so copy only.
            return [.success, .noValue, .attributeUnsupported].contains(status) ? .absent : .incomplete
        }
        guard let w = element(attribute(axApp, kAXFocusedWindowAttribute, deadline)) else { return .incomplete }
        var fieldPID: pid_t = 0; var windowPID: pid_t = 0
        guard AXUIElementGetPid(f, &fieldPID) == .success, AXUIElementGetPid(w, &windowPID) == .success,
              fieldPID == pid, windowPID == fieldPID else { return .incomplete }
        return .field(f, w)
    }
    // Chromium and Electron publish their accessibility tree (and so the focused
    // text field) only after an assistive client sets this. Native apps ignore it.
    private func enableManualAccessibility(_ axApp: AXUIElement, _ deadline: ObservationDeadline) {
        guard prepare(axApp, deadline) else { return }
        _ = AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
    private func isSettable(_ element: AXUIElement, _ name: String, _ deadline: ObservationDeadline) -> Bool {
        guard prepare(element, deadline) else { return false }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }
    private func attach(_ app: AXUIElement, pid: pid_t, deadline: ObservationDeadline) {
        guard prepare(app, deadline) else { return }
        var value: AXObserver?
        let callback: AXObserverCallback = { _, _, _, info in
            guard let info else { return }
            Unmanaged<FocusNotifications>.fromOpaque(info).takeUnretainedValue().notify()
        }
        guard AXObserverCreate(pid, callback, &value) == .success, let value else { return }
        let info = Unmanaged.passRetained(notifications).toOpaque()
        var registered: [String] = []
        for name in notificationNames where prepare(app, deadline) {
            if AXObserverAddNotification(value, app, name as CFString, info) == .success {
                registered.append(name)
            }
        }
        guard !registered.isEmpty else {
            Unmanaged<FocusNotifications>.fromOpaque(info).release()
            return
        }
        observer = value; observedApp = app; notificationInfo = info; registeredNotifications = registered
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(value), .commonModes)
    }
    private func detach(_ deadline: ObservationDeadline) {
        if let observer {
            let source = AXObserverGetRunLoopSource(observer)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
            if let app = observedApp, !registeredNotifications.isEmpty {
                _ = AXUIElementSetMessagingTimeout(app, Float(max(0.02, min(0.05, deadline.remaining()))))
                for name in registeredNotifications {
                    _ = AXObserverRemoveNotification(observer, app, name as CFString)
                }
            }
        }
        observer = nil; observedApp = nil; registeredNotifications.removeAll()
        if let info = notificationInfo {
            notificationInfo = nil
            let retained = Unmanaged<FocusNotifications>.fromOpaque(info).takeRetainedValue()
            // Any main-loop callback already in flight finishes before release.
            DispatchQueue.main.async { withExtendedLifetime(retained) {} }
        }
    }
    func close() {
        closed = true; notifications.set(nil); detach(ObservationDeadline())
        identities.removeAll(); focusedField = nil; focusedWindow = nil; ownedClipboardCounter = nil
        restoreSnapshot = nil
    }
    func perform(_ effect: Effect, permit: EffectPermit) async -> EffectResult {
        guard !closed, permit.valid else { return .failed("Delivery admission canceled or expired") }
        switch effect {
        case let .clipboardWrite(_, text, expectedCounter):
            // Automatic copies (expected counter present) save the whole clipboard
            // first, on this worker, so it can be put back after the paste. If the
            // snapshot fails, refuse the automatic write; recovery keeps the text
            // available for an explicit Copy without destroying the prior board.
            var snapshot: ClipboardSnapshot?
            var writeCounter = expectedCounter
            let armed = restoreNextCopy
            restoreNextCopy = false
            let needsSnapshot = (expectedCounter != nil || armed) && restoreEnabled
            if needsSnapshot {
                guard permit.valid, !IsSecureEventInputEnabled() else {
                    return .failed("Copy canceled or secure input enabled")
                }
                let before = NSPasteboard.general.changeCount
                guard expectedCounter.map({ before == $0 }) ?? true else {
                    return .failed("Clipboard changed before automatic copy")
                }
                let saved = await Self.captureClipboard(permit: permit)
                guard NSPasteboard.general.changeCount == before else {
                    return .failed("Clipboard changed while saving its contents")
                }
                snapshot = saved
                // Recheck the exact board sampled before the awaited capture.
                writeCounter = before
            }
            let result = await MainActor.run { () -> EffectResult in
                guard permit.valid, !IsSecureEventInputEnabled() else { return .failed("Copy canceled or secure input enabled") }
                if needsSnapshot {
                    return NativeClipboard.writeRestoring(text, to: PasteboardPort(board: .general),
                        snapshot: snapshot, expectedCounter: writeCounter, admitMutation: { permit.claim() })
                }
                return NativeClipboard.write(text, to: PasteboardPort(board: .general), expectedCounter: writeCounter,
                                             admitMutation: { permit.claim() })
            }
            if !closed {
                if case let .copied(counter) = result {
                    ownedClipboardCounter = counter
                    restoreSnapshot = snapshot
                } else {
                    ownedClipboardCounter = nil; restoreSnapshot = nil
                }
            }
            return result
        case let .axInsert(_, target, text):
            let fresh = snapshot()
            let deadline = ObservationDeadline()
            guard !closed, permit.valid, !fresh.secure, fresh.destination == target,
                  target.qualified, target.route == .qualifiedAX, let field = focusedField, let window = focusedWindow else {
                return .failed("Focused editor changed")
            }
            return NativeInsertion.insert(text, into: AXTextPort(field: field, window: window, deadline: deadline),
                expectedSelection: target.selection, admitMutation: { permit.claim() })
        case let .pasteKey(_, target):
            // Resolve the keyboard layout before the final AX checks, so no actor hop follows them.
            guard let key = await MainActor.run(body: { NativePasteShortcut.currentKey() }) else {
                return .failed("Paste keyboard layout unavailable")
            }
            let fresh = snapshot()
            let appLevel = target.element == NativeTargets.appLevelElement
            guard !closed, permit.valid, !fresh.secure, let now = fresh.destination, now == target,
                  now.qualified, target.route == .qualifiedClipboard,
                  let owned = ownedClipboardCounter, CGPreflightPostEventAccess() else {
                return .failed("Paste destination or clipboard ownership changed")
            }
            if !appLevel {
                guard let field = focusedField, let window = focusedWindow,
                      AXTextPort(field: field, window: window, deadline: ObservationDeadline()).isFocused else {
                    return .failed("Focused field changed before paste")
                }
            }
            let process = target.process
            let sent: Bool = {
                // Posted at the HID level so it reaches the frontmost app the same
                // way a physical Cmd-V does; Electron apps ignore per-process posts.
                guard permit.valid, !IsSecureEventInputEnabled(), CGPreflightPostEventAccess(),
                      let foreground = NSWorkspace.shared.frontmostApplication,
                      "\(foreground.processIdentifier):\(foreground.launchDate?.timeIntervalSince1970 ?? -1)" == process,
                      CursusProcessSameUser(foreground.processIdentifier),
                      let source = CGEventSource(stateID: .privateState),
                      let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false),
                      NSPasteboard.general.changeCount == owned, permit.claim() else { return false }
                down.flags = .maskCommand; up.flags = .maskCommand
                down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                return true
            }()
            return sent ? .pasteSent : .failed("Paste layout, focus or ownership changed before submission")
        }
    }
    // Reads the clipboard on its own task with a deadline, so a slow or stalled
    // provider never blocks focus tracking. A timeout leaves the clipboard alone.
    private static func captureClipboard(permit: EffectPermit) async -> ClipboardSnapshot? {
        guard let token = CaptureGate.shared.begin() else { return nil }
        // Whichever finishes first resumes; a stalled read is abandoned, not awaited.
        let once = ResumeOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<ClipboardSnapshot?, Never>) in
            once.set(continuation)
            let capture = Task.detached(priority: .userInitiated) {
                defer { CaptureGate.shared.end(token) }
                let admitted = { permit.valid && !IsSecureEventInputEnabled() && !once.done }
                // Admission is checked before the pasteboard is touched at all.
                guard admitted() else { once.resume(nil); return }
                once.resume(NativeClipboard.snapshot(SystemClipboardReader(), shouldContinue: admitted))
            }
            Task.detached {
                try? await Task.sleep(for: .milliseconds(500))
                once.resume(nil); capture.cancel()
            }
        }
    }
    // Puts back what was on the clipboard before dictation, only while the board
    // still holds our transcript. Returns false when there is nothing to restore.
    func restoreClipboard() async -> Bool {
        guard !closed, let snapshot = restoreSnapshot, let owned = ownedClipboardCounter else { return false }
        restoreSnapshot = nil
        let restored = await MainActor.run {
            NativeClipboard.restore(snapshot, to: PasteboardPort(board: .general), ifOwned: owned)
        }
        if restored { ownedClipboardCounter = nil }
        return restored
    }
}

final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ClipboardSnapshot?, Never>?
    private var finished = false
    var done: Bool { lock.withLock { finished } }
    func set(_ value: CheckedContinuation<ClipboardSnapshot?, Never>) {
        lock.withLock { continuation = value }
    }
    func resume(_ value: ClipboardSnapshot?) {
        let pending: CheckedContinuation<ClipboardSnapshot?, Never>? = lock.withLock {
            guard !finished else { return nil }
            finished = true; defer { continuation = nil }; return continuation
        }
        pending?.resume(returning: value)
    }
}

// One current read plus at most two expired native calls. Late completions release
// only their own token; their expired permits cannot qualify a clipboard snapshot.
final class CaptureGate: @unchecked Sendable {
    static let shared = CaptureGate()
    private let lock = NSLock()
    private var activeToken: UInt64 = 0
    private var nextToken: UInt64 = 1
    private var startedAt: TimeInterval = 0
    private var stranded: Set<UInt64> = []
    private static let leaseSeconds: TimeInterval = 2.0
    private static let maxStranded = 2

    func begin(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> UInt64? {
        lock.withLock {
            if activeToken != 0 {
                guard now - startedAt >= Self.leaseSeconds, stranded.count < Self.maxStranded else { return nil }
                stranded.insert(activeToken)
            }
            let token = nextToken
            nextToken &+= 1
            if nextToken == 0 { nextToken = 1 }
            activeToken = token
            startedAt = now
            return token
        }
    }
    func tryBegin() -> Bool { begin() != nil }
    func end(_ token: UInt64? = nil) {
        lock.withLock {
            if let token {
                if activeToken == token { activeToken = 0 }
                else { stranded.remove(token) }
            } else {
                activeToken = 0
            }
        }
    }
}

// A writing-tool selection is captured only on an explicit gesture. Applying it must
// find the same process, window, field, range and original text again.
actor NativeWritingSelection {
    struct Snapshot: @unchecked Sendable {
        let pid: pid_t
        let launch: Date
        let field: AXUIElement
        let window: AXUIElement
        let range: CFRange
        let text: String
    }
    private nonisolated let executor = AXExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    func capture() -> Snapshot? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier,
              let launch = front.launchDate, CursusProcessSameUser(front.processIdentifier),
              NativeTargets.classifyAppLevel(bundleID: front.bundleIdentifier, name: front.localizedName) == .normal,
              !CaptureAdmission.isCredentialApplication(name: front.localizedName, bundleID: front.bundleIdentifier) else { return nil }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard let field: AXUIElement = ScreenText.value(app, "AXFocusedUIElement"),
              let window: AXUIElement = ScreenText.value(app, "AXFocusedWindow") else { return nil }
        AXUIElementSetMessagingTimeout(field, 0.05)
        guard NativeTargets.classify(bundleID: front.bundleIdentifier, name: front.localizedName,
            role: ScreenText.role(field), subrole: ScreenText.value(field, "AXSubrole")) == .normal,
              CaptureAdmission.readableFocus(role: ScreenText.role(field), subrole: ScreenText.value(field, "AXSubrole")) else { return nil }
        let port = AXTextPort(field: field, window: window, deadline: ObservationDeadline())
        guard let range = port.selectedRange, range.length > 0, range.length <= Policy.textLimit,
              let text = port.string(in: range), !text.isEmpty, text.utf8.count <= Policy.textLimit, port.isFocused else { return nil }
        return Snapshot(pid: front.processIdentifier, launch: launch, field: field, window: window, range: range, text: text)
    }
    func apply(_ text: String, to selection: Snapshot, permit: EffectPermit) -> EffectResult {
        guard !Task.isCancelled, permit.valid else { return .failed("Replacement cancelled or expired") }
        guard NSRunningApplication(processIdentifier: selection.pid)?.launchDate == selection.launch,
              let current = capture(), current.pid == selection.pid,
              CFEqual(current.window, selection.window), CFEqual(current.field, selection.field),
              WritingPreviewState.sameSelection(original: selection.text, current: current.text,
                  expected: SelectionAnchor(location: selection.range.location, length: selection.range.length),
                  observed: SelectionAnchor(location: current.range.location, length: current.range.length)) else { return .failed("The original selection changed. Select it again before replacing.") }
        let port = AXTextPort(field: selection.field, window: selection.window, deadline: ObservationDeadline())
        return NativeInsertion.insert(text, into: port,
            expectedSelection: SelectionAnchor(location: selection.range.location, length: selection.range.length),
            admitMutation: { !Task.isCancelled && permit.claim() })
    }
}
