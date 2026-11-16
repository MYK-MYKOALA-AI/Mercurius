import AppKit

// Setup checklist. Each row re-reads live state every second, so granting a
// permission ticks it off without reopening the app.
@MainActor final class Onboarding: NSObject, NSWindowDelegate {
    enum Status { case done, todo, warning, info }
    struct Row {
        let title: String
        let detail: String
        let status: Status
        let button: String?
        let action: (() -> Void)?
        var enabled = true
    }
    let window: NSWindow
    var rows: () -> [Row] = { [] }
    var closed: (() -> Void)?
    private let list = NSStackView()
    private let tryField = NSTextField()
    private let heading = NSTextField(wrappingLabelWithString: "")
    private var lastSignature = ""

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Set up Mercurius"; window.isReleasedWhenClosed = false; window.delegate = self
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 14
        tryField.placeholderString = "Click here, hold Fn and say something"
        tryField.setAccessibilityLabel("Try dictation here")
        let tryLabel = NSTextField(labelWithString: "Try it")
        tryLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let done = NSButton(title: "Continue", target: self, action: #selector(finish))
        done.keyEquivalent = "\r"
        let notice = NSTextField(wrappingLabelWithString:
            "Choose Allow beside each permission you want to grant. Opening this checklist does not request access. You can continue and return to setup later.")
        notice.font = .systemFont(ofSize: 12); notice.textColor = .secondaryLabelColor
        let root = NSStackView(views: [heading, notice, list, tryLabel, tryField, done])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 16
        root.setCustomSpacing(6, after: tryLabel)
        root.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(); window.contentView = content; content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -22),
            list.widthAnchor.constraint(equalTo: root.widthAnchor),
            tryField.widthAnchor.constraint(equalTo: root.widthAnchor),
            heading.widthAnchor.constraint(equalTo: root.widthAnchor),
            notice.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
        showDictationKey(fn: true)
    }
    func showDictationKey(fn: Bool) {
        let key = fn ? "Fn" : "Control+Option"
        heading.stringValue = "Hold \(key), talk, let go. Your words appear where you're typing."
        tryField.placeholderString = "Click here, hold \(key) and say something"
    }
    var isVisible: Bool { window.isVisible }
    func show() {
        refresh(force: true)
        window.center(); NSApp.activate(); window.makeKeyAndOrderFront(nil)
    }
    func refresh(force: Bool = false) {
        guard window.isVisible || force else { return }
        let current = rows()
        let signature = current.map { "\($0.title)|\($0.detail)|\($0.status)|\($0.button ?? "")|\($0.enabled)" }.joined(separator: "\n")
        guard force || signature != lastSignature else { return }
        lastSignature = signature
        for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }
        for row in current { list.addArrangedSubview(view(for: row)) }
    }
    private func view(for row: Row) -> NSView {
        let (symbol, color): (String, NSColor) = switch row.status {
        case .done: ("checkmark.circle.fill", .systemGreen)
        case .todo: ("circle", .secondaryLabelColor)
        case .warning: ("exclamationmark.triangle.fill", .systemOrange)
        case .info: ("info.circle", .secondaryLabelColor)
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = color
        icon.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let title = NSTextField(labelWithString: row.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: row.detail)
        detail.textColor = .secondaryLabelColor; detail.font = .systemFont(ofSize: 12)
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
        var views: [NSView] = [icon, text]
        if let label = row.button, let action = row.action {
            let button = ActionButton(title: label, action: action)
            button.isEnabled = row.enabled
            button.setAccessibilityLabel("\(label) \(row.title)")
            button.setContentHuggingPriority(.required, for: .horizontal)
            views.append(button)
        }
        let line = NSStackView(views: views)
        line.orientation = .horizontal; line.alignment = .top; line.spacing = 12
        title.setAccessibilityLabel("\(row.title): \(row.status == .done ? "done" : row.detail)")
        return line
    }
    @objc private func finish() { window.performClose(nil) }
    func windowWillClose(_ notification: Notification) { closed?() }
}

// A button that runs a closure, so rows can carry their own action.
@MainActor final class ActionButton: NSButton {
    private var run: (() -> Void)?
    convenience init(title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title; bezelStyle = .rounded; run = action
        target = self; self.action = #selector(fire)
    }
    @objc private func fire() { run?() }
}
