import AppKit
import Testing
@testable import CursusVox

@Suite(.serialized) @MainActor struct RecordingPillVisibilityTests {
    private typealias Conn = @convention(c) () -> Int32
    private typealias Mod = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias Spaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private func wait(_ time: TimeInterval) async { try? await Task.sleep(for: .seconds(time)) }

    @Test func aPanelOnTheActiveSpaceKeepsItsBehaviourUntouched() async {
        let panel = NSPanel(contentRect: NSRect(x: 2, y: 2, width: 2, height: 2), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.alphaValue = 0.01
        panel.collectionBehavior = RecordingPill.spaces
        panel.orderInOnActiveSpace(behavior: RecordingPill.spaces)
        await wait(0.1)
        #expect(panel.collectionBehavior == RecordingPill.spaces)
        panel.orderOut(nil)
    }

    // Needs a second Space to pin the panel away from; with one Space there is nothing to repair.
    @Test func aPanelPinnedToAnotherSpaceComesBack() async throws {
        let handle = dlopen(nil, RTLD_NOW)
        let main = unsafeBitCast(try #require(dlsym(handle, "CGSMainConnectionID")), to: Conn.self)
        let remove = unsafeBitCast(try #require(dlsym(handle, "CGSRemoveWindowsFromSpaces")), to: Mod.self)
        let copy = unsafeBitCast(try #require(dlsym(handle, "CGSCopySpacesForWindows")), to: Spaces.self)
        let panel = NSPanel(contentRect: NSRect(x: 2, y: 2, width: 2, height: 2), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.alphaValue = 0.01; panel.level = .statusBar
        panel.collectionBehavior = RecordingPill.spaces
        panel.orderFrontRegardless()
        await wait(0.3)
        let spaces = copy(main(), 7, [panel.windowNumber] as CFArray)?.takeRetainedValue() as? [Int] ?? []
        guard spaces.count > 1 else { panel.orderOut(nil); return }
        // Pin it to one Space that isn't the current one, the state seen in the wild.
        for space in spaces where !panel.isOnActiveSpace || spaces.first != space {
            remove(main(), [panel.windowNumber] as CFArray, [space] as CFArray); await wait(0.1)
            if !panel.isOnActiveSpace { break }
        }
        await wait(0.2)
        guard !panel.isOnActiveSpace else { panel.orderOut(nil); return }
        panel.orderFrontRegardless(); await wait(0.2)
        #expect(!panel.isOnActiveSpace, "plain ordering must not be enough, or this test proves nothing")
        panel.orderInOnActiveSpace(behavior: RecordingPill.spaces)
        await wait(0.3)
        #expect(panel.isOnActiveSpace)
        #expect(panel.collectionBehavior == RecordingPill.spaces)
        panel.orderOut(nil)
    }
}
