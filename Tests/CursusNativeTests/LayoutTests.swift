import AppKit
import Testing
@testable import CursusVox

@MainActor struct LayoutTests {
    @Test func horizontalControlsOccupyOneRow() {
        let first = NSButton(title: "Record", target: nil, action: nil)
        let second = NSButton(title: "Stop", target: nil, action: nil)
        let row = NativeViews.stack([first, second], horizontal: true)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        host.addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor)])
        host.layoutSubtreeIfNeeded()
        #expect(abs(first.frame.midY - second.frame.midY) < 1)
        #expect(second.frame.minX > first.frame.maxX)
    }
}
