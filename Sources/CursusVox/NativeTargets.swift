import ApplicationServices
import CursusCore

enum NativeTargets {
    // Sam 2026-10-12: paste into any app, as Wispr Flow does. Excluded apps are
    // ones where Cmd-V acts on files or the system rather than inserting text.
    private static let excluded: Set<String> = [
        "com.apple.finder", "com.apple.loginwindow", "com.apple.dock", "com.apple.systemuiserver"
    ]
    // Pasting into a remote session would send text to another machine.
    // Verified identifiers, plus a deliberately wide name match: a false match
    // only means "copy instead of paste".
    private static let remotes: Set<String> = [
        "com.apple.ScreenSharing", "com.microsoft.rdc.macos", "com.microsoft.rdc.mac",
        "com.realvnc.vncviewer", "com.anydesk.AnyDesk", "com.carriez.flutterHbb"
    ]
    private static let remoteNames = [
        "remote desktop", "windows app", "teamviewer", "parsec", "rustdesk", "anydesk", "splashtop",
        "jump desktop", "nomachine", "vnc", "royal tsx", "screen sharing", "citrix", "horizon client"
    ]
    // Element identity used when an app exposes no focused AX element.
    static let appLevelElement = "app-level"

    // Sam 2026-10-12: paste into whatever field is focused. A field whose subrole
    // can't be read still pastes; password fields are refused by the secure event
    // input check, which every macOS and browser password field turns on.
    static func classify(bundleID: String?, name: String? = nil, role: String?, subrole: String?) -> Classification {
        if role == kAXSecureTextFieldSubrole || subrole == kAXSecureTextFieldSubrole { return .secure }
        if let app = classifyApp(bundleID: bundleID, name: name) { return app }
        return .normal
    }
    // An app exposing no focused element (some Electron and game-engine apps)
    // still gets the paste; the transcript stays on the clipboard so it isn't lost.
    static func classifyAppLevel(bundleID: String?, name: String?) -> Classification {
        classifyApp(bundleID: bundleID, name: name) ?? .normal
    }
    // Surfaces whose windows are never read, as opposed to apps that merely never receive a paste.
    // Finder is in the paste exclusion list because Cmd-V acts on files there, but its window holds
    // only file names, so a window clip must be able to read it: reusing the paste list refused
    // every Fn+T in Finder with "this window is protected" (2026-11-01). The login window, the Dock
    // and the menu bar stay refused: they are credential or system chrome, never window content.
    private static let captureExcluded: Set<String> = [
        "com.apple.loginwindow", "com.apple.dock", "com.apple.systemuiserver"
    ]
    static func classifyCapture(bundleID: String?, name: String?) -> Classification {
        guard let bundleID, !bundleID.isEmpty else { return .unknown }
        let lowered = (name ?? "").lowercased()
        if remotes.contains(bundleID) || remoteNames.contains(where: lowered.contains) { return .remote }
        if captureExcluded.contains(bundleID) { return .custom }
        return .normal
    }
    // Whether the focused element takes typed text. False means a page body, the
    // desktop, a list or a button: the transcript is copied, not pasted.
    private static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
    // Controls whose value is settable but which take no typed text.
    private static let controlRoles: Set<String> = [kAXSliderRole, kAXCheckBoxRole, kAXRadioButtonRole,
        kAXPopUpButtonRole, kAXIncrementorRole, kAXColorWellRole, kAXScrollBarRole, kAXMenuButtonRole,
        kAXButtonRole, kAXDisclosureTriangleRole, kAXValueIndicatorRole, kAXSplitterRole, kAXTabGroupRole,
        "AXSwitch", "AXStepper", "AXDateTimeArea", "AXLevelIndicator"]
    static func isEditable(role: String?, subrole: String?, editableAncestor: Bool = false,
                           valueSettable: Bool = false, insertionPoint: Bool = false) -> Bool {
        if let role, textRoles.contains(role) { return true }
        if let role, controlRoles.contains(role) { return false }
        return editableAncestor || valueSettable || insertionPoint
    }
    // The focus is known to take no typed text: Finder or the desktop, or a
    // visible element that isn't a text input. (Remote desktops and blind
    // targets are unknown, not "no text field".)
    static func takesNoText(_ target: Destination) -> Bool {
        // Finder's desktop or file list; a Finder rename or search field is a text
        // input whose paste is refused by policy, not "no text field".
        if target.classification == .custom { return target.element == appLevelElement || !target.editable }
        return target.element != appLevelElement && target.classification == .normal && !target.editable
    }
    // Only a paste into a field AX could see restores the user's clipboard.
    static func restoresClipboard(after target: Destination) -> Bool {
        target.element != appLevelElement
    }
    private static func classifyApp(bundleID: String?, name: String?) -> Classification? {
        guard let bundleID, !bundleID.isEmpty else { return .unknown }
        let lowered = (name ?? "").lowercased()
        if remotes.contains(bundleID) || remoteNames.contains(where: lowered.contains) { return .remote }
        if excluded.contains(bundleID) { return .custom }
        return nil
    }
    static func route(classification: Classification) -> InsertionRoute {
        classification == .normal ? .qualifiedClipboard : .unavailable
    }
}
