import Foundation
import Testing
import ApplicationServices
import CursusCore
@testable import CursusVox

private final class FixtureEditor: TextInsertionPort {
    var selectedRange: CFRange? = CFRange(location: 5, length: 3)
    var text = "Keep old suffix"
    var isFocused = true
    var rejectWrite = false
    var readbackAvailable = true
    var mutations = 0
    var readRanges: [CFRange] = []
    func replaceSelectedText(_ value: String) -> Bool {
        guard !rejectWrite, let range = selectedRange else { return false }
        let source = text as NSString
        text = source.replacingCharacters(in: NSRange(location: range.location, length: range.length), with: value)
        mutations += 1
        return true
    }
    func string(in range: CFRange) -> String? {
        readRanges.append(range)
        guard readbackAvailable else { return nil }
        return (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
    }
}

@MainActor struct InsertionTests {
    @Test func revokedDeliveryNeverMutates() {
        let field = FixtureEditor()
        let permit = EffectPermit(expiresAt: ProcessInfo.processInfo.systemUptime + 10)
        permit.revoke()
        guard case .failed = NativeInsertion.insert("new", into: field, admitMutation: { permit.claim() }) else {
            Issue.record("Revoked delivery must fail"); return
        }
        #expect(field.mutations == 0)
    }
    @Test func staleFocusOrSelectionNeverMutates() {
        let unfocused = FixtureEditor(); unfocused.isFocused = false
        guard case .failed = NativeInsertion.insert("new", into: unfocused) else {
            Issue.record("Lost focus must refuse mutation"); return
        }
        #expect(unfocused.mutations == 0)
        let moved = FixtureEditor()
        guard case .failed = NativeInsertion.insert("new", into: moved,
            expectedSelection: SelectionAnchor(location: 0, length: 0)) else {
            Issue.record("Changed selection must refuse mutation"); return
        }
        #expect(moved.mutations == 0)
    }
    @Test func fieldsWithoutReadableSecurityMetadataStillPaste() {
        // Sam 2026-10-12: password fields are refused by the secure event input
        // check at snapshot and at the Cmd-V post, not by reading the subrole.
        let classification = NativeTargets.classify(bundleID: "owned.fixture", role: kAXTextFieldRole, subrole: nil)
        #expect(classification == .normal)
        #expect(NativeTargets.route(classification: classification) == .qualifiedClipboard)
    }
    @Test func appsThatExposeNoFocusedElementStillPasteAndKeepTheText() {
        let electron = NativeTargets.classifyAppLevel(bundleID: "synthetic.electron-app", name: "Synthetic")
        #expect(electron == .normal)
        #expect(NativeTargets.route(classification: electron) == .qualifiedClipboard)
        #expect(NativeTargets.classifyAppLevel(bundleID: "com.apple.finder", name: "Finder") == .custom)
        #expect(NativeTargets.classifyAppLevel(bundleID: "com.apple.ScreenSharing", name: "Screen Sharing") == .remote)
        #expect(NativeTargets.classifyAppLevel(bundleID: nil, name: nil) == .unknown)
        // Nothing confirms a field received it, so the transcript stays on the clipboard.
        let blind = Destination(process: "1:1", window: NativeTargets.appLevelElement,
            element: NativeTargets.appLevelElement, classification: .normal, enabled: true, editable: true,
            route: .qualifiedClipboard)
        let field = Destination(process: "1:1", window: "w", element: "e", classification: .normal,
            enabled: true, editable: true, route: .qualifiedClipboard)
        #expect(!NativeTargets.restoresClipboard(after: blind))
        #expect(NativeTargets.restoresClipboard(after: field))
    }
    @Test func noTextFieldIsSaidOnlyWhenTheFocusIsKnown() {
        func target(_ c: Classification, element: String = "e", editable: Bool) -> Destination {
            Destination(process: "1:1", window: "w", element: element, classification: c, enabled: true,
                        editable: editable, route: .unavailable)
        }
        #expect(NativeTargets.takesNoText(target(.custom, element: NativeTargets.appLevelElement, editable: true)))
        #expect(NativeTargets.takesNoText(target(.custom, editable: false)))
        #expect(!NativeTargets.takesNoText(target(.custom, editable: true)))
        #expect(NativeTargets.takesNoText(target(.normal, editable: false)))
        #expect(!NativeTargets.takesNoText(target(.normal, editable: true)))
        #expect(!NativeTargets.takesNoText(target(.normal, element: NativeTargets.appLevelElement, editable: true)))
        #expect(!NativeTargets.takesNoText(target(.remote, editable: true)))
        #expect(!NativeTargets.takesNoText(target(.secure, editable: true)))
    }
    @Test func onlyFocusedTextInputsCountAsEditable() {
        for role in [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole] {
            #expect(NativeTargets.isEditable(role: role, subrole: nil))
        }
        #expect(NativeTargets.isEditable(role: kAXGroupRole, subrole: nil, editableAncestor: true))
        #expect(NativeTargets.isEditable(role: "AXWebArea", subrole: nil, valueSettable: true))
        #expect(NativeTargets.isEditable(role: kAXGroupRole, subrole: nil, insertionPoint: true))
        // A settable value on a control that takes no text (slider, checkbox) is not a text input.
        for role in [kAXSliderRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, kAXIncrementorRole,
                     kAXColorWellRole, kAXScrollBarRole, kAXMenuButtonRole] {
            #expect(!NativeTargets.isEditable(role: role, subrole: nil, valueSettable: true), "\(role)")
        }
        // A page body, the desktop, a list or a button takes no text: copy only.
        for role in ["AXWebArea", kAXScrollAreaRole, kAXListRole, kAXButtonRole, kAXGroupRole, kAXOutlineRole, nil] {
            #expect(!NativeTargets.isEditable(role: role, subrole: nil), "\(role ?? "nil")")
        }
    }
    @Test func remoteDesktopsAreRecognisedByVerifiedIdentifierOrName() {
        #expect(NativeTargets.classify(bundleID: "com.carriez.flutterHbb", role: kAXTextFieldRole, subrole: nil) == .remote)
        for name in ["TeamViewer", "Parsec", "Jump Desktop", "Splashtop Business", "NoMachine", "RealVNC Viewer",
                     "Microsoft Remote Desktop", "Windows App", "AnyDesk", "RustDesk", "Royal TSX"] {
            #expect(NativeTargets.classify(bundleID: "synthetic.\(name)", name: name, role: kAXTextFieldRole,
                                           subrole: nil) == .remote, "\(name)")
        }
        #expect(NativeTargets.classify(bundleID: "com.apple.Notes", name: "Notes", role: kAXTextAreaRole, subrole: nil) == .normal)
    }
    @Test func insertionReplacesSelectionOnceAndReadsOnlySuppliedText() {
        let field = FixtureEditor()
        #expect(NativeInsertion.insert("new 🎤", into: field) == .axConfirmed)
        #expect(field.text == "Keep new 🎤 suffix")
        #expect(field.mutations == 1)
        #expect(field.readRanges.count == 1)
        #expect(field.readRanges[0].location == 5)
        #expect(field.readRanges[0].length == "new 🎤".utf16.count)
    }
    @Test func missingReadbackNeverRetriesOrClaimsConfirmedInsertion() {
        let field = FixtureEditor(); field.readbackAvailable = false
        #expect(NativeInsertion.insert("new", into: field) == .axSent)
        #expect(field.mutations == 1)
    }
    @Test func rejectedWriteNeverFallsBackToPaste() {
        let field = FixtureEditor(); field.rejectWrite = true
        guard case .failed = NativeInsertion.insert("new", into: field) else {
            Issue.record("Rejected write must remain failed"); return
        }
        #expect(field.text == "Keep old suffix")
        #expect(field.mutations == 0)
        #expect(field.readRanges.isEmpty)
    }
    @Test func invalidSelectionNeverMutates() {
        let field = FixtureEditor(); field.selectedRange = CFRange(location: -1, length: 0)
        guard case .failed = NativeInsertion.insert("new", into: field) else {
            Issue.record("Invalid range must fail"); return
        }
        #expect(field.mutations == 0)
    }
    @Test func secureFieldsRemoteDesktopsAndNonTextAppsNeverPaste() {
        let secure = NativeTargets.classify(bundleID: "owned.fixture", role: kAXTextFieldRole, subrole: kAXSecureTextFieldSubrole)
        let remote = NativeTargets.classify(bundleID: "com.apple.ScreenSharing", role: kAXTextFieldRole, subrole: nil)
        let finder = NativeTargets.classify(bundleID: "com.apple.finder", role: nil, subrole: nil)
        let login = NativeTargets.classify(bundleID: "com.apple.loginwindow", role: kAXTextFieldRole, subrole: nil)
        let anonymous = NativeTargets.classify(bundleID: nil, role: kAXTextFieldRole, subrole: nil)
        #expect(secure == .secure); #expect(remote == .remote); #expect(anonymous == .unknown)
        #expect(finder == .custom); #expect(login == .custom)
        for classification in [secure, remote, finder, login, anonymous, .elevated] {
            #expect(NativeTargets.route(classification: classification) == .unavailable)
        }
    }
}

@MainActor @Test func anyOrdinaryAppPastesItsReadableFocusedElement() {
    // Sam 2026-10-12: paste into any app, terminals included (paste never sends Enter).
    for bundle in ["synthetic.unknown-app", "com.apple.Terminal", "com.tinyspeck.slackmacgap",
                   "com.apple.TextEdit", "ai.perplexity.comet"] {
        for role in [kAXTextFieldRole, kAXTextAreaRole, "AXWebArea", kAXButtonRole, nil] {
            let classification = NativeTargets.classify(bundleID: bundle, role: role, subrole: nil)
            #expect(classification == .normal)
            #expect(NativeTargets.route(classification: classification) == .qualifiedClipboard)
        }
    }
}

@MainActor @Test func cancelledWritingReplacementRefusesBeforeReadingNativeSelection() async {
    let permit = EffectPermit(expiresAt: ProcessInfo.processInfo.systemUptime + 10)
    permit.revoke()
    let inert = AXUIElementCreateApplication(1)
    let snapshot = NativeWritingSelection.Snapshot(pid: 1, launch: Date(timeIntervalSince1970: 0),
        field: inert, window: inert, range: CFRange(location: 0, length: 3), text: "old")
    let result = await NativeWritingSelection().apply("new", to: snapshot, permit: permit)
    #expect(result == .failed("Replacement cancelled or expired"))
}
