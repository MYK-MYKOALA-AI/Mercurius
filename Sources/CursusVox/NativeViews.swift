import AppKit

@MainActor enum NativeViews {
    static func stack(_ views: [NSView], horizontal: Bool) -> NSStackView {
        let view = NSStackView(views: views)
        view.orientation = horizontal ? .horizontal : .vertical
        view.alignment = horizontal ? .centerY : .leading
        view.spacing = 10
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }
}
