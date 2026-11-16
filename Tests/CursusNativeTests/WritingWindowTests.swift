import AppKit
import Foundation
import Testing
@testable import CursusVox

private actor ReadGate {
    private var continuation: CheckedContinuation<String?, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func read() async -> String? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation; observer?.resume(); observer = nil
        }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func finish() { continuation?.resume(returning: "Original retained text"); continuation = nil }
}

@Suite(.serialized) @MainActor struct WritingWindowTests {
    private func fixture(read: ((UUID) async -> String?)? = nil, model: @escaping () -> String? = { nil },
                         capture: (() async -> NativeWritingSelection.Snapshot?)? = nil) throws -> (WritingToolsWindow, ClipboardStore, URL, UserDefaults, String) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("writing-fixture-" + UUID().uuidString)
        let name = "WritingTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        let clipboard = ClipboardStore(root: root.appendingPathComponent("clips"), vault: root.appendingPathComponent("vault"))
        let window = WritingToolsWindow(clipboard: clipboard, history: { [] }, dictionary: { [] }, model: model,
            usage: UsageStore(url: root.appendingPathComponent("usage.json")), canRecord: { false }, defaults: defaults,
            captureSelection: capture ?? { nil }, readText: read)
        return (window, clipboard, root, defaults, name)
    }
    @Test func changedCommandCannotGenerateAnOlderCloudInstruction() async throws {
        var modelReads = 0
        let (window, clipboard, root, defaults, name) = try fixture(model: { modelReads += 1; return nil })
        defer { window.clearSession(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        await clipboard.ready(); await window.open(text: "Original", present: false)
        window.command.stringValue = "rewrite formal"; window.runCommand()
        window.command.stringValue = "translate to French"; window.generatePreview()
        #expect(modelReads == 0)
        #expect(window.source.string == "Original" && window.output.string.isEmpty)
    }
    @Test func recordedCommandOnlyFillsTheEditableFieldAndInvalidatesOlderWork() async throws {
        var modelReads = 0
        let (window, clipboard, root, defaults, name) = try fixture(model: { modelReads += 1; return nil })
        defer { window.clearSession(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        await clipboard.ready(); await window.open(text: "Original", present: false)
        window.command.stringValue = "rewrite formal"; window.runCommand()
        window.receiveSpokenCommand("Uppercase.")
        #expect(window.command.stringValue == "Uppercase")
        #expect(window.output.string.isEmpty && window.source.string == "Original")
        window.generatePreview()
        #expect(modelReads == 0 && window.output.string.isEmpty)
        window.runCommand()
        #expect(window.output.string == "ORIGINAL")
        window.clearSession(); window.receiveSpokenCommand("Lowercase.")
        #expect(window.command.stringValue.isEmpty)
    }
    @Test func editingRetainedTextKeepsItsDeletionProvenance() async throws {
        let (window, clipboard, root, defaults, name) = try fixture()
        defer { window.clearSession(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        await clipboard.ready()
        let id = clipboard.add(dictation: "Original retained text", at: Date())
        await window.open(present: false); window.command.stringValue = "search retained"; window.runCommand()
        await window.task?.value
        let result = try #require(window.results.arrangedSubviews.first as? NSButton)
        result.performClick(nil); await window.task?.value
        #expect(window.source.string == "Original retained text")
        window.source.string += " edited"
        window.textDidChange(Notification(name: NSText.didChangeNotification, object: window.source))
        clipboard.delete(id); window.refreshRetention()
        #expect(window.source.string.isEmpty && window.output.string.isEmpty)
        await clipboard.settled()
    }
    @Test func oldSearchLoadCannotOverwriteReopenedSession() async throws {
        let gate = ReadGate()
        let (window, clipboard, root, defaults, name) = try fixture(read: { _ in await gate.read() })
        defer { window.clearSession(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        await clipboard.ready(); clipboard.add(dictation: "Original retained text", at: Date())
        await window.open(present: false); window.command.stringValue = "search retained"; window.runCommand()
        await window.task?.value
        let result = try #require(window.results.arrangedSubviews.first as? NSButton)
        result.performClick(nil); let oldTask = window.task
        await gate.started()
        await window.open(text: "New session", present: false)
        await gate.finish(); await oldTask?.value
        #expect(window.source.string == "New session")
        await clipboard.settled()
    }
    @Test func commonModeRetentionPollClearsPastedTextAtDeadline() async throws {
        let (window, clipboard, root, defaults, name) = try fixture()
        defer { window.clearSession(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        await clipboard.ready(); await window.open(text: "Synthetic private text", present: false)
        window.command.stringValue = "uppercase"; window.runCommand()
        #expect(window.output.string == "SYNTHETIC PRIVATE TEXT")
        window.refreshRetention(now: Date().addingTimeInterval(601))
        #expect(window.source.string.isEmpty && window.output.string.isEmpty && window.command.stringValue.isEmpty)
    }

    @Test func interruptionClearsOriginalPreviewAndPendingCommand() async throws {
        let (window, clipboard, root, defaults, name) = try fixture()
        defer { window.clearSession(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        await clipboard.ready(); await window.open(text: "Synthetic original", present: false)
        window.command.stringValue = "uppercase"; window.runCommand()
        window.interrupt(reason: "Synthetic lock")
        #expect(window.source.string.isEmpty && window.output.string.isEmpty && window.command.stringValue.isEmpty)
        #expect(!window.commandCaptureActive)
    }

    @Test func interruptionDuringSelectionCaptureCannotOpenANewSessionAfterward() async throws {
        let gate = ReadGate()
        let (window, clipboard, root, defaults, name) = try fixture(capture: { _ = await gate.read(); return nil })
        defer { window.clearSession(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        await clipboard.ready()
        let opening = Task { await window.open(text: "Synthetic private text", present: false) }
        await gate.started(); window.interrupt(reason: "Synthetic lock while opening")
        await gate.finish(); await opening.value
        #expect(window.source.string.isEmpty && window.output.string.isEmpty)
    }

}
