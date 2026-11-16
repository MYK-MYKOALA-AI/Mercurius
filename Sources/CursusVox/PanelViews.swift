import AppKit

// The panel's building blocks, in the style of Control Center: soft rounded
// cards on the popover's material, SF Symbols in coloured tiles, rows that
// highlight under the pointer. Colours are system ones, so light and dark work.

// Popover materials can supply a vibrant appearance whose text colours do not
// suit an opaque control. Resolve a standard app appearance for the whole panel.
@MainActor final class PanelSurface: NSView {
    private var appearanceObservation: NSKeyValueObservation?
    override var isOpaque: Bool { true }
    override var allowsVibrancy: Bool { false }
    init(content: NSView) {
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        synchronizeAppearance()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.synchronizeAppearance() }
        }
    }
    required init?(coder: NSCoder) { nil }
    private func synchronizeAppearance() {
        let name = NSApp.effectiveAppearance.bestMatch(from: [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua
        ]) ?? .aqua
        appearance = NSAppearance(named: name)
        needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}

// A rounded, faintly filled surface holding one view.
@MainActor final class Card: NSView {
    private var tint: NSColor?
    init(_ content: NSView, inset: NSEdgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12),
         tint: NSColor? = nil) {
        self.tint = tint
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12; layer?.cornerCurve = .continuous; layer?.borderWidth = 0.5
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: inset.top),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset.left),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset.right),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset.bottom)
        ])
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (tint?.withAlphaComponent(0.14) ?? NSColor.labelColor.withAlphaComponent(0.05)).cgColor
            layer?.borderColor = (tint?.withAlphaComponent(0.35) ?? NSColor.labelColor.withAlphaComponent(0.16)).cgColor
        }
    }
}

// A white SF Symbol on a small coloured rounded square, as in System Settings.
@MainActor func symbolTile(_ name: String, color: NSColor, size: CGFloat = 26) -> NSView {
    let tile = NSView()
    tile.wantsLayer = true
    tile.layer?.backgroundColor = color.cgColor
    tile.layer?.cornerRadius = size * 0.28; tile.layer?.cornerCurve = .continuous
    let image = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
    image.symbolConfiguration = .init(pointSize: size * 0.5, weight: .semibold)
    image.contentTintColor = .white
    image.translatesAutoresizingMaskIntoConstraints = false
    tile.addSubview(image)
    tile.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        tile.widthAnchor.constraint(equalToConstant: size), tile.heightAnchor.constraint(equalToConstant: size),
        image.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
        image.centerYAnchor.constraint(equalTo: tile.centerYAnchor)
    ])
    return tile
}

// A clickable row: tile, title, detail on the right, chevron. Highlights on hover.
@MainActor final class NavRow: NSControl {
    private let run: () -> Void
    let detail = NSTextField(labelWithString: "")
    private var hovering = false { didSet { needsDisplay = true } }

    init(title: String, symbol: String, color: NSColor, action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        let name = NSTextField(labelWithString: title); name.font = .systemFont(ofSize: 13)
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor
        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
        chevron.symbolConfiguration = .init(pointSize: 11, weight: .semibold); chevron.contentTintColor = .tertiaryLabelColor
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [symbolTile(symbol, color: color), name, spacer, detail, chevron])
        row.orientation = .horizontal; row.spacing = 10; row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 38)
        ])
        setAccessibilityRole(.button); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { hovering = false; run() }
    override func accessibilityPerformPress() -> Bool { run(); return true }
    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
}

// A thin line between rows inside a card, inset past the tile.
@MainActor func rowDivider(inset: CGFloat = 44) -> NSView {
    let line = NSBox(); line.boxType = .separator
    let holder = NSView(); line.translatesAutoresizingMaskIntoConstraints = false; holder.addSubview(line)
    NSLayoutConstraint.activate([
        line.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: inset),
        line.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: inset == 0 ? 0 : -8),
        line.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        holder.heightAnchor.constraint(equalToConstant: 1)
    ])
    return holder
}

// A borderless SF Symbol button for compact actions (copy, settings, back). Brightens under the pointer.
@MainActor final class SymbolButton: NSButton {
    private var run: (() -> Void)?
    var tint: NSColor = .secondaryLabelColor { didSet { contentTintColor = tint } }
    convenience init(_ symbol: String, label: String, size: CGFloat = 13, action: @escaping () -> Void) {
        self.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        symbolConfiguration = .init(pointSize: size, weight: .medium)
        isBordered = false; bezelStyle = .regularSquare; imagePosition = .imageOnly
        contentTintColor = tint; toolTip = label; setAccessibilityLabel(label)
        run = action; target = self; self.action = #selector(fire)
        setContentHuggingPriority(.required, for: .horizontal)
    }
    @objc private func fire() { run?() }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { if isEnabled { contentTintColor = .labelColor } }
    override func mouseExited(with event: NSEvent) { contentTintColor = tint }
}

// A row that highlights under the pointer and runs `action` when clicked anywhere but on one
// of its own buttons (Clipboard rows, the card's Properties header). Same look as NavRow.
@MainActor final class HoverControl: NSControl {
    private let run: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }
    init(_ content: NSView, inset: NSEdgeInsets, action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset.left),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset.right),
            content.topAnchor.constraint(equalTo: topAnchor, constant: inset.top),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset.bottom)
        ])
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { nil }
    // Clicks on labels and icons belong to the row; clicks on a button inside stay with the button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== self {
            if current is NSButton || current is NSTextView { return hit }
            view = current.superview
        }
        return self
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { run() }
    override func accessibilityPerformPress() -> Bool { run(); return true }
    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}

// A capsule button with a symbol and a title, filled for the main action.
@MainActor final class PillButton: NSButton {
    private var run: (() -> Void)?
    convenience init(_ title: String, symbol: String, prominent: Bool = false, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imagePosition = .imageLeading; imageHugsTitle = true
        bezelStyle = .push; controlSize = .regular
        if prominent { bezelColor = .controlAccentColor; keyEquivalent = "" }
        run = action; target = self; self.action = #selector(fire)
    }
    @objc private func fire() { run?() }
}

// A keyboard key drawn as a small rounded cap ("fn", "W", "space").
@MainActor func keyCap(_ label: String) -> NSView {
    let text = NSTextField(labelWithString: label)
    text.font = .monospacedSystemFont(ofSize: 11, weight: .semibold); text.textColor = .labelColor
    text.alignment = .center
    let cap = NSView(); cap.wantsLayer = true
    cap.layer?.cornerRadius = 5; cap.layer?.cornerCurve = .continuous; cap.layer?.borderWidth = 0.5
    cap.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.25).cgColor
    cap.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
    text.translatesAutoresizingMaskIntoConstraints = false; cap.translatesAutoresizingMaskIntoConstraints = false
    cap.addSubview(text)
    NSLayoutConstraint.activate([
        text.centerXAnchor.constraint(equalTo: cap.centerXAnchor), text.centerYAnchor.constraint(equalTo: cap.centerYAnchor),
        cap.heightAnchor.constraint(equalToConstant: 20),
        cap.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
        cap.widthAnchor.constraint(equalTo: text.widthAnchor, constant: 12)
    ])
    return cap
}

// One shortcut: its keys on the left (fixed column so rows line up), what it does on the right.
@MainActor func shortcutRow(_ keys: [String], joiner: String = "+", _ title: String, _ detail: String? = nil) -> NSView {
    var parts: [NSView] = []
    for (index, key) in keys.enumerated() {
        if index > 0 {
            let plus = NSTextField(labelWithString: joiner); plus.font = .systemFont(ofSize: 10); plus.textColor = .tertiaryLabelColor
            parts.append(plus)
        }
        parts.append(keyCap(key))
    }
    let keysRow = NSStackView(views: parts); keysRow.spacing = 3; keysRow.alignment = .centerY
    keysRow.translatesAutoresizingMaskIntoConstraints = false
    let column = NSView(); column.addSubview(keysRow); column.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        keysRow.leadingAnchor.constraint(equalTo: column.leadingAnchor), keysRow.centerYAnchor.constraint(equalTo: column.centerYAnchor),
        // Wide enough for the longest keys (ctrl + option + space) so caps never run into the text.
        keysRow.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor),
        column.widthAnchor.constraint(equalToConstant: 124), column.heightAnchor.constraint(equalToConstant: 22)
    ])
    let name = NSTextField(labelWithString: title); name.font = .systemFont(ofSize: 12.5, weight: .medium)
    var lines: [NSView] = [name]
    if let detail {
        let note = NSTextField(labelWithString: detail); note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        lines.append(note)
    }
    let text = NSStackView(views: lines); text.orientation = .vertical; text.alignment = .leading; text.spacing = 1
    text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let row = NSStackView(views: [column, text]); row.spacing = 8; row.alignment = .centerY
    return row
}

// Pads a view inside a card row so stacked rows breathe and dividers sit between them.
@MainActor func padded(_ view: NSView, vertical: CGFloat = 9) -> NSView {
    let holder = NSView(); holder.translatesAutoresizingMaskIntoConstraints = false
    view.translatesAutoresizingMaskIntoConstraints = false; holder.addSubview(view)
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: holder.leadingAnchor), view.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
        view.topAnchor.constraint(equalTo: holder.topAnchor, constant: vertical),
        view.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -vertical)
    ])
    return holder
}

// The one quiet pointer to who made this. Never shown during dictation.
@MainActor enum MadeByMyKoala {
    nonisolated static let url = URL(string: "https://mykoala.com.au/?utm_source=mercurius")!
    static func link() -> NSView {
        let button = ActionButton(title: "Made by MyKoala") { NSWorkspace.shared.open(url) }
        button.isBordered = false; button.font = .systemFont(ofSize: 11); button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityHelp("Opens mykoala.com.au in your browser")
        return button
    }
}
