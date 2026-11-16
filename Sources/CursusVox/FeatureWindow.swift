import AppKit

// Native settings pages use a readable heading, aligned rows and explicit actions.
@MainActor final class FeatureWindow: NSObject, NSWindowDelegate {
    var closed: (() -> Void)?
    func windowWillClose(_ notification: Notification) { closed?() }
    let window: NSWindow
    let stack = NSStackView()
    init(title: String) {
        window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 580,height: 620),
                          styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
        super.init(); window.minSize = NSSize(width: 460, height: 360); window.title = title; window.isReleasedWhenClosed = false; window.delegate = self
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true
        window.contentView = scroll
        let document = FlippedView(); scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor,constant: 20),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor,constant: -20),
            stack.topAnchor.constraint(equalTo: document.topAnchor,constant: 20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor,constant: -20)])
    }
    func clear() { for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() } }
    @discardableResult func text(_ value: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value); label.isSelectable = true
        label.preferredMaxLayoutWidth = 520; stack.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true; return label
    }
    func button(_ title: String, action: @escaping () -> Void) {
        stack.addArrangedSubview(ActionButton(title: title, action: action))
    }
    func show() { window.center(); NSApp.activate(); window.makeKeyAndOrderFront(nil) }
}
