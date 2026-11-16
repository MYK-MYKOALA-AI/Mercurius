import AppKit
import QuartzCore

// The fn+W review card: a dark floating card near the top right of the screen, like the
// Obsidian Web Clipper's popup. It appears at once while the page is read, then shows the note
// to adjust: title, properties, body (preview or Markdown) and folder. Nothing is saved or
// copied until a button says so. It stays over the app Sam is working in until Esc, its close
// button or a finished action closes it; the draft stays in the main clipboard as unsaved.
// It never activates CursusVox, so the browser or editor Sam clipped stays in front.
@MainActor final class ClipCardPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKey?(event) == true { return true }
        // Edit keys work here even though CursusVox isn't the active app.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let key = event.charactersIgnoringModifiers?.lowercased() {
            let selector: Selector? = switch key {
            case "x": #selector(NSText.cut(_:))
            case "c": #selector(NSText.copy(_:))
            case "v": #selector(NSText.paste(_:))
            case "a": #selector(NSText.selectAll(_:))
            case "z": Selector(("undo:"))
            default: nil
            }
            if let selector, NSApp.sendAction(selector, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
    // Esc closes the card, unless it is finishing a typed accent or an input-method word.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, (firstResponder as? NSTextView)?.hasMarkedText() != true {
            onEscape?(); return
        }
        super.sendEvent(event)
    }
}

@MainActor final class ClipCard: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSTextViewDelegate, NSComboBoxDelegate {
    static let width: CGFloat = 380
    static let inset: CGFloat = 16
    static var contentWidth: CGFloat { width - inset * 2 }
    static let surface = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.115, alpha: 0.98)
    static let bodyHeight: CGFloat = 216

    let model = ClipCardModel()
    var effects: ClipCardModel.Effects?
    var retry: (() -> Void)?
    var closed: (() -> Void)?
    // The edited draft, for the main clipboard: called a moment after typing stops, before an
    // action, and when the card closes, so an edit is never lost.
    var changed: ((ClipDraft, UUID?) -> Void)?
    // The vault's folders and the note's planned path both look at the disk (a vault on a slow
    // volume, up to 999 names), so they run off the main actor: typing never waits on them. The
    // path shows at once without the disk (`guess`), then the free name when it is known; a
    // result for an older title or folder is never shown.
    var folders: @Sendable () -> [String] = { ClipsVault.folders() }
    var planned: @Sendable (String, String) -> URL = { ClipsVault.planned(title: $0, folder: $1) }
    var guess: (String, String) -> URL = { ClipsVault.guess(title: $0, folder: $1) }
    private var knownFolders = [ClipsVault.defaultFolder]
    private var pathRequest = 0, folderRequest = 0
    private var pathWork: Task<Void, Never>?, folderWork: Task<Void, Never>?
    var propertiesOpen: Bool {
        get { UserDefaults.standard.object(forKey: "clipCardPropertiesOpen") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "clipCardPropertiesOpen") }
    }
    var isShown: Bool { panel.isVisible && !closing }

    let panel: ClipCardPanel
    private let root = NSView()
    private let stack = NSStackView()     // the header, the content and the footer
    private let content = NSStackView()   // everything between them, scrolling when the screen is too short
    private let scroll = NSScrollView()
    private var scrollHeight: NSLayoutConstraint!
    private let siteLabel = NSTextField(labelWithString: "")
    private let kindLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let titleField = GrowingField()
    private let titleSkeleton = Skeleton(lines: [0.82, 0.5], height: 15, gap: 7)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let hintRow = NSStackView()
    private let propertiesGroup = NSStackView()
    private let chevron = NSImageView()
    private let propertiesCount = NSTextField(labelWithString: "")
    private let propertiesList = NSStackView()
    private var propertiesCard: Card!
    private var propertyFields: [NSTextField] = []
    private let bodyGroup = NSStackView()
    private let mode = NSSegmentedControl(labels: ["Preview", "Markdown"], trackingMode: .selectOne, target: nil, action: nil)
    private let bodyMeta = NSTextField(labelWithString: "")
    private let bodyText = NSTextView()
    private let bodySkeleton = Skeleton(lines: [1, 0.94, 0.7, 0, 1, 0.88, 0.96, 0.6], height: 9, gap: 9)
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let folderGroup = NSStackView()
    private let folderBox = NSComboBox()
    private let pathLabel = NSTextField(labelWithString: "")
    private let footer = NSStackView()
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let again = NSButton(title: "Try again", target: nil, action: nil)
    private let split = SplitButton(title: ClipCardModel.Action.save.title)
    private let errorGroup = NSStackView()
    private let errorText = NSTextField(wrappingLabelWithString: "")
    private var lastAction: ClipCardModel.Action?
    private var closeTimer: Timer?
    private var persistTimer: Timer?
    private var closing = false
    private var top: CGFloat?   // the card's top edge stays put as it grows

    override init() {
        panel = ClipCardPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = .floating
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        // Shown over whichever app is front, on every Space, and never hidden because CursusVox
        // is not the active app. `.transient` (before 2026-11-01) hid the card as soon as the
        // clip started, because a clip starts while the browser or editor is the active app.
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self
        panel.setAccessibilityTitle("Clip review")
        panel.onKey = { [weak self] event in self?.key(event) ?? false }
        panel.onEscape = { [weak self] in self?.dismiss() }
        build()
        show(.extracting("Reading the page…"))
    }

    // MARK: state

    // A new clip: the card says what it's doing and nothing can act yet. Any edits to the clip
    // on the card are handed to the clipboard first. Returns the token the extraction answers with.
    @discardableResult func begin(_ message: String, site: String) -> Int {
        persist()
        closeTimer?.invalidate(); lastAction = nil
        let token = model.begin(message)
        siteLabel.stringValue = site
        show(model.phase)
        return token
    }
    // The extracted draft, for the clip `token` began. An edited draft on the card is kept (false).
    @discardableResult func offer(_ draft: ClipDraft, token: Int, storeID: UUID?, notice: String? = nil) -> Bool {
        guard model.offer(draft, token: token, notice: notice) else { return false }
        model.storeID = storeID
        fill(); show(.ready)
        return true
    }
    // A clip reopened from the clipboard.
    func load(_ draft: ClipDraft, savedAt file: URL?, folder: String, storeID: UUID?) {
        persist()
        closeTimer?.invalidate(); lastAction = nil
        model.load(draft, savedAt: file, folder: folder, storeID: storeID)
        fill(); show(.ready)
    }
    func fail(_ reason: String, token: Int) {
        model.fail(reason, token: token)
        show(model.phase)
    }
    // Hands an edited draft to the clipboard (only new edits, never a draft just saved as it is).
    private func persist() {
        persistTimer?.invalidate(); persistTimer = nil
        if let edits = model.takeEdits() { changed?(edits.draft, edits.storeID) }
    }
    // Quitting: whatever was typed reaches the clipboard now.
    func flush() { commitEditing(); persist() }
    private func editedSoon() {
        persistTimer?.invalidate()
        persistTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.persist() }
        }
    }

    private func show(_ phase: ClipCardModel.Phase) {
        let ready = phase == .ready
        let extracting: Bool = { if case .extracting = phase { return true }; return false }()
        titleField.isHidden = !ready; titleSkeleton.isHidden = !extracting
        hintRow.isHidden = !ready || model.notice == nil
        propertiesGroup.isHidden = !ready
        bodyGroup.isHidden = !ready; bodySkeleton.isHidden = !extracting
        folderGroup.isHidden = !ready
        footer.isHidden = !(ready || extracting)
        errorGroup.isHidden = ready || extracting
        titleSkeleton.pulse(extracting); bodySkeleton.pulse(extracting)
        if extracting { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        split.isEnabled = model.canAct
        split.setAccessibilityHelp(ready ? nil : "Available once the page has been read")
        again.isHidden = true
        switch phase {
        case let .extracting(message):
            kindLabel.stringValue = "Web clip"
            status(.working(message))
        case .ready:
            status(.info(model.saved == nil ? "⌘S saves · ⌘C copies" : "Saved · edits save a new note"))
            if let notice = model.notice { announce(notice) }
        case let .failed(reason):
            kindLabel.stringValue = "Web clip"
            errorText.stringValue = reason
            announce("Couldn't clip this page. " + reason)
        }
        relayout()
    }

    private enum Status { case info(String), working(String), success(String), failure(String) }
    private func status(_ value: Status) {
        switch value {
        case let .info(text):
            statusIcon.image = nil; statusIcon.isHidden = true
            statusLabel.stringValue = text; statusLabel.textColor = .secondaryLabelColor
        case let .working(text):
            statusIcon.isHidden = true
            statusLabel.stringValue = text; statusLabel.textColor = .secondaryLabelColor
            announce(text)
        case let .success(text):
            statusIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            statusIcon.contentTintColor = RecordingPill.accentDeep; statusIcon.isHidden = false
            statusLabel.stringValue = text; statusLabel.textColor = .labelColor
            announce(text)
        case let .failure(text):
            statusIcon.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)
            statusIcon.contentTintColor = .systemOrange; statusIcon.isHidden = false
            statusLabel.stringValue = text; statusLabel.textColor = .systemOrange
            announce(text)
        }
    }
    // Status changes are read out by VoiceOver.
    private func announce(_ text: String) {
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // Puts the model's draft into the fields.
    private func fill() {
        guard let draft = model.draft else { return }
        siteLabel.stringValue = draft.site ?? "Web clip"
        kindLabel.stringValue = model.saved == nil ? "Unsaved clip" : "Saved clip"
        titleField.stringValue = draft.title; titleField.invalidateIntrinsicContentSize()
        hint.stringValue = model.notice ?? ""
        for view in propertiesList.arrangedSubviews { propertiesList.removeArrangedSubview(view); view.removeFromSuperview() }
        propertyFields = []
        for (index, property) in draft.properties.enumerated() {
            let row = propertyRow(property, index: index)
            propertiesList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: propertiesList.widthAnchor).isActive = true
        }
        propertiesCount.stringValue = "\(draft.properties.count)"
        propertiesCard.isHidden = !propertiesOpen
        chevron.image = NSImage(systemSymbolName: propertiesOpen ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        mode.selectedSegment = 0
        renderBody()
        notice.stringValue = draft.truncationNotice ?? ""; notice.isHidden = draft.truncationNotice == nil
        folderBox.removeAllItems(); folderBox.addItems(withObjectValues: knownFolders)
        folderBox.stringValue = model.folder
        loadFolders()
        updatePath()
    }
    // The vault's folders, read off the main actor; only the latest request fills the list.
    private func loadFolders() {
        folderRequest += 1
        let request = folderRequest, folders = self.folders
        folderWork = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { folders() }.value
            guard let self, request == folderRequest else { return }
            folderWork = nil
            knownFolders = found
            folderBox.removeAllItems(); folderBox.addItems(withObjectValues: found)
        }
    }
    // Tests: returns once the folder list and the path on show answer the latest request.
    func settled() async {
        while let work = pathWork ?? folderWork { await work.value }
    }
    private func renderBody() {
        guard let draft = model.draft else { return }
        let markdown = mode.selectedSegment == 1
        bodyText.isEditable = markdown; bodyText.isRichText = !markdown
        if markdown {
            bodyText.string = draft.body
            bodyText.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular); bodyText.textColor = .labelColor
            bodyText.setAccessibilityLabel("Note Markdown")
        } else {
            bodyText.textStorage?.setAttributedString(MarkdownPreview.render(draft.body))
            bodyText.setAccessibilityLabel("Note preview")
        }
        if let container = bodyText.textContainer { bodyText.layoutManager?.ensureLayout(for: container) }
        bodyText.sizeToFit()
        bodyText.scroll(.zero)
        updateMeta()
    }
    private func updateMeta() {
        guard let draft = model.draft else { return }
        bodyMeta.stringValue = "\(draft.words.formatted()) words · \(ClipDraft.size(draft.markdown.utf8.count))"
    }
    // The draft as it stands is the note already saved, in this folder.
    private var savedHere: Bool {
        guard let draft = model.draft, let saved = model.saved else { return false }
        return saved.draft == draft && saved.folder == model.folder
    }
    private func updatePath() {
        guard let draft = model.draft else { return }
        pathRequest += 1
        if let saved = model.saved, savedHere {
            showPath("Saved as " + (saved.url.path as NSString).abbreviatingWithTildeInPath, planned: false)
            return
        }
        showPath((guess(draft.title, model.folder).path as NSString).abbreviatingWithTildeInPath, planned: true)
        planPath()
    }
    // Works out the free name off the main actor. One at a time: when the title or folder changed
    // while it ran, its answer is dropped and the latest is planned instead.
    private func planPath() {
        guard pathWork == nil, let draft = model.draft, !savedHere else { return }
        let request = pathRequest, title = draft.title, folder = model.folder, planned = self.planned
        pathWork = Task { [weak self] in
            let file = await Task.detached(priority: .userInitiated) { planned(title, folder) }.value
            guard let self else { return }
            pathWork = nil
            guard request == pathRequest else { planPath(); return }
            showPath((file.path as NSString).abbreviatingWithTildeInPath, planned: true)
        }
    }
    private func showPath(_ text: String, planned: Bool) {
        pathLabel.stringValue = text
        pathLabel.textColor = planned ? .tertiaryLabelColor : RecordingPill.accentDeep.withAlphaComponent(0.9)
        pathLabel.toolTip = text
        // "Saved as …" already says what it is; only a planned path is read as "Saves to …".
        pathLabel.setAccessibilityLabel(planned ? "Saves to " + text : text)
    }

    // MARK: actions

    func run(_ action: ClipCardModel.Action) async {
        guard let effects, model.canAct else { return }
        closeTimer?.invalidate()
        commitEditing()
        // The clipboard gets the draft as it is now before anything is saved, so the save's
        // completion only drops what it actually wrote (ClipboardStore.markSaved).
        persist()
        lastAction = action
        again.isHidden = true
        split.isEnabled = false
        if action != .copyMarkdown && action != .copyPlain { status(.working(action == .save ? "Saving…" : "Working…")) }
        let token = model.token
        let outcome = await model.perform(action, effects)
        split.isEnabled = model.canAct
        guard token == model.token else { return }   // another clip was opened meanwhile
        switch outcome {
        case let .done(text):
            status(.success(text)); updatePath()
            kindLabel.stringValue = model.saved == nil ? "Unsaved clip" : "Saved clip"
            // A finished save or copy closes the card after a beat, so the result can be seen.
            let delay: TimeInterval = action == .openInObsidian || action == .revealInFinder ? 0.2 : 1.1
            closeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        case let .failed(text):
            status(.failure(text)); again.isHidden = !model.ready
        }
        persist()
        relayout()
    }
    private func start(_ action: ClipCardModel.Action) { Task { await run(action) } }
    @objc private func runAgain() { if let lastAction { start(lastAction) } }
    @objc private func retryClip() { retry?() }

    private func key(_ event: NSEvent) -> Bool {
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        let selected = ((panel.firstResponder as? NSTextView)?.selectedRange().length ?? 0) > 0
        guard let action = ClipCardModel.shortcut(key, command: command, hasSelection: selected) else { return false }
        start(action)
        return true
    }
    // Text typed into a field counts even if the field hasn't ended editing.
    private func commitEditing() {
        if let editor = titleField.currentEditor() { titleChanged(editor.string) }
    }
    private func titleChanged(_ text: String) {
        model.edit { $0.title = ClipDraft.oneLine(text) }
        if model.edited { editedSoon() }
        titleField.invalidateIntrinsicContentSize(); updatePath(); relayout(animated: false)
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let text = (notification.userInfo?["NSFieldEditor"] as? NSTextView)?.string ?? field.stringValue
        if field === titleField { titleChanged(text); return }
        if field === folderBox { model.folder = text; updatePath(); return }
        if let index = propertyFields.firstIndex(where: { $0 === field }) {
            model.edit { $0.properties[index].set(text) }
            updatePath(); editedSoon()
        }
    }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard folderBox.indexOfSelectedItem >= 0,
              let value = folderBox.itemObjectValue(at: folderBox.indexOfSelectedItem) as? String else { return }
        model.folder = value; updatePath()
    }
    func textDidChange(_ notification: Notification) {
        guard mode.selectedSegment == 1 else { return }
        let text = bodyText.string
        model.edit { $0.body = text; $0.originalBytes = nil }
        updateMeta(); updatePath(); editedSoon()
    }
    @objc private func modeChanged() { renderBody() }
    @objc private func toggleProperties() {
        propertiesOpen.toggle()
        propertiesCard.isHidden = !propertiesOpen
        chevron.image = NSImage(systemSymbolName: propertiesOpen ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        relayout()
    }

    // MARK: showing and hiding

    // Shows the card near the top right of the screen the pointer is on, springing in.
    func present() {
        closing = false
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        top = area.maxY - 12
        let size = fittingSize()
        let target = NSRect(x: area.maxX - Self.width - 14, y: area.maxY - 12 - size.height, width: Self.width, height: size.height)
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.setFrame(target.offsetBy(dx: 0, dy: 10), display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.34
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.35, 0.55, 1)   // a little overshoot
                panel.animator().setFrame(target, display: true)
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16; panel.animator().alphaValue = 1
            }
        } else {
            panel.setFrame(target, display: true)
        }
        panel.makeKey()
        if model.ready { panel.makeFirstResponder(nil) }
    }
    // Closes without saving; the draft is already in the clipboard. Fades and lifts away.
    func dismiss() {
        guard panel.isVisible, !closing else { return }
        closing = true
        closeTimer?.invalidate(); closeTimer = nil
        commitEditing(); persist()
        let frame = panel.frame
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16; context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(frame.offsetBy(dx: 0, dy: 6), display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.closing else { return }
                self.panel.orderOut(nil); self.closing = false
                self.titleSkeleton.pulse(false); self.bodySkeleton.pulse(false)
                self.closed?()
            }
        })
    }
    // The card is not a popover: it stays over whichever app is front while Sam reads or edits
    // it (2026-11-01). Esc, its close button or a finished save/copy closes it. The old
    // resign-key dismissal and `.transient` collection behaviour made it vanish a moment after
    // it appeared, because CursusVox is never the active app when a clip starts.

    // The card's height: header, content and footer, as tall as the screen allows. When the
    // content (a long title, many properties) doesn't fit, it scrolls and the footer with Save
    // and Copy stays in view.
    private func fittingSize() -> NSSize {
        root.layoutSubtreeIfNeeded()
        let needed = ceil(content.fittingSize.height)
        scrollHeight.constant = 0
        let chrome = ceil(stack.fittingSize.height) + Self.inset * 2
        let limit = ((panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 900) - 24
        scrollHeight.constant = min(needed, max(limit - chrome, 120))
        scroll.verticalScrollElasticity = needed > scrollHeight.constant ? .automatic : .none
        return NSSize(width: Self.width, height: chrome + scrollHeight.constant)
    }
    // Resizes to fit, keeping the top edge where it is.
    private func relayout(animated: Bool = true) {
        let size = fittingSize()
        let topEdge = top ?? panel.frame.maxY
        let frame = NSRect(x: panel.frame.minX, y: topEdge - size.height, width: size.width, height: size.height)
        guard frame != panel.frame else { return }
        if animated && panel.isVisible && panel.alphaValue > 0 && !closing {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2; context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        panel.invalidateShadow()
    }
    // Draws the final frame without waiting for animation (offscreen renders).
    func settleForSnapshot() {
        top = panel.frame.maxY
        panel.alphaValue = 1
        relayout(animated: false)
        root.layoutSubtreeIfNeeded()
    }

    // MARK: building

    private func build() {
        root.wantsLayer = true
        root.layer?.backgroundColor = Self.surface.cgColor
        root.layer?.cornerRadius = 16; root.layer?.cornerCurve = .continuous
        root.layer?.borderWidth = 0.5; root.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        root.layer?.masksToBounds = true
        panel.contentView = root

        // Header: what this is and where it came from, a spinner while reading, and Close.
        siteLabel.font = .systemFont(ofSize: 12.5, weight: .semibold); siteLabel.lineBreakMode = .byTruncatingTail
        siteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        kindLabel.font = .systemFont(ofSize: 10.5); kindLabel.textColor = .secondaryLabelColor
        let names = NSStackView(views: [siteLabel, kindLabel]); names.orientation = .vertical; names.alignment = .leading; names.spacing = 0
        names.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let close = SymbolButton("xmark", label: "Close", size: 11) { [weak self] in self?.dismiss() }
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [Self.mark(), names, spacer, spinner, close])
        header.orientation = .horizontal; header.spacing = 9; header.alignment = .centerY

        // Title: one line of text that wraps and grows as it gets longer.
        titleField.font = .systemFont(ofSize: 17, weight: .semibold)
        titleField.placeholderString = "Untitled"; titleField.delegate = self
        titleField.setAccessibilityLabel("Title")
        titleField.width = Self.contentWidth

        // A notice about the capture itself (a thin Google Docs read), in plain view.
        let hintIcon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) ?? NSImage())
        hintIcon.symbolConfiguration = .init(pointSize: 11, weight: .semibold); hintIcon.contentTintColor = .systemOrange
        hint.font = .systemFont(ofSize: 11.5); hint.textColor = .systemOrange
        hint.preferredMaxLayoutWidth = Self.contentWidth - 24
        hintRow.addArrangedSubview(hintIcon); hintRow.addArrangedSubview(hint)
        hintRow.alignment = .top; hintRow.spacing = 7; hintRow.isHidden = true

        // Properties: a disclosure header and the typed rows, open or closed as last left.
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .bold); chevron.contentTintColor = .tertiaryLabelColor
        let propertiesTitle = NSTextField(labelWithString: "Properties")
        propertiesTitle.font = .systemFont(ofSize: 11.5, weight: .semibold); propertiesTitle.textColor = .secondaryLabelColor
        propertiesCount.font = .systemFont(ofSize: 11); propertiesCount.textColor = .tertiaryLabelColor
        let disclosureRow = NSStackView(views: [chevron, propertiesTitle, propertiesCount])
        disclosureRow.spacing = 6; disclosureRow.alignment = .centerY
        let disclosure = HoverControl(disclosureRow, inset: NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 8)) { [weak self] in
            self?.toggleProperties()
        }
        disclosure.setAccessibilityLabel("Properties"); disclosure.setAccessibilityRole(.disclosureTriangle)
        propertiesList.orientation = .vertical; propertiesList.spacing = 0
        propertiesCard = Card(propertiesList, inset: NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8))
        propertiesGroup.orientation = .vertical; propertiesGroup.alignment = .leading; propertiesGroup.spacing = 4
        propertiesGroup.addArrangedSubview(disclosure); propertiesGroup.addArrangedSubview(propertiesCard)
        propertiesCard.widthAnchor.constraint(equalTo: propertiesGroup.widthAnchor).isActive = true

        // Body: rendered, or the raw Markdown to edit.
        mode.target = self; mode.action = #selector(modeChanged); mode.controlSize = .small; mode.selectedSegment = 0
        mode.setAccessibilityLabel("Show the note as a preview or as Markdown")
        bodyMeta.font = .systemFont(ofSize: 10.5); bodyMeta.textColor = .tertiaryLabelColor
        let bodySpacer = NSView(); bodySpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bodyHeader = NSStackView(views: [mode, bodySpacer, bodyMeta]); bodyHeader.alignment = .centerY
        bodyText.drawsBackground = false; bodyText.textContainerInset = NSSize(width: 6, height: 8)
        bodyText.isAutomaticQuoteSubstitutionEnabled = false; bodyText.isAutomaticDashSubstitutionEnabled = false
        bodyText.isAutomaticTextReplacementEnabled = false; bodyText.isAutomaticSpellingCorrectionEnabled = false
        bodyText.isAutomaticLinkDetectionEnabled = false; bodyText.allowsUndo = true; bodyText.delegate = self
        // Sized to the scroll view up front, so the text lays out at its real width and grows downward.
        bodyText.frame = NSRect(x: 0, y: 0, width: Self.contentWidth - 2, height: Self.bodyHeight)
        bodyText.minSize = NSSize(width: 0, height: Self.bodyHeight)
        bodyText.autoresizingMask = [.width]; bodyText.isVerticallyResizable = true; bodyText.isHorizontallyResizable = false
        bodyText.textContainer?.widthTracksTextView = true
        bodyText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let bodyScroll = NSScrollView(); bodyScroll.hasVerticalScroller = true; bodyScroll.autohidesScrollers = true
        bodyScroll.drawsBackground = false; bodyScroll.documentView = bodyText; bodyScroll.scrollerStyle = .overlay
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false
        bodyScroll.heightAnchor.constraint(equalToConstant: Self.bodyHeight).isActive = true
        let bodyCard = Card(bodyScroll, inset: NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
        notice.font = .systemFont(ofSize: 11); notice.textColor = .systemOrange
        notice.preferredMaxLayoutWidth = Self.contentWidth; notice.isHidden = true
        bodyGroup.orientation = .vertical; bodyGroup.alignment = .leading; bodyGroup.spacing = 6
        for view in [bodyHeader, bodyCard, notice] {
            bodyGroup.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: bodyGroup.widthAnchor).isActive = true
        }

        // Folder: where Save puts the note, with the exact path it will get.
        let folderIcon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage())
        folderIcon.symbolConfiguration = .init(pointSize: 12, weight: .medium); folderIcon.contentTintColor = .secondaryLabelColor
        let folderTitle = NSTextField(labelWithString: "Folder")
        folderTitle.font = .systemFont(ofSize: 12); folderTitle.textColor = .secondaryLabelColor
        folderBox.controlSize = .small; folderBox.font = .systemFont(ofSize: 12); folderBox.completes = true
        folderBox.isEditable = true; folderBox.numberOfVisibleItems = 8; folderBox.delegate = self
        folderBox.setAccessibilityLabel("Folder in Mercurius Clips")
        folderBox.setContentHuggingPriority(.init(1), for: .horizontal)
        let folderRow = NSStackView(views: [folderIcon, folderTitle, folderBox]); folderRow.spacing = 7; folderRow.alignment = .centerY
        pathLabel.font = .systemFont(ofSize: 10.5); pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folderGroup.orientation = .vertical; folderGroup.alignment = .leading; folderGroup.spacing = 4
        for view in [folderRow, pathLabel] {
            folderGroup.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: folderGroup.widthAnchor).isActive = true
        }

        // Footer: what just happened, and the split button.
        statusIcon.symbolConfiguration = .init(pointSize: 12, weight: .semibold); statusIcon.isHidden = true
        statusLabel.font = .systemFont(ofSize: 11.5); statusLabel.maximumNumberOfLines = 3
        statusLabel.preferredMaxLayoutWidth = Self.contentWidth - 190
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setAccessibilityRole(.staticText)
        again.bezelStyle = .inline; again.controlSize = .small; again.target = self; again.action = #selector(runAgain)
        again.isHidden = true
        let statusColumn = NSStackView(views: [statusLabel, again]); statusColumn.orientation = .vertical
        statusColumn.alignment = .leading; statusColumn.spacing = 4
        statusColumn.setContentHuggingPriority(.init(1), for: .horizontal)
        statusColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        split.primary = { [weak self] in self?.start(.save) }
        split.actions = { [weak self] in self?.actionMenu() ?? NSMenu() }
        let footerSpacer = NSView(); footerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footerRow = NSStackView(views: [statusIcon, statusColumn, footerSpacer, split]); footerRow.spacing = 6; footerRow.alignment = .centerY
        let line = rowDivider(inset: 0)
        footer.orientation = .vertical; footer.spacing = 12
        for view in [line, footerRow] { footer.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true }

        // Failure: the cause, the next step, and Try again.
        let errorTitle = NSTextField(labelWithString: "Couldn't clip this page")
        errorTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        errorText.font = .systemFont(ofSize: 12); errorText.textColor = .secondaryLabelColor
        errorText.preferredMaxLayoutWidth = Self.contentWidth - 46
        let errorWords = NSStackView(views: [errorTitle, errorText]); errorWords.orientation = .vertical
        errorWords.alignment = .leading; errorWords.spacing = 3
        let errorTop = NSStackView(views: [symbolTile("exclamationmark.triangle.fill", color: .systemOrange, size: 32), errorWords])
        errorTop.alignment = .top; errorTop.spacing = 12
        let retryButton = PillButton("Try again", symbol: "arrow.clockwise", prominent: true) { [weak self] in self?.retryClip() }
        let closeButton = PillButton("Close", symbol: "xmark") { [weak self] in self?.dismiss() }
        retryButton.controlSize = .small; closeButton.controlSize = .small
        let errorButtons = NSStackView(views: [retryButton, closeButton]); errorButtons.spacing = 8
        errorGroup.orientation = .vertical; errorGroup.alignment = .leading; errorGroup.spacing = 14
        errorGroup.addArrangedSubview(errorTop); errorGroup.addArrangedSubview(errorButtons)
        errorButtons.edgeInsets = NSEdgeInsets(top: 0, left: 44, bottom: 0, right: 0)

        // The content between the header and the footer scrolls when the card would be taller
        // than the screen; the header and the footer never move.
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 12
        for view in [titleField, titleSkeleton, hintRow, propertiesGroup, bodyGroup, bodySkeleton, folderGroup, errorGroup] {
            content.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        content.setCustomSpacing(14, after: titleField); content.setCustomSpacing(16, after: titleSkeleton)
        content.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView(); document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay; scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 200)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            scrollHeight
        ])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        for view in [header, scroll, footer] {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.setCustomSpacing(10, after: header); stack.setCustomSpacing(16, after: scroll)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.inset),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.inset),
            stack.widthAnchor.constraint(equalToConstant: Self.contentWidth)
        ])
    }
    // The CursusVox mark with scissors: this card is a clip.
    private static func mark() -> NSView {
        let tile = symbolTile("scissors", color: .clear, size: 26)
        let gradient = CAGradientLayer()
        gradient.colors = [RecordingPill.accent.cgColor, RecordingPill.accentDeep.cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 1); gradient.endPoint = CGPoint(x: 1, y: 0)
        gradient.frame = NSRect(x: 0, y: 0, width: 26, height: 26); gradient.cornerRadius = 26 * 0.28
        tile.layer?.insertSublayer(gradient, at: 0)
        (tile.subviews.first as? NSImageView)?.contentTintColor = NSColor.black.withAlphaComponent(0.8)
        return tile
    }
    private func propertyRow(_ property: ClipDraft.Property, index: Int) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: Self.symbol(for: property), accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 11, weight: .medium); icon.contentTintColor = .tertiaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let name = NSTextField(labelWithString: property.name)
        name.font = .systemFont(ofSize: 12); name.textColor = .secondaryLabelColor; name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 78).isActive = true
        let value = NSTextField(string: property.text)
        value.isBordered = false; value.drawsBackground = false; value.focusRingType = .none
        value.font = .systemFont(ofSize: 12.5); value.lineBreakMode = .byTruncatingTail
        value.cell?.usesSingleLineMode = true; value.cell?.isScrollable = true
        value.placeholderString = property.kind == .list ? "Add, comma separated (\"quote\" one with a comma)" : "Empty"
        value.delegate = self; value.setAccessibilityLabel(property.name)
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        value.setContentHuggingPriority(.init(1), for: .horizontal)
        propertyFields.append(value)
        let row = NSStackView(views: [icon, name, value]); row.spacing = 8; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 25).isActive = true
        return row
    }
    static func symbol(for property: ClipDraft.Property) -> String {
        switch property.name {
        case "source": return "link"
        case "site": return "globe"
        case "author": return "person"
        case "description": return "text.quote"
        case "tags": return "tag"
        default:
            switch property.kind {
            case .text: return "textformat"
            case .date: return "calendar"
            case .datetime: return "clock"
            case .list: return "list.bullet"
            }
        }
    }
    private func actionMenu() -> NSMenu {
        let menu = NSMenu()
        for action in model.menu {
            let item = NSMenuItem(title: action.title, action: #selector(menuChose(_:)), keyEquivalent: action == .copyMarkdown ? "c" : "")
            item.target = self; item.representedObject = action.rawValue
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }
    @objc private func menuChose(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let action = ClipCardModel.Action(rawValue: raw) else { return }
        start(action)
    }
}

// An editable title that wraps and reports the height its text needs, even mid-edit.
@MainActor final class GrowingField: NSTextField {
    var width: CGFloat = 300
    convenience init() {
        self.init(frame: .zero)
        isBordered = false; drawsBackground = false; focusRingType = .none; isEditable = true; isSelectable = true
        cell?.wraps = true; cell?.isScrollable = false; cell?.usesSingleLineMode = false
        lineBreakMode = .byWordWrapping; maximumNumberOfLines = 0
    }
    override var intrinsicContentSize: NSSize {
        let text = currentEditor()?.string ?? stringValue
        let measured = (text.isEmpty ? "Ag" : text) as NSString
        let rect = measured.boundingRect(with: NSSize(width: width - 4, height: 10_000),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading],
                                         attributes: [.font: font ?? NSFont.systemFont(ofSize: 17)])
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(rect.height) + 4)
    }
    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification); invalidateIntrinsicContentSize()
    }
}

// Placeholder bars that pulse gently while the page is read.
@MainActor final class Skeleton: NSView {
    private let lines: [CGFloat]
    private let barHeight: CGFloat
    private let gap: CGFloat
    init(lines: [CGFloat], height: CGFloat, gap: CGFloat) {
        self.lines = lines; barHeight = height; self.gap = gap
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(lines.count) * (barHeight + gap) - gap)
    }
    override func draw(_ dirtyRect: NSRect) {
        for (index, fraction) in lines.enumerated() where fraction > 0 {
            let rect = NSRect(x: 0, y: CGFloat(index) * (barHeight + gap), width: bounds.width * fraction, height: barHeight)
            NSColor.white.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: rect, xRadius: barHeight / 2.4, yRadius: barHeight / 2.4).fill()
        }
    }
    func pulse(_ on: Bool) {
        guard on else { layer?.removeAnimation(forKey: "pulse"); return }
        guard layer?.animation(forKey: "pulse") == nil else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1; animation.toValue = 0.45; animation.duration = 0.85
        animation.autoreverses = true; animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(animation, forKey: "pulse")
    }
}

// The card's main button: the action on the left, a menu of the others behind the chevron.
// Drawn in the CursusVox gradient; dimmed and inert until the draft is ready.
@MainActor final class SplitButton: NSView {
    var primary: () -> Void = {}
    var actions: () -> NSMenu = { NSMenu() }
    var isEnabled = true { didSet { refresh() } }
    private let main = NSButton()
    private let more = NSButton()
    private var hover: NSButton? { didSet { needsDisplay = true } }
    static let height: CGFloat = 30
    static let chevronWidth: CGFloat = 28

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        for button in [main, more] {
            button.isBordered = false; button.bezelStyle = .regularSquare; button.target = self
            button.translatesAutoresizingMaskIntoConstraints = false; addSubview(button)
        }
        main.title = title; main.action = #selector(fireMain)
        main.setAccessibilityLabel(title)
        more.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "More actions")
        more.symbolConfiguration = .init(pointSize: 10, weight: .bold); more.imagePosition = .imageOnly
        more.action = #selector(showMenu); more.setAccessibilityLabel("More actions")
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            main.leadingAnchor.constraint(equalTo: leadingAnchor), main.topAnchor.constraint(equalTo: topAnchor),
            main.bottomAnchor.constraint(equalTo: bottomAnchor),
            main.trailingAnchor.constraint(equalTo: more.leadingAnchor),
            main.widthAnchor.constraint(equalToConstant: ceil((title as NSString).size(withAttributes: [.font: Self.titleFont]).width) + 26),
            more.trailingAnchor.constraint(equalTo: trailingAnchor), more.topAnchor.constraint(equalTo: topAnchor),
            more.bottomAnchor.constraint(equalTo: bottomAnchor), more.widthAnchor.constraint(equalToConstant: Self.chevronWidth)
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        refresh()
    }
    required init?(coder: NSCoder) { nil }
    static let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)

    private func refresh() {
        main.isEnabled = isEnabled; more.isEnabled = isEnabled
        let ink = NSColor.black.withAlphaComponent(isEnabled ? 0.85 : 0)
        let color = isEnabled ? ink : NSColor.white.withAlphaComponent(0.35)
        main.attributedTitle = NSAttributedString(string: main.title, attributes: [.font: Self.titleFont, .foregroundColor: color])
        more.contentTintColor = color
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        if isEnabled {
            NSGradient(starting: RecordingPill.accent, ending: RecordingPill.accentDeep)?.draw(in: shape, angle: 0)
        } else {
            NSColor.white.withAlphaComponent(0.08).setFill(); shape.fill()
        }
        if isEnabled, let hover {
            NSGraphicsContext.saveGraphicsState(); shape.addClip()
            NSColor.white.withAlphaComponent(0.18).setFill(); hover.frame.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        let x = bounds.width - Self.chevronWidth
        NSColor.black.withAlphaComponent(isEnabled ? 0.18 : 0).setFill()
        NSRect(x: x, y: 6, width: 1, height: bounds.height - 12).fill()
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hover = more.frame.contains(point) ? more : main.frame.contains(point) ? main : nil
    }
    override func mouseExited(with event: NSEvent) { hover = nil }
    @objc private func fireMain() { if isEnabled { primary() } }
    @objc private func showMenu() {
        guard isEnabled else { return }
        actions().popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: self)
    }
}
