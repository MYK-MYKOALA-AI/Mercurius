import AppKit
import Carbon
import CursusCore

@MainActor final class WritingToolsWindow: NSObject, NSTextViewDelegate, NSTextFieldDelegate {
    private let panel = FeatureWindow(title: "Writing tools")
    let source = NSTextView()
    let output = NSTextView()
    let command = NSTextField(string: "")
    let note = NSTextField(wrappingLabelWithString: "")
    let results = NSStackView()
    private let selection = NativeWritingSelection()
    private var originalSelection: NativeWritingSelection.Snapshot?
    private let snippets: LocalSettings<SnippetBook>
    private var snippetWindow: FeatureWindow?
    private let clipboard: ClipboardStore
    private let history: () -> [HistoryEntry]
    private let dictionary: () -> [String]
    private let model: () -> String?
    private let usage: UsageStore
    private let canRecord: () -> Bool
    private let captureSelection: (() async -> NativeWritingSelection.Snapshot?)?
    private let readText: (UUID) async -> String?
    private(set) var task: Task<Void, Never>?
    private var revision = UUID()
    private var pending: WritingCommand?
    private var pendingText: String?
    private var applyPermit: EffectPermit?
    private var previewState = WritingPreviewState()
    private var previewSource: String { previewState.original }
    private var previewText: String { previewState.output ?? "" }
    private var expiresAt = Date.distantPast
    private var opening = false
    private var expiry: Timer?
    private var searchGeneration = UUID()
    private var sourceValid: (() -> Bool)?
    private var resultValidity: [(NSView, () -> Bool)] = []
    private let speech = LocalSpeech(credentialRead: { nil }, credentialAuthorize: { nil }, scribeCredentialRead: { nil }, retention: .transient)
    private var voiceID: UInt64 = 0
    private var commandCapture = CommandCaptureState()
    private var recording: Bool { commandCapture.phase == .recording }
    private var startingVoice: Bool { commandCapture.phase == .starting }
    private var voiceTimer: Timer?
    private var voiceStarted: TimeInterval = 0
    private var voiceStopped: TimeInterval?

    init(clipboard: ClipboardStore, history: @escaping () -> [HistoryEntry], dictionary: @escaping () -> [String],
         model: @escaping () -> String?, usage: UsageStore, canRecord: @escaping () -> Bool,
         defaults: UserDefaults = .standard,
         captureSelection: (() async -> NativeWritingSelection.Snapshot?)? = nil,
         readText: ((UUID) async -> String?)? = nil,
         snippets shared: LocalSettings<SnippetBook>? = nil) {
        self.clipboard = clipboard; self.history = history; self.dictionary = dictionary
        self.model = model; self.usage = usage; self.canRecord = canRecord
        self.captureSelection = captureSelection; self.readText = readText ?? { await clipboard.text($0) }
        // The app passes its own store so the dictation path reads the same book this window edits.
        snippets = shared ?? LocalSettings(key: "writingSnippetsV1", initial: SnippetBook(), defaults: defaults)
        super.init()
        build()
        panel.closed = { [weak self] in self?.clearSession() }
        speech.select(.apple); speech.previewEnabled = false
        speech.recoveryConfiguration = RecoveryConfiguration(engine: .local, speechModel: "apple-speech", cleanupEnabled: false)
        speech.event = { [weak self] event in self?.voiceEvent(event) }
    }
    private func editor(_ view: NSTextView, label: String, editable: Bool) {
        panel.text(label)
        view.isRichText = false; view.isEditable = editable; view.font = .systemFont(ofSize: 14)
        view.textContainerInset = NSSize(width: 10, height: 10); view.setAccessibilityLabel(label)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.documentView = view; view.isVerticallyResizable = true
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        panel.stack.addArrangedSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalTo: panel.stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 140).isActive = true
    }
    private func build() {
        panel.text("Write, transform or find text. Ordinary dictation always remains dictation.")
        editor(source, label: "Original text", editable: true); source.delegate = self
        command.placeholderString = "rewrite concise · translate to French · snippet my reply · search invoice"
        command.setAccessibilityLabel("Text command"); command.delegate = self
        panel.stack.addArrangedSubview(command)
        command.widthAnchor.constraint(equalTo: panel.stack.widthAnchor).isActive = true
        panel.button("Run text command") { [weak self] in self?.runCommand() }
        panel.button("Record command on device") { [weak self] in self?.recordCommand() }
        panel.button("Stop recording") { [weak self] in self?.stopRecording(finalize: true) }
        panel.text("Commands: rewrite concise/formal/friendly; translate to a language; snippet a cue; search words; uppercase; lowercase; bullet list. Spoken commands fill this field for review. Run executes only supported text actions.")
        panel.button("Manage snippets…") { [weak self] in self?.manageSnippets() }
        panel.text("Rewrite and translation send the original text and instruction to OpenRouter only when you choose Generate cloud preview. Your selected cleanup model is used with data collection denied. Provider charges may apply; no fallback model is called.")
        panel.button("Generate cloud preview") { [weak self] in self?.generatePreview() }
        editor(output, label: "Preview", editable: false)
        panel.button("Copy preview") { [weak self] in self?.copyPreview() }
        panel.button("Replace original selection") { [weak self] in self?.applyPreview() }
        panel.button("Cancel / clear private text") { [weak self] in self?.clearSession() }
        note.setAccessibilityLabel("Writing tool status"); panel.stack.addArrangedSubview(note)
        note.widthAnchor.constraint(equalTo: panel.stack.widthAnchor).isActive = true
        results.orientation = .vertical; results.alignment = .leading; results.spacing = 10
        panel.stack.addArrangedSubview(results)
        results.widthAnchor.constraint(equalTo: panel.stack.widthAnchor).isActive = true
    }
    func open(text: String? = nil, present: Bool = true) async {
        clearSession()
        opening = true
        let token = revision
        let captured: NativeWritingSelection.Snapshot?
        if let captureSelection { captured = await captureSelection() } else { captured = await selection.capture() }
        guard token == revision else { return }
        guard !Task.isCancelled else { clearSession(); return }
        opening = false
        originalSelection = captured
        source.string = text ?? originalSelection?.text ?? ""
        expiresAt = Date().addingTimeInterval(600)
        note.stringValue = originalSelection == nil ? "Paste text here, or open Writing tools with text selected in another app. Text clears after ten minutes or on close." : "Original selection captured. Review the preview before replacing it. Text clears after ten minutes or on close."
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRetention() }
        }
        expiry = timer; RunLoop.main.add(timer, forMode: .common)
        if present { panel.show() }
    }
    func textDidChange(_ notification: Notification) {
        cancelWork(); pending = nil; output.string = ""; previewState.clear()
        note.stringValue = "Original changed. Run a text command again."
    }
    func controlTextDidChange(_ notification: Notification) { invalidateCommand() }
    private func invalidateCommand() {
        cancelWork(); pending = nil; pendingText = nil; previewState.clear(); output.string = ""
        note.stringValue = "Command changed. Choose Run text command to confirm it."
    }
    private func cancelWork() {
        applyPermit?.revoke(); applyPermit = nil
        revision = UUID(); task?.cancel(); task = nil
    }
    func interrupt(reason: String) {
        guard opening || expiresAt != .distantPast || commandCapture.busy else { return }
        clearSession(); note.stringValue = reason + ". Private text cleared."
    }
    func clearSession() {
        cancelWork(); opening = false; stopRecording(finalize: false); expiry?.invalidate(); expiry = nil
        source.string = ""; output.string = ""; command.stringValue = ""; note.stringValue = ""
        originalSelection = nil; previewState.clear(); pending = nil; pendingText = nil; sourceValid = nil
        expiresAt = .distantPast; searchGeneration = UUID(); clearResults()
        source.undoManager?.removeAllActions(); command.currentEditor()?.undoManager?.removeAllActions()
    }
    private var active: Bool { Date() < expiresAt && sourceValid?() != false }
    private func showPreview(_ text: String, original: String, request: UUID? = nil) {
        guard active else { return }
        let request = request ?? previewState.begin(source: original)
        guard previewState.receive(text, generation: request, currentSource: source.string) else { return }
        output.string = text
    }
    func runCommand() {
        guard active else { note.stringValue = "Open Writing tools again to begin."; return }
        cancelWork(); clearResults(); output.string = ""; previewState.clear(); pending = nil
        guard let parsed = WritingCommand.parse(command.stringValue) else {
            note.stringValue = "Unsupported command. Use one of the examples above. No action was taken."; return
        }
        pending = parsed; pendingText = command.stringValue
        if case let .search(query) = parsed { search(query); return }
        if parsed.instruction != nil {
            note.stringValue = "Ready to generate a cloud preview. Original text is unchanged."; return
        }
        if case let .snippet(cue) = parsed, dictionary().contains(where: { SnippetBook.key($0) == SnippetBook.key(cue) }) {
            note.stringValue = "This cue conflicts with a dictionary term. Edit the snippet cue before expanding."; return
        }
        guard snippets.problem == nil else { note.stringValue = snippets.problem!; return }
        guard let text = parsed.localResult(source: source.string, snippets: snippets.value), !text.isEmpty else {
            note.stringValue = "No matching snippet or source text. Original unchanged."; return
        }
        showPreview(text, original: source.string); note.stringValue = "Local preview ready. Nothing has been copied or replaced."
    }
    func generatePreview() {
        guard active, let pending, pending.instruction != nil, command.stringValue == pendingText else { note.stringValue = "Run a rewrite or translation command first."; return }
        let original = source.string
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, original.utf8.count <= Policy.textLimit else {
            note.stringValue = "Add original text, up to 256 KiB."; return
        }
        guard let model = model() else { note.stringValue = "Selected model is unavailable or does not support private text output. Choose a supported cleanup model."; return }
        cancelWork(); let token = revision; output.string = ""
        let request = previewState.begin(source: original)
        note.stringValue = "Generating preview… Original unchanged."
        task = Task { [weak self] in
            guard let self else { return }
            let key = await Task.detached { CloudCredentials.load() }.value
            guard !Task.isCancelled, token == revision, active, source.string == original else { return }
            guard let key else { note.stringValue = "OpenRouter credential unavailable. Open provider setup."; return }
            do {
                let reply = try await TextTransform().run(command: pending, source: original, model: model, key: key,
                    admit: { [usage] in usage.admit($0) }, record: { [usage] in usage.record($0) })
                guard !Task.isCancelled, token == revision, active, source.string == original else { return }
                showPreview(reply.text, original: original, request: request)
                note.stringValue = "Preview ready · " + (reply.cost.map { ModelCosts.money($0) + " USD" } ?? "charge unknown") + ". Review before replacing."
            } catch {
                guard !Task.isCancelled, token == revision, active else { return }
                note.stringValue = "Preview unavailable. Original unchanged. Any returned charge remains in Usage & budget."
            }
        }
    }
    private func copyPreview() {
        guard active, !previewText.isEmpty, previewState.usable(currentSource: source.string) else { return }
        let result = NativeClipboard.write(previewText, to: PasteboardPort(board: .general), admitMutation: { !IsSecureEventInputEnabled() })
        if case .copied = result { note.stringValue = "Preview copied." } else { note.stringValue = "Preview could not be copied." }
    }
    private func applyPreview() {
        guard active, !previewText.isEmpty, previewState.usable(currentSource: source.string),
              let originalSelection, originalSelection.text == previewSource else {
            note.stringValue = "No unchanged original selection to replace. Copy the preview instead."; return
        }
        cancelWork(); let token = revision; let text = previewText
        let permit = EffectPermit(expiresAt: ProcessInfo.processInfo.systemUptime + min(2, expiresAt.timeIntervalSinceNow))
        applyPermit = permit
        task = Task { [weak self] in
            guard let self else { return }
            guard let app = NSRunningApplication(processIdentifier: originalSelection.pid), app.launchDate == originalSelection.launch else {
                note.stringValue = "The original app closed. Copy the preview instead."; return
            }
            app.activate()
            for _ in 0..<10 {
                guard !Task.isCancelled, token == revision, active else { return }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == originalSelection.pid { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled, token == revision, active else { return }
            let result = await selection.apply(text, to: originalSelection, permit: permit)
            guard !Task.isCancelled, token == revision else { return }
            switch result {
            case .axConfirmed: note.stringValue = "Replacement confirmed."; self.originalSelection = nil
            case .axSent: note.stringValue = "Replacement sent; readback unavailable. Check the editor before trying again."; self.originalSelection = nil
            default: note.stringValue = "Selection changed or the editor refused replacement. Original preview retained."
            }
        }
    }
    func refreshRetention(now: Date = Date()) {
        guard expiresAt != .distantPast else { return }
        if now >= expiresAt {
            clearSession(); note.stringValue = "Private text expired. Open Writing tools again to begin."; return
        }
        if sourceValid?() == false {
            clearSession(); note.stringValue = "Source deleted, changed or expired. Private text cleared."; return
        }
        resultValidity.removeAll { view, valid in
            guard !valid() else { return false }
            results.removeArrangedSubview(view); view.removeFromSuperview(); return true
        }
    }
    private func clearResults() {
        resultValidity.removeAll()
        for view in results.arrangedSubviews { results.removeArrangedSubview(view); view.removeFromSuperview() }
    }
    private func search(_ query: String) {
        let token = UUID(); searchGeneration = token
        note.stringValue = "Searching retained text locally…"
        task = Task { [weak self] in
            guard let self else { return }
            await clipboard.ready()
            var count = 0
            for item in clipboard.items {
                await Task.yield()
                guard !Task.isCancelled, active, token == searchGeneration else { return }
                let rev = clipboard.revision(item.id)
                guard let text = await clipboard.text(item.id), clipboard.item(item.id) == item, clipboard.revision(item.id) == rev,
                      active, token == searchGeneration, !Task.isCancelled,
                      RetainedTextSearch.matches(query, fields: [item.title, item.source ?? "", text]) else { continue }
                count += 1
                let button = ActionButton(title: item.title) { [weak self] in
                    guard let self, active else { return }
                    cancelWork(); let loadRevision = revision
                    task = Task { [weak self] in
                        guard let self, !Task.isCancelled, loadRevision == revision, let current = clipboard.item(item.id), current == item,
                              clipboard.revision(item.id) == rev, let currentText = await readText(item.id),
                              clipboard.item(item.id) == current, clipboard.revision(item.id) == rev, active,
                              !Task.isCancelled, loadRevision == revision else { return }
                        sourceValid = { [weak self] in
                            guard let self else { return false }
                            return self.clipboard.retained(item.id) && self.clipboard.revision(item.id) == rev
                        }
                        cancelWork(); source.string = currentText; previewState.clear(); output.string = ""; originalSelection = nil
                        clearResults(); note.stringValue = "Retained item loaded as original text."
                    }
                }
                results.addArrangedSubview(button)
                resultValidity.append((button, { [weak self] in
                    guard let self else { return false }
                    return self.clipboard.retained(item.id) && self.clipboard.revision(item.id) == rev
                }))
                if count == 100 { break }
            }
            if count < 100 {
                for entry in history() where Date().timeIntervalSince(entry.at) < RepeatedTerms.textLifetime {
                    guard !Task.isCancelled, active, token == searchGeneration else { return }
                    guard RetainedTextSearch.matches(query, fields: [entry.text, entry.raw ?? ""]) else { continue }
                    count += 1
                    let button = ActionButton(title: "Activity · " + String(entry.text.prefix(64))) { [weak self] in
                        guard let self, active, let current = history().first(where: { $0.id == entry.id }),
                              Date().timeIntervalSince(current.at) < RepeatedTerms.textLifetime else { return }
                        sourceValid = { [weak self] in
                            guard let self else { return false }
                            return self.history().contains { $0.id == entry.id && $0.text == entry.text && Date().timeIntervalSince($0.at) < RepeatedTerms.textLifetime }
                        }
                        cancelWork(); source.string = current.text; previewState.clear(); output.string = ""; originalSelection = nil
                        clearResults(); note.stringValue = "Activity text loaded."
                    }
                    results.addArrangedSubview(button)
                    resultValidity.append((button, { [weak self] in
                        guard let self else { return false }
                        return self.history().contains { $0.id == entry.id && $0.text == entry.text && Date().timeIntervalSince($0.at) < RepeatedTerms.textLifetime }
                    }))
                    if count == 100 { break }
                }
            }
            guard !Task.isCancelled, active, token == searchGeneration else { return }
            note.stringValue = "\(count) local matches\(count == 100 ? " · first 100 shown" : ""). Deleted and expired text is unavailable."
        }
    }
    private func manageSnippets() {
        let window = snippetWindow ?? FeatureWindow(title: "Snippets"); snippetWindow = window; window.clear()
        window.text("Saved locally. Say a cue on its own while dictating and it expands to this text; in Writing tools, use snippet followed by the cue. A cue used inside a longer sentence is left alone, and a cue that is also a dictionary word stays with the dictionary.")
        if let problem = snippets.problem { window.text(problem); window.show(); return }
        let cue = NSTextField(string: ""); cue.placeholderString = "Spoken cue"; cue.setAccessibilityLabel("Snippet cue")
        window.stack.addArrangedSubview(cue)
        let content = NSTextView(); content.isRichText = false; content.font = .systemFont(ofSize: 14); content.setAccessibilityLabel("Snippet expansion")
        let scroll = NSScrollView(); scroll.documentView = content; scroll.hasVerticalScroller = true
        content.isVerticallyResizable = true; content.autoresizingMask = [.width]; content.textContainer?.widthTracksTextView = true
        window.stack.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo: window.stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        let status = window.text("")
        var editingID: UUID?
        window.button("Save snippet") { [weak self] in
            guard let self else { return }
            do {
                var book = snippets.value
                try book.save(Snippet(id: editingID ?? UUID(), cue: cue.stringValue, text: content.string), dictionary: dictionary())
                snippets.value = book
                guard snippets.save() else { status.stringValue = snippets.problem ?? "Could not save"; return }
                manageSnippets()
            } catch { status.stringValue = "Use a unique cue, different from dictionary terms, and nonempty text up to 64 KiB. At most 200 snippets." }
        }
        for snippet in snippets.value.entries {
            window.text(snippet.cue + " · " + String(snippet.text.prefix(100)))
            window.button("Edit “\(snippet.cue)”") {
                editingID = snippet.id; cue.stringValue = snippet.cue; content.string = snippet.text
                status.stringValue = "Editing “\(snippet.cue)”. Save to keep changes."
            }
            window.button("Delete “\(snippet.cue)”") { [weak self] in
                guard let self else { return }; snippets.value.remove(snippet.id); _ = snippets.save(); manageSnippets()
            }
        }
        window.show()
    }
    var commandCaptureActive: Bool { commandCapture.busy }
    private func recordCommand() {
        guard active, !recording, !startingVoice, voiceTimer == nil, canRecord(), !IsSecureEventInputEnabled() else {
            note.stringValue = "Finish dictation or close the protected field before recording a command."; return
        }
        guard commandCapture.begin() else { return }
        voiceID += 1; voiceStarted = ProcessInfo.processInfo.systemUptime; voiceStopped = nil
        note.stringValue = "Starting on-device command recording…"
        speech.startup(voiceID, context: CleanupContext(style: .strict), cleanOneStep: false)
        guard commandCapture.busy else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.speech.permissionsRevoked {
                    self.stopRecording(); self.note.stringValue = "Permission revoked. Command recording cancelled."; return
                }
                self.speech.poll()
                if ProcessInfo.processInfo.systemUptime - self.voiceStarted >= 60, self.recording { self.stopRecording(finalize: true) }
                if self.startingVoice && ProcessInfo.processInfo.systemUptime - self.voiceStarted > 15 || self.voiceStopped.map({ ProcessInfo.processInfo.systemUptime - $0 > 15 }) == true {
                    self.stopRecording(finalize: false); self.note.stringValue = "Command recording timed out. Try again when on-device speech is ready."
                }
            }
        }
        voiceTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func stopRecording(finalize: Bool = false) {
        if finalize {
            switch commandCapture.stop() {
            case .cancelStartup: stopRecording(finalize: false); note.stringValue = "Command recording cancelled before it started."
            case .finalize:
                voiceStopped = ProcessInfo.processInfo.systemUptime; speech.finalize(voiceID)
                note.stringValue = "Transcribing command on device…"
            case .ignored: break
            }
        } else {
            speech.close(voiceID); voiceID += 1; commandCapture.reset()
            voiceTimer?.invalidate(); voiceTimer = nil; voiceStopped = nil
        }
    }
    private func voiceEvent(_ event: Event) {
        switch event {
        case let .startupCompleted(id, availability, _):
            guard id == voiceID, startingVoice else { return }
            guard availability.ready, active, canRecord() else { stopRecording(); note.stringValue = availability.explanation; return }
            guard commandCapture.ready() else { return }
            speech.capture(id); note.stringValue = "Listening for a text command. Stop when finished."
        case .captureLimitReached: stopRecording(finalize: true)
        case let .final(id, text):
            guard id == voiceID, voiceStopped != nil else { return }; stopRecording()
            receiveSpokenCommand(text)
        case let .recognitionFailed(id, reason):
            guard id == voiceID else { return }; stopRecording(); note.stringValue = reason
        default: break
        }
    }
    func receiveSpokenCommand(_ text: String) {
        guard active else { return }
        invalidateCommand()
        command.stringValue = WritingCommand.spokenInput(text)
        note.stringValue = "Command transcribed locally. Review it, then choose Run text command."
    }
}
