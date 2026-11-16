import AppKit
import Security
import CursusCore

// Values stay in a secure field until explicit Save; no Keychain reads or network checks on open.
@MainActor final class CredentialSetupWindow: NSObject {
    let panel = FeatureWindow(title: "Provider keys")
    let provider = NSPopUpButton()
    let key = NSSecureTextField()
    private(set) var status: NSTextField!
    private(set) var saveButton: ActionButton!
    private(set) var closeButton: ActionButton!
    private var setup = CredentialSetup()
    var isSaving: Bool { setup.isSaving }
    private let waitNotice: Duration
    private let store: @Sendable (String, CloudCredentials.Provider) -> OSStatus

    init(store: @escaping @Sendable (String, CloudCredentials.Provider) -> OSStatus = { CloudCredentials.save($0, provider: $1) },
         waitNotice: Duration = .seconds(5)) {
        self.store = store; self.waitNotice = waitNotice
        super.init()
        setup.receive(.opened)
        panel.window.setContentSize(NSSize(width: 580, height: 420))
        panel.text("Use an existing OpenRouter or ElevenLabs API key. Keys stay in this Mac's Keychain.")
        panel.text("Saving does not check connection, provider credits, microphone access or successful transcription. Reopen Mercurius after saving to apply the key.")
        provider.addItems(withTitles: CloudCredentials.Provider.allCases.map(\.rawValue))
        provider.setAccessibilityLabel("Credential provider")
        provider.target = self; provider.action = #selector(providerChanged)
        panel.stack.addArrangedSubview(provider)
        key.placeholderString = "Existing API key"
        key.setAccessibilityLabel("Existing provider API key")
        key.translatesAutoresizingMaskIntoConstraints = false
        panel.stack.addArrangedSubview(key)
        key.widthAnchor.constraint(equalTo: panel.stack.widthAnchor).isActive = true
        saveButton = ActionButton(title: "Save to Keychain") { [weak self] in self?.save() }
        saveButton.setAccessibilityLabel("Save provider key to Keychain")
        panel.stack.addArrangedSubview(saveButton)
        status = panel.text("No key has been entered or inspected.")
        closeButton = ActionButton(title: "Cancel") { [weak self] in self?.panel.window.close() }
        closeButton.keyEquivalent = "\u{1b}"
        panel.stack.addArrangedSubview(closeButton)
        panel.closed = { [weak self] in self?.clearInput(); self?.setup.receive(.closed) }
        provider.nextKeyView = key; key.nextKeyView = saveButton
    }
    func show() {
        clearInput()
        if !isSaving { status.stringValue = "Enter an existing key, then choose Save to Keychain." }
        panel.show(); panel.window.makeFirstResponder(key)
    }
    func clearInput() {
        // End field editing too: clearing stringValue alone can leave the field editor's copy visible.
        if let editor = key.currentEditor() {
            editor.string = ""; editor.undoManager?.removeAllActions()
        }
        panel.window.endEditing(for: key)
        key.stringValue = ""
    }
    @objc func providerChanged() {
        setup.receive(.edited)
        clearInput()
        status.stringValue = "Enter the existing key for the selected provider."
    }
    func save() {
        guard !isSaving else { return }
        guard panel.window.makeFirstResponder(nil) else { return }
        guard CloudCredentials.Provider.allCases.indices.contains(provider.indexOfSelectedItem),
              let value = CloudCredentials.validated(key.stringValue) else {
            setup.receive(.save(valid: false))
            clearInput(); status.stringValue = "Enter a key without spaces or control characters (4096 bytes maximum)."; return
        }
        let selected = CloudCredentials.Provider.allCases[provider.indexOfSelectedItem]
        clearInput()
        guard setup.receive(.save(valid: true)) else { return }
        saveButton.isEnabled = false; provider.isEnabled = false; key.isEnabled = false
        closeButton.title = "Close (save continues)"
        status.stringValue = "Saving to Keychain… Closing this window does not cancel the current save."
        let store = self.store
        let notice = Task { [weak self, waitNotice] in
            try? await Task.sleep(for: waitNotice)
            guard !Task.isCancelled, let self, isSaving else { return }
            status.stringValue = "Keychain is taking longer than expected. You may close this window; the current request must finish before retrying."
        }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { store(value, selected) }.value
            notice.cancel()
            guard let self else { return }
            setup.receive(.completed); saveButton.isEnabled = true; provider.isEnabled = true; key.isEnabled = true
            closeButton.title = "Close"
            status.stringValue = result == errSecSuccess
                ? "Saved. Reopen Mercurius to apply this key. Connection and transcription have not been checked."
                : "Keychain did not confirm saving. Unlock your login Keychain and try again."
        }
    }
}
