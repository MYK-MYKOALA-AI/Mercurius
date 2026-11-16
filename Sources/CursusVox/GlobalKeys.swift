import AppKit
import CursusCore

@MainActor final class GlobalKeys {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    var receive: ((KeyEvent) -> Bool)?
    // Fn + a letter (key code): a capture shortcut such as Fn+W. Returns true when handled.
    var chord: ((Int64) -> Bool)?
    fileprivate(set) var chordKey: Int64?
    fileprivate(set) var fnDown = false
    // With the Control+Option hold key, Control+Option+letter is a capture shortcut too: keyboards whose
    // fn key never reaches macOS (some keyboard/firmware setups) have no other way to press one.
    var controlOptionChords = false
    var unavailable: (() -> Void)?
    var recovered: (() -> Void)?
    var active: Bool { port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func enable() -> Bool {
        close()
        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << NSEvent.EventType.systemDefined.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            // The tap's only run-loop source is attached to the main run loop.
            // Suppression is decided inline, never by a queued Task.
            let consumed = MainActor.assumeIsolated {
                let owner = Unmanaged<GlobalKeys>.fromOpaque(info).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    owner.disabled(type)
                    return false
                }
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                // Fn is tracked from its own flag changes: a letter pressed while Fn is held doesn't
                // always carry the Fn flag itself (Sam, 2026-10-13: fn+W did nothing on the Air).
                if type == .flagsChanged {
                    let down = event.flags.contains(.maskSecondaryFn)
                    if down != owner.fnDown { PillTrace.log.notice("fn \(down ? "down" : "up", privacy: .public)") }
                    owner.fnDown = down
                }
                // A chord key stays ours until it is released: its repeats and key-up never reach the app.
                if let held = owner.chordKey, code == held, type == .keyDown || type == .keyUp {
                    if type == .keyUp { owner.chordKey = nil }
                    return true
                }
                let fnHeld = owner.fnDown || event.flags.contains(.maskSecondaryFn)
                if owner.chordKey == nil, type == .keyDown, GlobalKeys.isChord(event.flags, fnHeld: fnHeld, controlOption: owner.controlOptionChords),
                   event.getIntegerValueField(.keyboardEventAutorepeat) == 0, owner.chord?(code) == true {
                    owner.chordKey = code
                    // Cancel dictation after the tap callback returns: never run policy work inline.
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { _ = owner.receive?(.otherKeyDown) }
                    }
                    return true
                }
                if let key = GlobalKeys.keyEvent(type: type, event: event) {
                    return owner.receive?(key) == true
                }
                return false
            }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guard let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else {
            CFMachPortInvalidate(created); return false
        }
        port = created; source = newSource
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        if !active { close(); return false }
        return true
    }
    // Fn plus a bare letter (Cmd/Shift/Option/Control+W keep their usual meaning), or, when enabled,
    // exactly Control+Option plus the letter.
    nonisolated static func isChord(_ flags: CGEventFlags, fnHeld: Bool, controlOption: Bool) -> Bool {
        let others: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        if fnHeld, flags.isDisjoint(with: others) { return true }
        return controlOption && !fnHeld && !flags.contains(.maskSecondaryFn) && flags.contains([.maskControl, .maskAlternate])
            && flags.isDisjoint(with: [.maskCommand, .maskShift])
    }
    nonisolated static func keyEvent(type: CGEventType, event: CGEvent) -> KeyEvent? {
        if type == .flagsChanged {
            return .flags(fn: event.flags.contains(.maskSecondaryFn),
                          control: event.flags.contains(.maskControl), option: event.flags.contains(.maskAlternate))
        }
        // Media and brightness events carry no typed input and must not cancel held dictation.
        if type.rawValue == UInt32(NSEvent.EventType.systemDefined.rawValue) { return nil }
        guard type == .keyDown || type == .keyUp else { return nil }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if code == 49 { return type == .keyDown ? .spaceDown(repeated: repeated) : .spaceUp }
        if code == 53 && type == .keyDown { return .escape(repeated: repeated) }
        return type == .keyDown ? .otherKeyDown : nil
    }
    private func disabled(_ reason: CGEventType) {
        chordKey = nil; fnDown = false
        unavailable?() // invalidate policy admission immediately; no native effects here
        guard let stopped = port else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = port, current === stopped else { return }
            // A user-disabled listener or revoked access needs fresh admission through enable().
            guard reason == .tapDisabledByTimeout, CGPreflightListenEventAccess(), CFMachPortIsValid(current) else {
                close(); return
            }
            CGEvent.tapEnable(tap: current, enable: true)
            if active { recovered?() } else { close() }
        }
    }
    func close() {
        chordKey = nil   // a key held when the tap stops must not swallow the next ordinary press
        fnDown = false
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes); CFRunLoopSourceInvalidate(source) }
        port = nil; source = nil
    }
}
