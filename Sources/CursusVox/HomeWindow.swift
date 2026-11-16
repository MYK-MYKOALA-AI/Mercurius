import AppKit
import CursusCore

struct HistoryEntry: Equatable {
    let text: String
    let at: Date
    var raw: String? = nil      // what the engine heard, when cleanup changed it
    var detail: String? = nil   // engine and timing, e.g. "Grok · 2.1 s · cleaned 0.4 s"
    var usageRecordingID: UUID? = nil
    var costs: String? = nil    // each model and its charge, e.g. "grok-stt-1.0 $0.0011 · gpt-oss-120b $0.00006"
    var corrections: [String] = []
    var generation: UInt64? = nil
    var outcomes: [Outcome] = []
    var wordCountGeneration: UInt64? = nil
    var smart: Bool? = nil      // the mode of the app it was dictated into, for re-cleaning
    var id = UUID()
    mutating func applyReclean(_ replacement: HistoryEntry) {
        guard id == replacement.id else { return }
        let currentCount = wordCountGeneration, dictatedSmart = smart
        self = replacement
        wordCountGeneration = currentCount
        if smart == nil { smart = dictatedSmart }
    }
    var deliveryStatus: String { outcomes.last?.label ?? "Text available" }
}

// The menu-bar panel: click the waveform for recent dictations, the dictionary
// and settings. It closes when you click elsewhere, like any menu-bar extra.
@MainActor final class HomePanel: NSObject, NSPopoverDelegate {
    // The primary tabs persist; vocabulary editors return to Settings.
    enum Page: Int { case home, dictionary, takeBacks, settings, clipboard }
    static let size = NSSize(width: 432, height: 650)
    static let contentWidth: CGFloat = 400   // size.width minus the 16 pt margins
    // The prompt Sam pastes into ChatGPT or Claude, which know how he writes.
    static let aiPrompt = """
        List the names, places, products, companies, slang and technical terms I use often that a \
        speech-to-text engine would likely mishear. One per line. Where it's often misheard, write \
        `misheard → correct`. Max 100, no explanations.
        """

    let popover = NSPopover()
    let engine = NSPopUpButton(frame: .zero, pullsDown: false)
    let shortcut = NSPopUpButton(frame: .zero, pullsDown: false)
    let cleanupModel = NSPopUpButton(frame: .zero, pullsDown: false)
    let speechModel = NSPopUpButton(frame: .zero, pullsDown: false)
    // Cleanup models the picker offers (measured catalog + live catalogue extras) and
    // transcription model ids for the speech picker; App replaces both when the
    // catalogue arrives. Defaults keep the pickers working before any fetch.
    var cleanupModels: [AICleanup.Model] = AICleanup.catalog
    var speechModelIDs: [String] = CloudSpeech.speechCatalog {
        didSet { rebuildSpeechPicker() }
    }
    let cleanupStyle = NSPopUpButton(frame: .zero, pullsDown: false)
    let customModelField = NSTextField(string: "")
    let quickWordField = NSTextField(string: "")
    var saveCustomCleanupModel: ((String) -> Void)?
    var rerunCleanup: ((HistoryEntry) -> Void)?
    let keepOnClipboard = NSSwitch()
    let aiCleanup = NSSwitch()
    let learnCorrections = NSSwitch()
    let autoAddNames = NSSwitch()
    let dropTakeBacks = NSSwitch()
    let livePreview = NSSwitch()
    let pillTheme = NSPopUpButton()
    let pillMotion = NSPopUpButton()
    var quit: (() -> Void)?
    var allowGrok: (() -> Void)?
    var manageCredentials: (() -> Void)?
    var chooseLanguages: (() -> Void)?
    let emptyTitle = NSTextField(labelWithString: "Hold Fn and talk")
    private let statusDot = NSView()
    private let warning = NSTextField(wrappingLabelWithString: "")
    private var warningCard: NSView?
    private let heroMeta = NSTextField(wrappingLabelWithString: "")
    private let heroCosts = NSTextField(wrappingLabelWithString: "")
    private let heroText = NSTextField(wrappingLabelWithString: "")
    private let heroHeard = NSTextField(wrappingLabelWithString: "")
    private var heroCard: NSView?
    private var emptyCard: NSView?
    // Koa greets you before the first dictation and cheers each new one.
    private let idleKoa = KoaView(), heroKoa = KoaView()
    private var koaTimer: Timer?
    private var hintRow: NSView?
    private var heroEntry: HistoryEntry?
    private let earlierLabel = NSTextField(labelWithString: "EARLIER")
    private lazy var dictionaryRow = NavRow(title: "Dictionary", symbol: "character.book.closed.fill",
                                            color: .systemBlue) { [weak self] in
        self?.select(.dictionary)
    }
    private lazy var takeBackRow = NavRow(title: "Take-back phrases", symbol: "arrow.uturn.backward",
                                          color: .systemPurple) { [weak self] in self?.select(.takeBacks) }
    let opensAtLogin = NSSwitch()
    let closesOnOutsideClick = NSSwitch()   // Settings › Panel: close when you click anywhere else
    private var outsideClicks: Any?
    let screenText = NSSwitch()
    let copyAfterCapture = NSSwitch()
    // Live list prices by model id, today's spend, and when the prices were fetched (from App).
    var price: ((String) -> ModelPrice?)?
    var todaysCosts: (() -> (total: String?, perModel: String?))?
    var pricesUpdated: (() -> Date?)?
    private let engineNote = NSTextField(wrappingLabelWithString: "")
    private let modelNote = NSTextField(wrappingLabelWithString: "")
    private let costsTotal = NSTextField(labelWithString: "")
    private let costsModels = NSTextField(wrappingLabelWithString: "")
    private let pricesNote = NSTextField(wrappingLabelWithString: "")
    private let strictAppsDetail = NSTextField(labelWithString: "")
    private let strictEditor = NSStackView()
    // The main clipboard: its items, and what the app does when one is used (a message to show, or nil).
    enum ClipboardAction { case open, copy, pin, save, openFile, reveal, delete }
    var clipboardItems: (() -> [ClipboardStore.Item])?
    var clipboardProblem: (() -> String?)?
    var clipboardAction: ((ClipboardAction, ClipboardStore.Item) -> (ok: Bool, message: String)?)?
    private let clipboardList = NSStackView()
    private let clipboardEmptyTitle = NSTextField(labelWithString: "Nothing here yet")
    private let clipboardEmptyHelp = NSTextField(wrappingLabelWithString: "")
    private var clipboardEmpty: NSView?
    private var clipboardCard: NSView?
    private let clipboardNote = NSTextField(wrappingLabelWithString: "")
    // Why clips and captures aren't being kept on disk; shown whenever there is a reason, apart
    // from the rows and from a row's own message, so neither hides it.
    private let clipboardWarning = NSTextField(wrappingLabelWithString: "")
    private var shownProblem: String?
    private let clipboardFilter = NSSegmentedControl(labels: ["All", "Clips", "Captures", "Dictations"], trackingMode: .selectOne,
                                                     target: nil, action: nil)
    private let clipboardSearch = NSSearchField()
    private var shownClipboard: [ClipboardStore.Item]?
    private var shownMinute = 0   // rows carry "Erased in N min" / "N h left", so they redraw each minute
    // Rows are built a page at a time; "Show more" adds the next page, so every kept item can be reached.
    static let clipboardPage = 150
    private var clipboardLimit = HomePanel.clipboardPage
    private var clipboardHidden = 0   // matching items past the limit, as last shown
    // The take-back phrases in use, and where to save an edited list.
    var takeBackPhrases: (() -> [String])?
    var saveTakeBacks: (([String]) -> Void)?
    private let takeBackBox = NSTextView()
    private let takeBackNote = NSTextField(labelWithString: "")
    private let takeBackChips = NSStackView()
    var strictApps: (() -> [String])?
    var saveStrictApps: (([String]) -> Void)?
    private let strictAppsBox = NSTextView()
    private let strictAppsNote = NSTextField(labelWithString: "")
    let status = NSTextField(wrappingLabelWithString: "")
    let headline = NSTextField(labelWithString: "Ready")
    var copy: ((String) -> Void)?
    var copyEntry: ((HistoryEntry) -> Void)?
    var showEntry: ((HistoryEntry) -> Void)?
    var recognitionOnlyTerms: (() -> [String])?
    var retry: ((AudioOutbox.Item) -> Void)?
    var retryCurrent: ((AudioOutbox.Item) -> Void)?
    private var shownFailed: [AudioOutbox.Item] = []
    var openSetup: (() -> Void)?
    // Shortcut help follows the chosen key (Fn or Control + Option).
    private let settingsDictation = NSStackView()
    private let captureShortcutHint = NSTextField(wrappingLabelWithString: "Capture screen: Fn + T.")
    func showDictationKey(fn: Bool) {
        let key = fn ? ["fn"] : ["⌃", "⌥"], name = fn ? "fn" : "ctrl+option"
        shortcutHint.stringValue = fn ? "Hold Fn to dictate" : "Hold Control + Option to dictate"
        let binding: Binding = fn ? .fn : .controlOption
        emptyTitle.stringValue = "Hold " + binding.displayName + " and talk"
        captureShortcutHint.stringValue = "Capture screen: \(binding.chord("T")). Writing tools: \(binding.chord("E"))."
        screenText.setAccessibilityHelp("Turn what's in the front window into a Markdown note with " + binding.chord("T"))
        func fill(_ stack: NSStackView, _ rows: [NSView]) {
            for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
            stack.orientation = .vertical; stack.spacing = 0
            for row in rows { stack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        }
        settingsDictation.toolTip = "Hold, talk, release to paste. For hands-free dictation, press \(name) + space again to stop."
        fill(settingsDictation, [
            padded(shortcutRow(key, "Hold to dictate"), vertical: 6),
            rowDivider(inset: 0),
            padded(shortcutRow(key + ["space"], "Hands-free"), vertical: 6)
        ])
    }
    var closed: (() -> Void)?
    // The user's own words (not the built-in seed) and where to save them.
    var savedDictionary: (() -> (terms: [String], replacements: [String: String]))?
    var builtIn = Vocabulary(terms: Vocabulary.seed, replacements: Vocabulary.seedReplacements)
    var saveDictionary: (((terms: [String], replacements: [String: String])) -> Void)?
    var suggestions: (() -> [RepeatedTerms.Suggestion])?
    private let suggestionRow = NSStackView()
    private let wordsNote = NSTextField(labelWithString: "")
    private var wordsDirty = false
    private var wordsSnapshot = ""   // the list as shown when editing began
    var isShown: Bool { popover.isShown }

    private let navigation = NSSegmentedControl(labels: ["Activity", "Clipboard", "Settings"], trackingMode: .selectOne, target: nil, action: nil)
    private let tabs = NSTabView()
    private let settingsSections = NSSegmentedControl(labels: ["Dictation", "Capture", "General"], trackingMode: .selectOne, target: nil, action: nil)
    private var settingsGroups: [NSView] = []
    private var heroDetails: NSView?
    private let usageDetails = NSStackView()
    private let shortcutHint = NSTextField(labelWithString: "Hold Fn to dictate")
    private let historyList = NSStackView()
    private var shown: [HistoryEntry] = []
    private let importBox = NSTextView()
    private let wordsBox = NSTextView()
    private let preview = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let addButton = NSButton(title: "Add", target: nil, action: nil)

    override init() {
        super.init()
        let content = NSViewController()
        content.view = PanelSurface(content: rootView())
        content.view.frame = NSRect(origin: .zero, size: Self.size)
        content.preferredContentSize = Self.size
        popover.contentViewController = content
        popover.contentSize = Self.size
        popover.behavior = .transient
        popover.delegate = self
    }

    func show(from anchor: NSView, page: Page = .home) {
        select(page)
        loadDictionary(); loadTakeBacks(); loadStrictApps(); loadClipboard()
        applyCloseBehavior()
        NSApp.activate()
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        syncOutsideClicks(shown: true)
    }
    // Captures this app's presented content, not the desktop or other apps.
    func capturePresented(to url: URL) throws {
        guard url.isFileURL, url.pathExtension.lowercased() == "png", popover.isShown,
              let view = popover.contentViewController?.view, view.window?.isVisible == true else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        CATransaction.flush()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .withoutOverwriting)
    }
    // A menu-bar app isn't always made active when its panel opens, so a transient popover can
    // miss the click that should close it. While the panel is open, any click in another app, on
    // the desktop or in the menu bar closes it (unless Settings › Panel keeps it open).
    // Clicks inside CursusVox, including its menu-bar icon, are not seen by a global monitor.
    // Also when the switch changes while the panel is open: the monitor follows at once.
    func applyCloseBehavior() {
        popover.behavior = closesOnOutsideClick.state == .on ? .transient : .applicationDefined
        syncOutsideClicks(shown: popover.isShown)
    }
    var watchingOutsideClicks: Bool { outsideClicks != nil }
    // Exactly one monitor while the panel is shown and the setting is on; none otherwise.
    func syncOutsideClicks(shown: Bool) {
        stopWatchingOutsideClicks()
        guard shown, closesOnOutsideClick.state == .on else { return }
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.closesOnOutsideClick.state == .on else { return }
                self.hide()
            }
        }
    }
    func stopWatchingOutsideClicks() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
    }
    func hide() { popover.performClose(nil) }
    var approvalFirstNotice = false
    var showVocabularyInbox: (() -> Void)?
    var showAppPresets: (() -> Void)?
    var showHealth: (() -> Void)?
    var showWritingTools: (() -> Void)?
    var showUsage: (() -> Void)?
    var openedSettings: (() -> Void)?
    func select(_ page: Page) {
        if wordsDirty { saveWords() }
        tabs.selectTabViewItem(at: page.rawValue)
        navigation.selectedSegment = page == .home ? 0 : page == .clipboard ? 1 : 2
        if page == .clipboard { loadClipboard() }
        if page == .dictionary { loadDictionary() }
        // Koa's frames load after launch, so he is drawn again whenever the page shows.
        if page == .home, koaTimer?.isValid != true { poseKoa() }
        refreshCosts()
        if page == .settings { refreshPrices(); refreshStrictCount(); openedSettings?() }
    }
    // Readiness stays separate from configuration and historical usage.
    func setStatus(_ text: String, ok: Bool) {
        headline.stringValue = text
        statusDot.layer?.backgroundColor = (ok ? NSColor.systemGreen : NSColor.systemOrange).cgColor
    }
    // A problem worth acting on now (Grok locked), with its fix one click away; nil hides it.
    func setWarning(_ text: String?) {
        warning.stringValue = text ?? ""
        warningCard?.isHidden = text == nil
    }
    func setCounts(words: Int, phrases: Int) {
        dictionaryRow.detail.stringValue = "\(words) words"
        takeBackRow.detail.stringValue = dropTakeBacks.state == .on ? "\(phrases) phrases" : "Off"
    }
    func popoverDidClose(_ notification: Notification) {
        if wordsDirty { saveWords() }
        stopWatchingOutsideClicks(); closed?()
    }

    func update(history entries: [HistoryEntry], failed: [AudioOutbox.Item] = []) {
        let recent = Array(entries.suffix(5))
        guard recent != shown || failed != shownFailed else { return }
        shown = recent; shownFailed = failed
        let time = DateFormatter(); time.timeStyle = .short
        // The newest dictation is the hero, with Copy and Paste; the rest are listed below it.
        if heroEntry?.id != recent.last?.id { heroDetails?.isHidden = true }
        heroEntry = recent.last
        let arrived = recent.last != nil && heroEntry?.id != recent.last?.id
        heroCard?.isHidden = recent.last == nil; emptyCard?.isHidden = recent.last != nil
        // The empty card already says how to dictate.
        hintRow?.isHidden = recent.last == nil
        if arrived { cheer() } else { poseKoa() }
        if heroEntry == nil { heroText.stringValue = ""; heroHeard.stringValue = ""; heroMeta.stringValue = ""; heroCosts.stringValue = "" }
        if let hero = heroEntry {
            heroMeta.stringValue = [time.string(from: hero.at), hero.deliveryStatus, hero.detail, hero.corrections.isEmpty ? nil : "Dictionary: " + hero.corrections.joined(separator: "; ")].compactMap { $0 }.joined(separator: " · ")
            heroText.stringValue = hero.text
            heroHeard.stringValue = hero.raw.map { "Original: " + $0 } ?? ""
            heroHeard.isHidden = hero.raw == nil
            heroCosts.stringValue = hero.costs.map { $0 == "free, on this Mac" ? "No online charges · on this Mac" : "Reported usage · " + $0 } ?? "No online charge reported"
            heroCosts.isHidden = false
        }
        for view in historyList.arrangedSubviews { historyList.removeArrangedSubview(view); view.removeFromSuperview() }
        // Recordings whose transcription failed: retry instead of speaking again.
        for item in failed.reversed() {
            let text = NSTextField(labelWithString:
                "Not transcribed · \(time.string(from: item.at)) · \(Int(item.seconds.rounded())) s")
            text.font = .systemFont(ofSize: 12, weight: .medium); text.textColor = .systemOrange
            let button = ActionButton(title: "Retry") { [weak self] in self?.retry?(item) }
            button.controlSize = .small
            let current = ActionButton(title: "Use current engine") { [weak self] in self?.retryCurrent?(item) }
            current.controlSize = .small
            let actions = NSStackView(views: [button,current]); actions.orientation = .vertical; actions.spacing = 4
            historyList.addArrangedSubview(listRow(text, trailing: actions, trailingWidth: 124))
        }
        for entry in recent.dropLast().reversed() {
            let text = NSTextField(wrappingLabelWithString: entry.text)
            text.font = .systemFont(ofSize: 12.5); text.maximumNumberOfLines = 2
            text.lineBreakMode = .byTruncatingTail; text.cell?.truncatesLastVisibleLine = true
            text.preferredMaxLayoutWidth = Self.contentWidth - 60
            // When, and what each model cost; wraps rather than hiding a charge.
            let when = NSTextField(wrappingLabelWithString: [time.string(from: entry.at), entry.deliveryStatus, entry.detail, entry.corrections.isEmpty ? nil : "Dictionary: " + entry.corrections.joined(separator: "; ")].compactMap { $0 }.joined(separator: " · "))
            when.textColor = .secondaryLabelColor; when.font = .systemFont(ofSize: 12)
            when.toolTip = entry.costs.map { "Reported usage for this dictation: " + $0 }
            when.setAccessibilityHelp(when.toolTip)
            when.maximumNumberOfLines = 2; when.preferredMaxLayoutWidth = Self.contentWidth - 60
            let column = NSStackView(views: [text, when])
            column.orientation = .vertical; column.alignment = .leading; column.spacing = 2
            let copy = SymbolButton("doc.on.doc", label: "Copy") { [weak self] in self?.copyTranscript(entry) }
            let details = ActionButton(title: "Details") { [weak self] in self?.showEntry?(entry) }
            details.controlSize = .small
            details.setAccessibilityLabel("Details for earlier dictation")
            let actions = NSStackView(views: [copy, details]); actions.orientation = .vertical; actions.spacing = 4
            historyList.addArrangedSubview(listRow(column, trailing: actions))
        }
        earlierLabel.isHidden = historyList.arrangedSubviews.isEmpty
    }
    private func listRow(_ content: NSView, trailing: NSView, trailingWidth: CGFloat = 64) -> NSView {
        content.setContentHuggingPriority(.defaultLow, for: .horizontal)
        content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [content, trailing])
        row.orientation = .horizontal; row.alignment = .top; row.spacing = 8
        content.widthAnchor.constraint(equalToConstant: Self.contentWidth - trailingWidth - 16).isActive = true
        trailing.widthAnchor.constraint(equalToConstant: trailingWidth).isActive = true
        row.edgeInsets = NSEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return row
    }

    // MARK: layout

    @objc private func navigate() {
        let index = min(2, max(0, navigation.selectedSegment))
        select([Page.home, .clipboard, .settings][index])
    }
    @objc private func changeSettingsSection() {
        let selected = min(2, max(0, settingsSections.selectedSegment))
        for (index, group) in settingsGroups.enumerated() { group.isHidden = index != selected }
    }
    private func rootView() -> NSView {
        tabs.tabViewType = .noTabsNoBorder; tabs.drawsBackground = false
        let pages: [(String, NSView)] = [
            ("home", page(nil, homeView())),
            ("dictionary", page("Dictionary", dictionaryView())),
            ("takeBacks", page("Take-back phrases", takeBackView())),
            ("settings", page(nil, settingsView())),
            ("clipboard", page(nil, clipboardView()))
        ]
        for (id, view) in pages {
            let item = NSTabViewItem(identifier: id); item.view = view; tabs.addTabViewItem(item)
        }
        let title = NSTextField(labelWithString: "Mercurius")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        let space = NSView(); space.setContentHuggingPriority(.init(1), for: .horizontal)
        let quit = SymbolButton("power", label: "Quit Mercurius") { [weak self] in self?.quit?() }
        headline.font = .systemFont(ofSize: 12); headline.textColor = .secondaryLabelColor
        headline.lineBreakMode = .byTruncatingTail
        headline.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusDot.wantsLayer = true; statusDot.layer?.cornerRadius = 3
        statusDot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 6).isActive = true
        let state = NSStackView(views: [statusDot, headline]); state.spacing = 5; state.alignment = .centerY
        let header = NSStackView(views: [symbolTile("waveform", color: Self.koaOrange, size: 28), title, space, state, quit])
        header.spacing = 8; header.alignment = .centerY
        navigation.target = self; navigation.action = #selector(navigate)
        navigation.segmentStyle = .rounded; navigation.segmentDistribution = .fillEqually; navigation.selectedSegment = 0
        navigation.setAccessibilityLabel("Main navigation")
        navigation.font = .systemFont(ofSize: 13, weight: .medium)
        navigation.heightAnchor.constraint(equalToConstant: 34).isActive = true
        costsTotal.font = .systemFont(ofSize: 12, weight: .medium)
        costsTotal.lineBreakMode = .byTruncatingTail
        costsTotal.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let details = SymbolButton("chart.bar", label: "Daily usage details") { [weak self] in
            self?.usageDetails.isHidden.toggle()
        }
        let usage = NSStackView(views: [costsTotal, details]); usage.alignment = .centerY; usage.distribution = .fill
        costsTotal.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for field in [costsModels, pricesNote] {
            field.font = .systemFont(ofSize: 12); field.textColor = .secondaryLabelColor
            field.preferredMaxLayoutWidth = Self.contentWidth
        }
        usageDetails.orientation = .vertical; usageDetails.alignment = .leading; usageDetails.spacing = 6
        usageDetails.addArrangedSubview(costsModels); usageDetails.addArrangedSubview(pricesNote); usageDetails.isHidden = true
        let stack = NSStackView(views: [header, navigation, tabs, rowDivider(inset: 0), usage, usageDetails])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        tabs.setContentHuggingPriority(.init(1), for: .vertical)
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        tabs.setContentCompressionResistancePriority(.init(1), for: .vertical)
        stack.widthAnchor.constraint(equalToConstant: Self.size.width).isActive = true
        stack.heightAnchor.constraint(equalToConstant: Self.size.height).isActive = true
        refreshCosts()
        return stack
    }
    // Scrollable pages; vocabulary editors include a Back to Settings action.
    private func page(_ title: String?, _ content: NSView) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView(); document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.documentView = document
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        scroll.setContentCompressionResistancePriority(.init(1), for: .vertical)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 2),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12)
        ])
        guard let title else { return scroll }
        let back = SymbolButton("chevron.left", label: "Back to Settings", size: 14) { [weak self] in self?.select(.settings) }
        let name = NSTextField(labelWithString: title); name.font = .systemFont(ofSize: 14, weight: .semibold)
        let header = NSStackView(views: [back, name]); header.spacing = 8
        // NSScrollView has no intrinsic height. Pin its remaining space instead
        // of letting an enclosing stack collapse it below the heading.
        let container = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header); container.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func homeView() -> NSView {
        let alert = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) ?? NSImage())
        alert.contentTintColor = .systemOrange
        warning.font = .systemFont(ofSize: 12); warning.preferredMaxLayoutWidth = Self.contentWidth - 110
        let allow = ActionButton(title: "Allow") { [weak self] in self?.allowGrok?() }
        let warningRow = NSStackView(views: [alert, warning, allow]); warningRow.spacing = 8
        let warnCard = Card(warningRow, tint: .systemOrange); warnCard.isHidden = true; warningCard = warnCard

        let latest = NSTextField(labelWithString: "Latest"); latest.font = .systemFont(ofSize: 13, weight: .semibold)
        let space = NSView(); space.setContentHuggingPriority(.init(1), for: .horizontal)
        let copy = SymbolButton("doc.on.doc", label: "Copy latest dictation", size: 14) { [weak self] in
            guard let entry = self?.heroEntry else { return }; self?.copyTranscript(entry)
        }
        heroKoa.widthAnchor.constraint(equalToConstant: 40).isActive = true
        heroKoa.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let top = NSStackView(views: [heroKoa, latest, space, copy]); top.alignment = .centerY; top.spacing = 6
        heroText.font = .systemFont(ofSize: 16, weight: .regular); heroText.isSelectable = true
        heroText.maximumNumberOfLines = 8; heroText.cell?.truncatesLastVisibleLine = true
        heroText.preferredMaxLayoutWidth = Self.contentWidth - 32
        heroMeta.font = .systemFont(ofSize: 12); heroMeta.textColor = .secondaryLabelColor
        heroMeta.lineBreakMode = .byWordWrapping
        heroMeta.maximumNumberOfLines = 0; heroMeta.preferredMaxLayoutWidth = Self.contentWidth - 100
        for field in [heroHeard, heroCosts] {
            field.font = .systemFont(ofSize: 12); field.textColor = .secondaryLabelColor
            field.preferredMaxLayoutWidth = Self.contentWidth - 32; field.isSelectable = true
        }
        heroHeard.maximumNumberOfLines = 0
        let rerun = ActionButton(title: "Re-run cleanup") { [weak self] in
            guard let self, let entry = self.heroEntry else { return }
            self.rerunCleanup?(entry)
        }
        rerun.controlSize = .small
        rerun.setAccessibilityLabel("Re-run AI cleanup on latest dictation")
        let detailStack = NSStackView(views: [heroCosts, heroHeard, rerun]); detailStack.orientation = .vertical
        detailStack.alignment = .leading; detailStack.spacing = 8; detailStack.isHidden = true; heroDetails = detailStack
        let detail = ActionButton(title: "Details") { [weak self] in self?.heroDetails?.isHidden.toggle() }
        detail.bezelStyle = .rounded; detail.controlSize = .small
        detail.setAccessibilityLabel("Show or hide dictation models, charges and original words")
        let meta = NSStackView(views: [heroMeta, detail]); meta.distribution = .fill; meta.alignment = .centerY
        heroMeta.setContentHuggingPriority(.defaultLow, for: .horizontal)
        heroMeta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let heroStack = NSStackView(views: [top, heroText, meta, detailStack])
        heroStack.orientation = .vertical; heroStack.alignment = .leading; heroStack.spacing = 12
        for view in [top, meta, detailStack] { view.widthAnchor.constraint(equalTo: heroStack.widthAnchor).isActive = true }
        let hero = Card(heroStack, inset: NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)); hero.isHidden = true; heroCard = hero
        emptyTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        let emptyNote = small("Koa types what you say, wherever your cursor is.")
        emptyNote.alignment = .center
        idleKoa.widthAnchor.constraint(equalToConstant: 168).isActive = true
        idleKoa.heightAnchor.constraint(equalToConstant: 168).isActive = true
        // Koa is the welcome: large and centred, with the one thing to do under him.
        let emptyRow = NSStackView(views: [idleKoa, emptyTitle, emptyNote]); emptyRow.orientation = .vertical
        emptyRow.alignment = .centerX; emptyRow.spacing = 6; emptyRow.setCustomSpacing(2, after: idleKoa)
        let empty = Card(emptyRow, inset: NSEdgeInsets(top: 18, left: 16, bottom: 22, right: 16)); emptyCard = empty
        earlierLabel.isHidden = true
        earlierLabel.stringValue = "Earlier"; earlierLabel.font = .systemFont(ofSize: 11, weight: .medium)
        earlierLabel.textColor = .tertiaryLabelColor
        historyList.orientation = .vertical; historyList.alignment = .leading; historyList.spacing = 2
        shortcutHint.font = .systemFont(ofSize: 12); shortcutHint.textColor = .secondaryLabelColor
        let hint = NSStackView(views: [shortcutHint]); hint.spacing = 8; hint.alignment = .centerY
        hintRow = hint; hint.isHidden = true
        hint.toolTip = "Dictations are erased after 10 minutes and when you quit. All shortcuts are in Settings."
        let retention = small("Dictation text clears after 10 minutes or when you quit.")
        let stack = NSStackView(views: [warnCard, hero, empty, earlierLabel, historyList, hint, retention, MadeByMyKoala.link()])
        poseKoa()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.setCustomSpacing(8, after: earlierLabel)
        for view in [warnCard, hero, empty, historyList] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    // Koa at rest: the listening pose in the empty card, the happy one beside the latest dictation.
    private func poseKoa() {
        idleKoa.begin(now: 0); idleKoa.advance(now: 10)
        heroKoa.begin(now: 0); heroKoa.set(.happy, now: 1); heroKoa.advance(now: 10)
    }
    // A short happy bounce for a new dictation. KoaView holds still under Reduce Motion.
    private func cheer() {
        let start = ProcessInfo.processInfo.systemUptime
        heroKoa.begin(now: start - 10); heroKoa.set(.happy, now: start)
        koaTimer?.invalidate()
        koaTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.heroKoa.advance(now: now)
                if now - start >= 1.2 { self.koaTimer?.invalidate() }
            }
        }
    }

    private func dictionaryView() -> NSView {
        count.font = .systemFont(ofSize: 12, weight: .medium)
        let prompt = ActionButton(title: "Copy prompt for your AI") { [weak self] in self?.copy?(Self.aiPrompt) }
        prompt.controlSize = .small
        prompt.toolTip = "Paste it into ChatGPT or Claude, then paste the answer below."
        let top = NSStackView(views: [count, prompt]); top.orientation = .horizontal; top.distribution = .equalSpacing
        quickWordField.placeholderString = "Quick add word or misheard → correct"
        quickWordField.font = .systemFont(ofSize: 12)
        quickWordField.target = self; quickWordField.action = #selector(quickAddWord)
        quickWordField.setAccessibilityLabel("Quick add dictionary word")
        let quickAdd = ActionButton(title: "Quick Add") { [weak self] in self?.quickAddWord() }
        quickAdd.controlSize = .small
        let quickRow = NSStackView(views: [quickWordField, quickAdd]); quickRow.orientation = .horizontal; quickRow.spacing = 6
        quickWordField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        quickWordField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        suggestionRow.orientation = .horizontal; suggestionRow.spacing = 6
        let importLabel = small("Paste names, places and jargon: one per line, or “misheard → correct”.")
        let importScroll = textArea(importBox, height: 110)
        importBox.delegate = self
        preview.font = .systemFont(ofSize: 11); preview.textColor = .secondaryLabelColor
        preview.lineBreakMode = .byTruncatingTail
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addButton.target = self; addButton.action = #selector(addImport); addButton.controlSize = .small
        addButton.isEnabled = false
        let addRow = NSStackView(views: [preview, addButton]); addRow.orientation = .horizontal
        let wordsLabel = small("Your words, kept for good. Edit or delete lines, then Save. Built-in names aren't listed.")
        let wordsScroll = textArea(wordsBox, height: 150)
        let save = ActionButton(title: "Save") { [weak self] in self?.saveWords() }
        save.controlSize = .small
        wordsNote.font = .systemFont(ofSize: 11); wordsNote.textColor = .systemOrange
        wordsNote.lineBreakMode = .byTruncatingTail
        wordsNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wordsBox.delegate = self
        let saveRow = NSStackView(views: [save, wordsNote]); saveRow.orientation = .horizontal
        let stack = NSStackView(views: [top, quickRow, suggestionRow, importLabel, importScroll, addRow, wordsLabel, wordsScroll, saveRow])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        for view in [top, quickRow, importScroll, addRow, wordsScroll, importLabel, wordsLabel] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.setCustomSpacing(12, after: addRow)
        return stack
    }
    private func takeBackView() -> NSView {
        let intro = small("Say one of these and the words just before it are dropped: “Book it for Friday, no I mean Saturday” is pasted as “Book it for Saturday”. Every edit is still checked.")
        let listLabel = small("One phrase per line. Add how it gets misheard too, like “no weight” for “no wait”.")
        let scroll = textArea(takeBackBox, height: 150)
        takeBackBox.delegate = self
        let save = ActionButton(title: "Save") { [weak self] in self?.saveTakeBackBox() }
        let reset = ActionButton(title: "Reset to defaults") { [weak self] in
            self?.takeBackBox.string = TakeBack.defaults.joined(separator: "\n"); self?.saveTakeBackBox()
        }
        for button in [save, reset] { button.controlSize = .small }
        takeBackNote.font = .systemFont(ofSize: 11); takeBackNote.textColor = .systemOrange
        takeBackNote.lineBreakMode = .byTruncatingTail
        takeBackNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let saveRow = NSStackView(views: [save, reset, takeBackNote]); saveRow.orientation = .horizontal
        takeBackChips.orientation = .horizontal; takeBackChips.spacing = 6
        let toggle = Card(switchRow("Drop words I take back", "Needs Grok and Clean up with AI.", dropTakeBacks),
                          inset: NSEdgeInsets(top: 2, left: 12, bottom: 2, right: 12))
        let stack = NSStackView(views: [intro, toggle, listLabel, scroll, saveRow, takeBackChips])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        for view in [intro, toggle, listLabel, scroll] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        stack.setCustomSpacing(10, after: intro)
        return stack
    }
    // The box shows the saved list unless the user is mid-edit; the chips offer
    // the suggested phrases that aren't in it yet.
    func loadTakeBacks() {
        let phrases = takeBackPhrases?() ?? TakeBack.defaults
        if takeBackNote.stringValue != "Unsaved" { takeBackBox.string = phrases.joined(separator: "\n") }
        let have = Set(TakeBack.parse(takeBackBox.string).map { $0.lowercased() })
        takeBackChips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let missing = TakeBack.suggested.filter { !have.contains($0) }
        if !missing.isEmpty {
            let add = NSTextField(labelWithString: "Add:"); add.font = .systemFont(ofSize: 11)
            add.textColor = .secondaryLabelColor; takeBackChips.addArrangedSubview(add)
        }
        for phrase in missing.prefix(3) {
            let chip = ActionButton(title: "+ " + phrase) { [weak self] in
                guard let self else { return }
                takeBackBox.string = (TakeBack.parse(takeBackBox.string) + [phrase]).joined(separator: "\n")
                saveTakeBackBox()
            }
            chip.controlSize = .small; chip.bezelStyle = .recessed
            chip.setContentCompressionResistancePriority(.required, for: .horizontal)
            takeBackChips.addArrangedSubview(chip)
        }
    }
    private func saveTakeBackBox() {
        let phrases = TakeBack.parse(takeBackBox.string)
        let lines = takeBackBox.string.split(whereSeparator: { $0.isNewline || $0 == "," })
            .filter { !$0.allSatisfy(\.isWhitespace) }.count
        saveTakeBacks?(phrases)
        takeBackNote.stringValue = lines > phrases.count ? "Saved; \(lines - phrases.count) line(s) skipped (words only, 4 max)" : ""
        loadTakeBacks()
    }

    private func loadStrictApps() {
        if strictAppsNote.stringValue != "Unsaved" { strictAppsBox.string = (strictApps?() ?? []).joined(separator: "\n") }
        refreshStrictCount()
    }
    // "10 apps" beside Strict in these apps: the saved list, read each time it can have changed.
    func refreshStrictCount() {
        let count = (strictApps?() ?? []).count
        strictAppsDetail.stringValue = "\(count) app\(count == 1 ? "" : "s")"
    }
    private func saveStrictAppsBox() {
        let ids = AppCleanup.parseApps(strictAppsBox.string)
        let lines = strictAppsBox.string.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }.count
        saveStrictApps?(ids)
        strictAppsNote.stringValue = lines > ids.count ? "Saved; \(lines - ids.count) line(s) skipped" : "Saved"
        loadStrictApps()
    }

    private func textArea(_ text: NSTextView, height: CGFloat) -> NSScrollView {
        text.font = .systemFont(ofSize: 12); text.isRichText = false; text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
        text.textContainerInset = NSSize(width: 4, height: 4)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.documentView = text; text.autoresizingMask = [.width]
        text.isVerticallyResizable = true; text.minSize = NSSize(width: 0, height: height)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    // Settings, in the style of Home: grouped cards of rows, each with an icon tile, a title,
    // at most one short line, and its control. Prices and today's spend come from App.
    private func settingsView() -> NSView {
        if engine.numberOfItems == 0 {
            engine.addItems(withTitles: Self.engineNames)
            shortcut.addItems(withTitles: ["Fn", "Control + Option"])
        }
        engine.setAccessibilityLabel("Speech engine"); shortcut.setAccessibilityLabel("Dictation shortcut")
        if cleanupModel.numberOfItems == 0 { rebuildCleanupPicker() }
        cleanupModel.setAccessibilityLabel("AI cleanup model")
        if speechModel.numberOfItems == 0 { rebuildSpeechPicker() }
        speechModel.setAccessibilityLabel("Speech model")
        if cleanupStyle.numberOfItems == 0 { cleanupStyle.addItems(withTitles: ["Smart", "Strict"]) }
        cleanupStyle.setAccessibilityLabel("Cleanup style")
        for popup in [engine, shortcut, cleanupModel, cleanupStyle, speechModel] { popup.controlSize = .small; popup.font = .systemFont(ofSize: 12) }
        for note in [engineNote, modelNote] { note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
            note.preferredMaxLayoutWidth = Self.contentWidth - 24 }
        refreshPrices()

        let voice = rows([
            pickerRow("Speech engine", engine, engineNote),
            rowDivider(inset: 0),
            pickerRow("Speech model", speechModel),
            ActionButton(title: "Provider keys…") { [weak self] in self?.manageCredentials?() },
            ActionButton(title: "Speech languages…") { [weak self] in self?.chooseLanguages?() },
            rowDivider(inset: 0),
            controlRow("keyboard", "Talk key", nil, shortcut),
            padded(settingsDictation, vertical: 0),
            rowDivider(inset: 0),
            toggleRow("text.bubble", "Show my words while I talk", nil, livePreview)
        ])

        captureShortcutHint.font = .systemFont(ofSize: 12)
        captureShortcutHint.textColor = .secondaryLabelColor
        captureShortcutHint.preferredMaxLayoutWidth = Self.contentWidth - 24
        refreshStrictCount()
        strictAppsDetail.font = .systemFont(ofSize: 12); strictAppsDetail.textColor = .secondaryLabelColor
        let editStrict = ActionButton(title: "Edit") { [weak self] in
            guard let self else { return }
            strictEditor.isHidden.toggle()
            if !strictEditor.isHidden { loadStrictApps(); strictAppsBox.window?.makeFirstResponder(strictAppsBox) }
        }
        editStrict.controlSize = .small
        let strictScroll = textArea(strictAppsBox, height: 84)
        strictAppsBox.delegate = self; strictAppsBox.setAccessibilityLabel("Strict app bundle identifiers")
        let saveStrict = ActionButton(title: "Save") { [weak self] in self?.saveStrictAppsBox() }
        saveStrict.controlSize = .small
        strictAppsNote.font = .systemFont(ofSize: 11); strictAppsNote.textColor = Self.koaOrange
        let strictSave = NSStackView(views: [saveStrict, strictAppsNote]); strictSave.orientation = .horizontal
        let strictHelp = small("One bundle ID per line. These apps only get words removed, never reworded.", width: Self.contentWidth - 24)
        for view in strictEditor.arrangedSubviews { strictEditor.removeArrangedSubview(view); view.removeFromSuperview() }
        for view in [strictHelp, strictScroll, strictSave] { strictEditor.addArrangedSubview(view) }
        strictEditor.orientation = .vertical; strictEditor.alignment = .leading; strictEditor.spacing = 6
        strictEditor.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)
        strictScroll.widthAnchor.constraint(equalTo: strictEditor.widthAnchor).isActive = true
        strictEditor.isHidden = true

        customModelField.placeholderString = "Custom model ID (e.g. minimax/minimax-m3.1-flash:free)"
        customModelField.font = .systemFont(ofSize: 11.5); customModelField.controlSize = .small
        customModelField.target = self; customModelField.action = #selector(applyCustomModel)
        customModelField.setAccessibilityLabel("Custom OpenRouter cleanup model ID")
        let useCustom = ActionButton(title: "Use Model") { [weak self] in self?.applyCustomModel() }
        useCustom.controlSize = .small
        let customStack = NSStackView(views: [customModelField, useCustom])
        customStack.orientation = .horizontal; customStack.spacing = 6; customStack.alignment = .centerY
        customModelField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        customModelField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let customRow = padded(customStack, vertical: 6)

        let cleanup = rows([
            toggleRow("sparkles", "Clean up with AI", "Removes ums, repeats and words you take back.", aiCleanup),
            rowDivider(inset: 0),
            pickerRow("Style", cleanupStyle),
            rowDivider(inset: 0),
            pickerRow("Model", cleanupModel, modelNote),
            customRow,
            rowDivider(inset: 0),
            controlRow("lock.shield", "Strict in these apps", strictAppsDetail, editStrict),
            strictEditor,
            rowDivider(inset: 0),
            toggleRow("graduationcap", "Learn from my corrections", "Corrections after a paste become suggestions for you to approve.", learnCorrections),
            rowDivider(inset: 0),
            toggleRow("text.badge.plus", "Add names I say often", "Names said often appear in your vocabulary inbox.", autoAddNames)
        ])

        let capture = rows([
            captureShortcutHint,
            toggleRow("text.viewfinder", "Capture screen", "Whatever is in the front window becomes a Markdown note: pages, documents, apps and images.", screenText),
            rowDivider(inset: 0),
            toggleRow("doc.on.clipboard", "Also copy captured text", "After a window clip, also put the Markdown on the system clipboard.", copyAfterCapture)
        ])

        if pillTheme.numberOfItems == 0 { pillTheme.addItems(withTitles: PillStyle.Theme.allCases.map(\.title)) }
        if pillMotion.numberOfItems == 0 { pillMotion.addItems(withTitles: PillStyle.Motion.allCases.map(\.title)) }
        pillTheme.setAccessibilityLabel("Pill colour")
        pillMotion.setAccessibilityLabel("Koa motion")
        let appearance = rows([pickerRow("Pill colour", pillTheme), rowDivider(inset: 0), pickerRow("Koa motion", pillMotion)])
        let clipboard = rows([
            toggleRow("clipboard", "Keep text on the clipboard", "Off: your previous clipboard comes back after each paste.", keepOnClipboard),
            rowDivider(inset: 0),
            toggleRow("rectangle.portrait.and.arrow.right", "Close when I click elsewhere", "Off: this panel stays open until you click the menu-bar icon.", closesOnOutsideClick),
            rowDivider(inset: 0),
            toggleRow("power", "Open at login", "Mercurius starts when you log in, so Fn works after a restart.", opensAtLogin)
        ])

        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = Self.contentWidth
        let setup = ActionButton(title: "Setup checklist…") { [weak self] in self?.hide(); self?.openSetup?() }
        setup.controlSize = .small
        let logs = ActionButton(title: "Show log") {
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Mercurius")
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
        logs.controlSize = .small
        let usage = ActionButton(title: "Usage & budget…") { [weak self] in self?.hide(); self?.showUsage?() }
        let presets = ActionButton(title: "App presets…") { [weak self] in self?.hide(); self?.showAppPresets?() }
        let writing = ActionButton(title: "Writing tools & snippets…") { [weak self] in self?.hide(); self?.showWritingTools?() }
        let health = ActionButton(title: "Health & diagnostics…") { [weak self] in self?.hide(); self?.showHealth?() }
        let buttons = NSStackView(views: [NSStackView(views: [setup, logs]), NSStackView(views: [usage, presets]), writing, health]); buttons.orientation = .vertical; buttons.alignment = .leading

        let inbox = ActionButton(title: "Vocabulary inbox…") { [weak self] in self?.hide(); self?.showVocabularyInbox?() }
        let vocabulary = rows([dictionaryRow, rowDivider(), takeBackRow, inbox])
        let dictation = NSStackView(views: [Card(voice, inset: Self.rowInset), Card(cleanup, inset: Self.rowInset)])
        let captures = NSStackView(views: [Card(capture, inset: Self.rowInset)])
        let learningNotice = NSTextField(wrappingLabelWithString: "New: your name fixes now join the dictionary by themselves. Undo them in Vocabulary inbox.")
        learningNotice.isHidden = !approvalFirstNotice
        let general = NSStackView(views: [learningNotice, Card(vocabulary, inset: Self.rowInset), Card(appearance, inset: Self.rowInset), Card(clipboard, inset: Self.rowInset), status, buttons])
        settingsGroups = [dictation, captures, general]
        for group in [dictation, captures, general] {
            group.orientation = .vertical; group.alignment = .leading; group.spacing = 12
            for view in group.arrangedSubviews { view.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true }
        }
        settingsSections.target = self; settingsSections.action = #selector(changeSettingsSection)
        settingsSections.selectedSegment = 0; settingsSections.segmentDistribution = .fillEqually
        settingsSections.setAccessibilityLabel("Settings category")
        settingsSections.font = .systemFont(ofSize: 13, weight: .medium)
        settingsSections.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let stack = NSStackView(views: [settingsSections, dictation, captures, general])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        changeSettingsSection()
        return stack
    }
    static let koaOrange = NSColor(srgbRed: 1, green: 0x5B / 255.0, blue: 0x18 / 255.0, alpha: 1)
    private static let rowInset = NSEdgeInsets(top: 2, left: 12, bottom: 2, right: 12)
    static let engineNames = ["OpenRouter speech", "Gemini one-step", "On-device", "On-device + AI cleanup", "ElevenLabs Scribe · your credits"]
    private static let engineModels: [String?] = [CloudSpeech.model, CloudSpeech.oneStepModel, nil, nil, nil]

    // Rebuild a picker from its model list, keeping the current selection by id.
    func rebuildCleanupPicker() {
        let selected = cleanupModel.selectedItem?.representedObject as? String
        cleanupModel.removeAllItems()
        for model in cleanupModels {
            cleanupModel.addItem(withTitle: model.name)
            cleanupModel.lastItem?.representedObject = model.id
        }
        // A saved model the catalogue has not delivered yet stays visible, so
        // the menu and the engine never disagree about what is selected.
        if let selected, !cleanupModels.contains(where: { $0.id == selected }) {
            cleanupModel.addItem(withTitle: ModelCosts.shortName(selected))
            cleanupModel.lastItem?.representedObject = selected
        }
        if let selected, let index = cleanupModel.itemArray.firstIndex(where: { $0.representedObject as? String == selected }) {
            cleanupModel.selectItem(at: index)
        }
    }
    func rebuildSpeechPicker() {
        let selected = speechModel.selectedItem?.representedObject as? String
        speechModel.removeAllItems()
        for id in speechModelIDs {
            speechModel.addItem(withTitle: ModelCosts.shortName(id))
            speechModel.lastItem?.representedObject = id
            speechModel.lastItem?.toolTip = id
        }
        if let selected, !speechModelIDs.contains(selected) {
            speechModel.addItem(withTitle: ModelCosts.shortName(selected))
            speechModel.lastItem?.representedObject = selected
            speechModel.lastItem?.toolTip = selected
        }
        if let selected, let index = speechModel.itemArray.firstIndex(where: { $0.representedObject as? String == selected }) {
            speechModel.selectItem(at: index)
        }
    }
    // App calls this when the live catalogue lands: new models become selectable
    // without an app update, and the prices refresh to match.
    func updateCatalogue(cleanup: [AICleanup.Model], speech: [String]) {
        // An unchanged catalogue must not rebuild (and close) an open menu.
        guard cleanup.map(\.id) != cleanupModels.map(\.id) || speech != speechModelIDs else { refreshPrices(); return }
        cleanupModels = cleanup
        if let custom = AICleanup.customModel(customModelField.stringValue), !cleanupModels.contains(where: { $0.id == custom.id }) { cleanupModels.append(custom) }
        speechModelIDs = speech
        rebuildCleanupPicker()
        rebuildSpeechPicker()
        refreshPrices()
    }

    func populateCleanupModels(custom: String? = nil, selected: String? = nil) {
        let current = selected ?? (cleanupModel.selectedItem?.representedObject as? String)
        cleanupModel.removeAllItems()
        if let custom, let model = AICleanup.customModel(custom), !cleanupModels.contains(where: { $0.id == model.id }) { cleanupModels.append(model) }
        for model in cleanupModels {
            cleanupModel.addItem(withTitle: model.name)
            cleanupModel.lastItem?.representedObject = model.id
        }
        if let current, let index = cleanupModel.itemArray.firstIndex(where: { $0.representedObject as? String == current }) {
            cleanupModel.selectItem(at: index)
        }
        refreshPrices()
    }
    @objc func applyCustomModel() {
        let slug = customModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let model = AICleanup.customModel(slug) else { return }
        saveCustomCleanupModel?(model.id)
        populateCleanupModels(custom: model.id, selected: model.id)
    }

    // Catalogue rates appear only in picker menus; history and daily usage show actual charges.
    func refreshPrices() {
        for (index, item) in engine.itemArray.enumerated() where index < Self.engineNames.count {
            let price = Self.engineModels[index].flatMap { self.price?($0) }.flatMap(ModelCosts.label)
            item.title = Self.engineNames[index] + (index == 2 ? " · free" : index == 3 ? " · speech free" : price.map { " · " + $0 } ?? "")
        }
        let cleanupByID = Dictionary(cleanupModels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in cleanupModel.itemArray {
            guard let id = item.representedObject as? String,
                  let model = cleanupByID[id] else { continue }
            let name = model.name.components(separatedBy: " · ")[0]
            let rate = price?(id).flatMap(ModelCosts.label) ?? (id.hasSuffix(":free") ? "free" : "rate unavailable")
            item.title = name + " · " + rate
            item.toolTip = model.name + ". Catalogue rate in USD: " + rate
        }
        for item in speechModel.itemArray {
            guard let id = item.representedObject as? String else { continue }
            let rate = price?(id).flatMap(ModelCosts.label) ?? (id.hasSuffix(":free") ? "free" : "rate unavailable")
            item.title = ModelCosts.shortName(id) + " · " + rate
        }
        // The speech model only drives the Grok (transcription) engine.
        speechModel.isEnabled = engine.indexOfSelectedItem == 0
        let selected = max(0, engine.indexOfSelectedItem)
        engineNote.stringValue = [
            "\(ModelCosts.shortName(CloudSpeech.model)) transcribes; the cleanup model below tidies the text.",
            "\(ModelCosts.shortName(CloudSpeech.oneStepModel)) transcribes and cleans in one call.",
            "Audio never leaves this Mac, and nothing is cleaned online.",
            "Audio stays on this Mac. Online text cleanup is billed separately.",
            "Audio goes directly to ElevenLabs and uses your credits. Standard provider retention applies. Dictionary words are not sent. Optional text cleanup uses OpenRouter."
        ][min(selected, 4)]
        // Only Grok takes dictionary key terms; say what another engine gives up.
        if selected == 0, let id = speechModel.selectedItem?.representedObject as? String, !id.hasPrefix("x-ai/") {
            engineNote.stringValue = "\(ModelCosts.shortName(id)) transcribes; the cleanup model below tidies the text. Dictionary words are not sent to this speech model."
        }
        let modelID = cleanupModel.selectedItem?.representedObject as? String ?? AICleanup.catalog[0].id
        let cleanupActive = selected != 2 && aiCleanup.state == .on
        cleanupModel.isEnabled = cleanupActive
        customModelField.isEnabled = cleanupActive
        modelNote.setAccessibilityLabel("Cleanup model details")
        modelNote.toolTip = nil
        modelNote.setAccessibilityHelp(nil)
        if selected == 2 {
            modelNote.stringValue = "On-device only. This model is not used."
        } else if !cleanupActive {
            modelNote.stringValue = "AI cleanup is off. This model is not used."
        } else {
            let models = AICleanup.order(choosing: modelID, from: cleanupModels)
            let backup = models.dropFirst().map { $0.name.components(separatedBy: " · ")[0] }.joined(separator: ", ")
            modelNote.stringValue = (selected == 1 ? "For take-back phrases. " : "")
                + "Cleanup sends the transcript, app name and dictionary terms."
                + (models[0].trains ? " Free endpoint may train on this data." : "")
            modelNote.toolTip = "If the selected model cannot provide usable text, cleanup may try \(backup). Each actual charge appears in dictation details. Prices in the model menu are catalogue rates in USD."
        }
        modelNote.setAccessibilityHelp(modelNote.toolTip)
        let styleExplanation = cleanupStyle.indexOfSelectedItem == 1
            ? "Only removes words. Nothing is reworded." : "Writes what you meant: fixes grammar, merges corrections."
        cleanupStyle.toolTip = styleExplanation
        cleanupStyle.setAccessibilityHelp(styleExplanation)
    }
    // "Today $0.012 · 120 words spoken", then the per-model split and where the prices come from.
    func refreshCosts() {
        let today = todaysCosts?()
        costsTotal.stringValue = today?.total ?? "Today $0 · 0 words today"
        costsTotal.toolTip = "Provider-reported spend in USD, recognized words delivered today, and all-time words since this counter started. Open Usage & budget for the model breakdown."
        costsTotal.setAccessibilityHelp(costsTotal.toolTip)
        costsModels.stringValue = today?.perModel.map { "Today’s billed models · " + $0 } ?? "No online charges recorded today."
        if let at = pricesUpdated?() {
            let time = DateFormatter(); time.dateStyle = .none; time.timeStyle = .short
            pricesNote.stringValue = "USD · Actual charges above. Menu rates updated \(time.string(from: at))."
        } else { pricesNote.stringValue = "USD · Actual charges above. Catalogue rates load when online." }
    }
    private func rows(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.spacing = 0
        for row in views { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }
    private func panelSymbol(_ name: String) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return icon
    }
    private func rowTitle(_ symbol: String, _ title: String, _ note: String?) -> NSStackView {
        let name = NSTextField(labelWithString: title); name.font = .systemFont(ofSize: 13)
        let lines: [NSView] = [name]
        if let note {
            name.toolTip = note
            name.setAccessibilityHelp(note)
        }
        let text = NSStackView(views: lines); text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [panelSymbol(symbol), text])
        row.alignment = .centerY; row.spacing = 10
        return row
    }
    // Compact settings rows keep explanations in tooltips and accessibility help.
    private func toggleRow(_ symbol: String, _ title: String, _ note: String?, _ control: NSSwitch) -> NSView {
        control.controlSize = .small; control.setAccessibilityLabel(title)
        return controlRow(symbol, title, nil, control, noteText: note)
    }
    // Tile and title on the left; an optional detail and a control on the right.
    private func controlRow(_ symbol: String, _ title: String, _ detail: NSView?, _ control: NSView,
                            noteText: String? = nil) -> NSView {
        let left = rowTitle(symbol, title, noteText)
        let right = [detail, control].compactMap { $0 }
        let trailing = NSStackView(views: right); trailing.spacing = 8; trailing.alignment = .centerY
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [left, trailing]); row.alignment = .centerY; row.spacing = 10; row.distribution = .fill
        return padded(row, vertical: 9)
    }
    // Picker labels share a row with their control; data-sharing notes stay visible.
    private func pickerRow(_ title: String, _ popup: NSPopUpButton, _ note: NSTextField? = nil) -> NSView {
        let name = NSTextField(labelWithString: title); name.font = .systemFont(ofSize: 12, weight: .medium)
        name.widthAnchor.constraint(equalToConstant: 90).isActive = true
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [name, popup]); row.alignment = .centerY; row.spacing = 8
        let stack = NSStackView(views: [row] + (note.map { [$0] } ?? [])); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return padded(stack, vertical: 8)
    }

    // Clipboard: everything CursusVox made, newest first, each with Copy, Pin and a menu.
    private func clipboardView() -> NSView {
        clipboardSearch.placeholderString = "Search titles or sources"
        clipboardSearch.setAccessibilityLabel("Search clipboard titles or sources")
        clipboardSearch.target = self; clipboardSearch.action = #selector(filterClipboard)
        clipboardSearch.sendsSearchStringImmediately = true
        clipboardFilter.target = self; clipboardFilter.action = #selector(filterClipboard)
        clipboardFilter.font = .systemFont(ofSize: 13, weight: .medium)
        clipboardFilter.controlSize = .regular; clipboardFilter.segmentDistribution = .fillEqually; clipboardFilter.selectedSegment = 0
        clipboardFilter.setAccessibilityLabel("Clipboard item kind")
        clipboardList.orientation = .vertical; clipboardList.alignment = .leading; clipboardList.spacing = 0
        clipboardEmptyTitle.font = .systemFont(ofSize: 14, weight: .medium)
        clipboardEmptyHelp.font = .systemFont(ofSize: 12); clipboardEmptyHelp.textColor = .secondaryLabelColor
        clipboardEmptyHelp.preferredMaxLayoutWidth = Self.contentWidth - 70
        let emptyText = NSStackView(views: [clipboardEmptyTitle, clipboardEmptyHelp])
        emptyText.orientation = .vertical; emptyText.alignment = .leading; emptyText.spacing = 2
        let emptyRow = NSStackView(views: [symbolTile("doc.on.clipboard", color: .systemTeal, size: 30), emptyText])
        emptyRow.spacing = 10; emptyRow.alignment = .centerY
        let empty = Card(emptyRow); clipboardEmpty = empty
        clipboardNote.font = .systemFont(ofSize: 11.5); clipboardNote.isHidden = true
        clipboardNote.preferredMaxLayoutWidth = Self.contentWidth
        clipboardWarning.font = .systemFont(ofSize: 11.5); clipboardWarning.textColor = .systemOrange
        clipboardWarning.isHidden = true; clipboardWarning.preferredMaxLayoutWidth = Self.contentWidth
        let folder = ActionButton(title: "Open Clips folder") { [weak self] in
            // The vault only exists after the first save; make it so the button always opens something.
            do { try ClipsVault.prepare(); NSWorkspace.shared.open(ClipsVault.folder) }
            catch { self?.clipboardStatus("Couldn't create the Clips folder.", ok: false) }
        }
        folder.controlSize = .small
        let privacy = small("Unsaved clips and window captures expire after 48 hours unless you Pin them in Clipboard. Pin keeps history only — it does not write a note. Save to Clips writes Markdown into ~/Mercurius Clips permanently. Dictations erase after 10 minutes.")
        // The rows sit in a card like Home's own list, so hover and spacing match.
        let list = Card(clipboardList, inset: NSEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)); clipboardCard = list
        let retention = ActionButton(title: "Retention details") { privacy.isHidden.toggle() }
        retention.bezelStyle = .rounded; retention.controlSize = .small
        privacy.isHidden = true
        let tools = NSStackView(views: [folder, retention]); tools.spacing = 12
        let retentionSummary = small("Unsaved clips: 48 h unless Pin. Save to Clips → ~/Mercurius Clips. Pin ≠ Save.")
        let stack = NSStackView(views: [clipboardSearch, clipboardFilter, clipboardWarning, clipboardNote, empty, list, retentionSummary, tools, privacy])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.setCustomSpacing(12, after: list)
        for view in [clipboardSearch, clipboardFilter, empty, list, clipboardWarning, clipboardNote, retentionSummary, privacy] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }
    @objc private func filterClipboard() { clipboardLimit = Self.clipboardPage; loadClipboard(force: true) }
    // A result that arrives later (a save finishing), shown like a row's own message.
    func clipboardMessage(_ text: String, ok: Bool) { clipboardStatus(text, ok: ok) }
    private func clipboardStatus(_ text: String, ok: Bool) {
        clipboardNote.stringValue = text; clipboardNote.isHidden = false
        clipboardNote.textColor = ok ? .secondaryLabelColor : .systemOrange
        NSAccessibility.post(element: clipboardNote, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    // Rebuilds the rows when the items changed (or `force`), so hovering isn't interrupted every
    // second. A storage problem is shown (or cleared) whatever the rows did: a background write
    // failing changes no row, and its warning must still appear.
    func loadClipboard(force: Bool = false) {
        showProblem(clipboardProblem?())
        let all = clipboardItems?() ?? []
        let kinds: [ClipboardStore.Kind]? = [nil, [.clip], [.capture], [.dictation]][min(3, max(0, clipboardFilter.selectedSegment))]
        let query = clipboardSearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = all.filter { item in
            (kinds?.contains(item.kind) ?? true) && (query.isEmpty || item.title.localizedStandardContains(query)
                || item.source?.localizedStandardContains(query) == true)
        }
        clipboardEmptyTitle.stringValue = query.isEmpty ? "Nothing here yet" : "No matches"
        let binding: Binding = shortcut.indexOfSelectedItem == 1 ? .controlOption : .fn
        clipboardEmptyHelp.stringValue = query.isEmpty
            ? "Capture what's on screen with \(binding.chord("T")), or dictate. Save to Clips to keep a note in ~/Mercurius Clips."
            : "Try a different title or source, or another filter."
        let items = Array(matching.prefix(clipboardLimit))
        let hidden = matching.count - items.count
        let minute = Int(Date().timeIntervalSince1970 / 60)
        guard force || items != shownClipboard || hidden != clipboardHidden || minute != shownMinute else { return }
        shownClipboard = items; clipboardHidden = hidden; shownMinute = minute
        for view in clipboardList.arrangedSubviews { clipboardList.removeArrangedSubview(view); view.removeFromSuperview() }
        clipboardEmpty?.isHidden = !items.isEmpty; clipboardCard?.isHidden = items.isEmpty
        for (index, item) in items.enumerated() {
            if index > 0 { let line = rowDivider(); clipboardList.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: clipboardList.widthAnchor).isActive = true }
            let row = clipboardRow(item)
            clipboardList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: clipboardList.widthAnchor).isActive = true
        }
        if hidden > 0 {
            let more = ActionButton(title: "Show \(min(hidden, Self.clipboardPage)) more (\(hidden) older)") { [weak self] in
                guard let self else { return }
                clipboardLimit += Self.clipboardPage; loadClipboard(force: true)
            }
            more.controlSize = .small
            let holder = NSStackView(views: [more]); holder.edgeInsets = NSEdgeInsets(top: 8, left: 6, bottom: 6, right: 6)
            clipboardList.addArrangedSubview(holder)
        }
    }
    private func showProblem(_ problem: String?) {
        guard problem != shownProblem else { return }
        shownProblem = problem
        clipboardWarning.stringValue = problem ?? ""; clipboardWarning.isHidden = problem == nil
        if let problem {
            NSAccessibility.post(element: clipboardWarning, notification: .announcementRequested,
                                 userInfo: [.announcement: problem, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
    private func act(_ action: ClipboardAction, _ item: ClipboardStore.Item) {
        guard let result = clipboardAction?(action, item) else { loadClipboard(force: true); return }
        clipboardStatus(result.message, ok: result.ok)
        loadClipboard(force: true)
    }
    private func clipboardRow(_ item: ClipboardStore.Item) -> NSView {
        let (symbol, kind): (String, String) = switch item.kind {
        case .clip: ("scissors", "Clip")
        case .capture: ("text.viewfinder", "Text")
        case .dictation: ("mic.fill", "Dictation")
        }
        let title = NSTextField(labelWithString: item.title.isEmpty ? kind : item.title)
        title.font = .systemFont(ofSize: 12.5, weight: .medium); title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let meta = NSTextField(labelWithAttributedString: Self.meta(item, kind: kind))
        meta.lineBreakMode = .byTruncatingTail; meta.maximumNumberOfLines = 1; meta.cell?.usesSingleLineMode = true
        meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [title, meta]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.setContentHuggingPriority(.init(1), for: .horizontal)
        let copy = SymbolButton("doc.on.doc", label: "Copy", size: 12) { [weak self] in self?.act(.copy, item) }
        var trailing: [NSView] = [copy]
        // Dictations can't be pinned (their text is always erased after 10 minutes), and a saved
        // note is kept anyway, so Pin shows only where it changes something.
        if item.kind != .dictation && (item.saved == nil || item.pinned) {
            let pin = SymbolButton(item.pinned ? "pin.fill" : "pin", label: item.pinned ? "Unpin" : "Pin", size: 12) { [weak self] in
                self?.act(.pin, item)
            }
            if item.pinned { pin.tint = .systemTeal }
            trailing.append(pin)
        }
        let more = SymbolButton("ellipsis.circle", label: "More", size: 12) {}
        more.target = self; more.action = #selector(showRowMenu(_:)); more.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        trailing.append(more)
        let buttons = NSStackView(views: trailing); buttons.spacing = 9
        buttons.setContentHuggingPriority(.required, for: .horizontal)
        buttons.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [panelSymbol(symbol), text, buttons])
        row.spacing = 10; row.alignment = .centerY
        let control = HoverControl(row, inset: NSEdgeInsets(top: 7, left: 6, bottom: 7, right: 8)) { [weak self] in
            self?.act(item.kind == .clip ? .open : .copy, item)
        }
        control.setAccessibilityLabel("\(kind): \(item.title.isEmpty ? kind : item.title)")
        control.setAccessibilityHelp(item.kind == .clip ? "Opens the clip to review" : "Copies it")
        return control
    }
    @objc private func showRowMenu(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let item = shownClipboard?.first(where: { $0.id.uuidString == id }) else { return }
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String, _ action: ClipboardAction) {
            let entry = ClosureMenuItem(title: title) { [weak self] in self?.act(action, item) }
            entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(entry)
        }
        switch item.kind {
        case .clip:
            add("Review…", "rectangle.and.pencil.and.ellipsis", .open)
            if item.saved != nil {
                add("Open note", "arrow.up.forward.square", .openFile); add("Reveal in Finder", "folder", .reveal)
            } else { add("Save to Clips", "tray.and.arrow.down", .save) }
        case .capture:
            if item.saved != nil {
                add("Open note", "arrow.up.forward.square", .openFile); add("Reveal in Finder", "folder", .reveal)
            }
            // Always offered: a saved capture whose note was moved or deleted is written again from its kept
            // text, and one whose note is still there just returns it (saveToClips checks first).
            add("Save to Clips", "tray.and.arrow.down", .save)
        case .dictation: break
        }
        if item.kind != .dictation && (item.saved == nil || item.pinned) {
            add(item.pinned ? "Unpin" : "Pin", item.pinned ? "pin.slash" : "pin", .pin)
        }
        menu.addItem(.separator())
        add("Delete", "trash", .delete)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }
    // "Saved · example.com · 2:31 pm · 4 KB": what will happen to it first, so it never truncates
    // away; the kind is the row's icon (and its spoken label).
    static func meta(_ item: ClipboardStore.Item, kind: String, now: Date = Date()) -> NSAttributedString {
        let time = DateFormatter(); time.timeStyle = .short
        time.dateStyle = Calendar.current.isDateInToday(item.at) ? .none : .short
        time.doesRelativeDateFormatting = true
        var badge: (String, NSColor)
        switch item.kind {
        case .dictation:
            let left = max(1, Int(ceil((ClipboardStore.dictationLifetime - now.timeIntervalSince(item.at)) / 60)))
            badge = ("Erased in \(left) min", .secondaryLabelColor)
        case _ where item.saved != nil: badge = ("Saved", .systemTeal)
        case _ where item.pinned: badge = ("Pinned", .systemTeal)
        case .clip, .capture:
            let hours = max(1, Int(ceil((ClipboardStore.lifetime - now.timeIntervalSince(item.at)) / 3600)))
            badge = (item.kind == .clip ? "Unsaved · \(hours) h left" : "\(hours) h left", .secondaryLabelColor)
        }
        var parts: [String] = []
        if let source = item.source, !source.isEmpty { parts.append(source) }
        parts.append(time.string(from: item.at))
        if item.kind != .dictation { parts.append(ClipDraft.size(item.bytes)) }
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
        let text = NSMutableAttributedString(string: badge.0, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                                           .foregroundColor: badge.1])
        text.append(NSAttributedString(string: " · " + parts.joined(separator: " · "), attributes: base))
        return text
    }

    // Title and one-line explanation on the left, a switch on the right.
    private func switchRow(_ title: String, _ detail: String, _ control: NSSwitch) -> NSView {
        control.controlSize = .small; control.setAccessibilityLabel(title)
        let name = NSTextField(labelWithString: title); name.font = .systemFont(ofSize: 13)
        let note = NSTextField(wrappingLabelWithString: detail)
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = Self.contentWidth - 90
        let text = NSStackView(views: [name, note]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [text, control]); row.alignment = .centerY; row.spacing = 10
        row.distribution = .fill
        return padded(row, vertical: 10)
    }
    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: 12, weight: .semibold)
        return field
    }
    // `width`: the space the text actually has (less inside a card, whose padding is 12 a side).
    private func small(_ text: String, width: CGFloat = HomePanel.contentWidth) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 12); field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = width
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    // MARK: dictionary

    private func copyTranscript(_ entry: HistoryEntry) {
        if let copyEntry { copyEntry(entry) } else { copy?(entry.text) }
    }
    // The words box shows the user's saved entries in the same format the import reads.
    func loadDictionary() {
        let saved = savedDictionary?() ?? (terms: [], replacements: [:])
        let pairs = saved.replacements.sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value)" }
        let paired = Set(saved.replacements.values.map { $0.lowercased() })
        let terms = saved.terms.filter { !paired.contains($0.lowercased()) }
        // An edit in progress is never replaced by a background change (a learned word).
        if !wordsDirty {
            wordsBox.string = (pairs + terms).joined(separator: "\n"); wordsSnapshot = wordsBox.string
            let hints = recognitionOnlyTerms?() ?? []
            wordsNote.stringValue = hints.isEmpty ? "" : "\(hints.count) recognition-only terms. They create no automatic replacements. Add an explicit → rule to replace words."
        }
        refreshCount(saved)
        updatePreview()
        // Names said 3+ times today that aren't in the dictionary: one click adds each.
        for view in suggestionRow.arrangedSubviews { suggestionRow.removeArrangedSubview(view); view.removeFromSuperview() }
        let full = currentVocabulary().terms.count >= Vocabulary.maxTerms
        let found = full ? [] : Array((suggestions?() ?? []).prefix(3))
        suggestionRow.isHidden = found.isEmpty
        if !found.isEmpty { suggestionRow.addArrangedSubview(small("Said often:")) }
        for suggestion in found {
            let button = ActionButton(title: "+ \(suggestion.term) (\(suggestion.count)×)") { [weak self] in
                guard let self else { return }
                let saved = savedDictionary?() ?? (terms: [], replacements: [:])
                saveDictionary?((saved.terms + [suggestion.term], saved.replacements))
                loadDictionary()
            }
            button.controlSize = .small
            suggestionRow.addArrangedSubview(button)
        }
    }
    private func refreshCount(_ saved: (terms: [String], replacements: [String: String])) {
        let total = Vocabulary(terms: builtIn.terms + saved.terms).terms.count
        // A full list used to fail silently; say so, and how to make room.
        count.stringValue = total >= Vocabulary.maxTerms
            ? "\(total) of \(Vocabulary.maxTerms) words — full; delete a word to add more"
            : "\(total) of \(Vocabulary.maxTerms) words"
    }
    private func currentVocabulary() -> Vocabulary {
        let saved = savedDictionary?() ?? (terms: [], replacements: [:])
        let allTerms = builtIn.terms + saved.terms
        var merged: [String: String] = [:]
        for pair in builtIn.replacements { merged[pair.from] = pair.to }
        for (from, to) in saved.replacements { merged[from] = to }
        return Vocabulary.effective(terms: allTerms, replacements: merged, recognitionOnly: recognitionOnlyTerms?() ?? [])
    }
    func updatePreview() {
        let result = DictionaryImport.parse(importBox.string, existing: currentVocabulary())
        let parts = [(result.newTerms.count + result.newReplacements.filter { pair in
                        !result.newTerms.contains(pair.to) }.count, "new"),
                     (result.alreadyHave.count, "already in"), (result.tooLong.count, "too long"),
                     (result.overLimit.count, "over the limit"), (result.skipped.count, "skipped")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        preview.stringValue = importBox.string.isEmpty ? "" : (parts.isEmpty ? "Nothing new" : parts.joined(separator: " · "))
        addButton.isEnabled = !result.newTerms.isEmpty || !result.newReplacements.isEmpty
    }
    @objc func quickAddWord() {
        let line = quickWordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        let result = DictionaryImport.parse(line, existing: currentVocabulary())
        guard !result.newTerms.isEmpty || !result.newReplacements.isEmpty else {
            wordsNote.stringValue = !result.alreadyHave.isEmpty ? "Already in your dictionary"
                : !result.overLimit.isEmpty ? "Over the \(Vocabulary.maxTerms)-word limit"
                : !result.tooLong.isEmpty ? "Too long (max \(Vocabulary.maxTermLength) characters)" : "Enter a word or misheard → correct"
            return
        }
        let saved = savedDictionary?() ?? (terms: [], replacements: [:])
        saveDictionary?(result.merged(into: saved))
        quickWordField.stringValue = ""
        loadDictionary()
    }
    @objc private func addImport() {
        let result = DictionaryImport.parse(importBox.string, existing: currentVocabulary())
        let saved = savedDictionary?() ?? (terms: [], replacements: [:])
        saveDictionary?(result.merged(into: saved))
        importBox.string = ""
        loadDictionary()
    }
    private func saveWords() {
        // Re-read the whole box as the user's list: deleted lines are removed. Nothing
        // is saved if any line wouldn't fit, so a word is never dropped silently.
        let result = DictionaryImport.parse(wordsBox.string, existing: builtIn)
        let problems = [(result.overLimit.count, "over the \(Vocabulary.maxTerms)-word limit"), (result.tooLong.count, "too long"),
                        (result.skipped.count, "not a name or term")].filter { $0.0 > 0 }
        guard problems.isEmpty else {
            wordsNote.stringValue = "Not saved: " + problems.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
            return
        }
        // Apply only what the user changed, so words added meanwhile aren't lost.
        guard let updated = DictionaryImport.applyEdit(from: wordsSnapshot, to: wordsBox.string, builtIn: builtIn,
                                                       saved: savedDictionary?() ?? (terms: [], replacements: [:])) else {
            wordsNote.stringValue = "Not saved: over the \(Vocabulary.maxTerms)-word limit"
            return
        }
        saveDictionary?(updated)
        wordsDirty = false
        loadDictionary()
    }
}

extension HomePanel: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        if (notification.object as? NSTextView) === importBox { updatePreview() }
        if (notification.object as? NSTextView) === wordsBox { wordsDirty = true; wordsNote.stringValue = "Unsaved" }
        if (notification.object as? NSTextView) === takeBackBox { takeBackNote.stringValue = "Unsaved" }
        if (notification.object as? NSTextView) === strictAppsBox { strictAppsNote.stringValue = "Unsaved" }
    }
}

@MainActor final class FlippedView: NSView { override var isFlipped: Bool { true } }

// A menu item that runs a closure (row menus built on the fly).
@MainActor final class ClosureMenuItem: NSMenuItem {
    private var run: (() -> Void)?
    convenience init(title: String, action: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self; run = action
    }
    @objc private func fire() { run?() }
}
