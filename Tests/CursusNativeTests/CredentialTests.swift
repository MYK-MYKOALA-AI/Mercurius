import Foundation
import Security
import AppKit
import Testing
@testable import CursusVox

struct CredentialTests {
    @Test func credentialValidationRejectsHeaderInjectionAndOversize() {
        #expect(CloudCredentials.validated(nil) == nil)
        #expect(CloudCredentials.validated("") == nil)
        #expect(CloudCredentials.validated("fixture\r\nInjected: value") == nil)
        #expect(CloudCredentials.validated("fixture\u{0}") == nil)
        #expect(CloudCredentials.validated(String(repeating: "x", count: 4097)) == nil)
        #expect(CloudCredentials.validated("original-synthetic-credential") == "original-synthetic-credential")
    }
}

private final class ReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var onMain = false
    func read() -> String? {
        lock.lock(); defer { lock.unlock() }
        calls += 1; onMain = onMain || Thread.isMainThread
        return "original-synthetic-credential"
    }
    var observations: (Int, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (calls, onMain)
    }
}

@MainActor @Test func cloudCredentialReadDoesNotRunInlineOnTheUIThread() async {
    let probe = ReadProbe()
    let speech = LocalSpeech(credentialRead: { probe.read() })
    defer { speech.shutdown() }
    speech.select(.cloud)
    #expect(!speech.cloudCredentialReady)
    // Waiting yields the main actor; the worker must complete independently.
    for _ in 0..<100 where !speech.cloudCredentialReady {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(speech.cloudCredentialReady)
    #expect(probe.observations.0 == 1)
    #expect(!probe.observations.1)
    speech.select(.apple)
    #expect(!speech.cloudCredentialReady)
}

private final class BlockingReadProbe: @unchecked Sendable {
    let entered: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    init() {
        let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        entered = channel.stream; continuation = channel.continuation
    }
    func read() -> String? {
        lock.lock(); calls += 1; lock.unlock()
        continuation.yield(())
        guard release.wait(timeout: .now() + 2) == .success else { return nil }
        return "original-synthetic-credential"
    }
    func unblock() { release.signal() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
}

@MainActor @Test func cloudReadsCoalesceAndAppleDiscardsPendingCredential() async {
    let probe = BlockingReadProbe()
    let speech = LocalSpeech(credentialRead: { probe.read() })
    defer { probe.unblock(); speech.shutdown() }
    for _ in 0..<100 { speech.select(.cloud) }
    for await _ in probe.entered { break }
    #expect(probe.count == 1)
    speech.select(.apple)
    probe.unblock()
    for _ in 0..<100 where speech.credentialReadPending {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(!speech.credentialReadPending)
    #expect(!speech.cloudCredentialReady)
    #expect(speech.backend == .apple)
}

@MainActor @Test func shutdownDiscardsPendingCredentialAndPreventsNewReads() async {
    let probe = BlockingReadProbe()
    let speech = LocalSpeech(credentialRead: { probe.read() })
    defer { probe.unblock(); speech.shutdown() }
    speech.select(.cloud)
    for await _ in probe.entered { break }
    speech.shutdown()
    speech.select(.cloud)
    probe.unblock()
    for _ in 0..<100 where speech.credentialReadPending {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(probe.count == 1)
    #expect(!speech.cloudCredentialReady)
}

@MainActor @Test func cloudAuthorizationRequiresExplicitActionAndCloudSelection() async {
    let authorization = ReadProbe()
    let speech = LocalSpeech(credentialRead: { nil }, credentialAuthorize: { authorization.read() })
    defer { speech.shutdown() }
    speech.authorizeCloudCredential()
    #expect(authorization.observations.0 == 0)
    speech.select(.cloud)
    for _ in 0..<100 where speech.credentialReadPending {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(!speech.cloudCredentialReady)
    #expect(authorization.observations.0 == 0)
    speech.authorizeCloudCredential()
    for _ in 0..<100 where !speech.cloudCredentialReady {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(speech.cloudCredentialReady)
    #expect(authorization.observations.0 == 1)
    #expect(!authorization.observations.1)
}

@MainActor @Test func queuedAuthorizationWaitsForPassiveReadAndCoalescesClicks() async {
    let passive = BlockingReadProbe()
    let authorization = ReadProbe()
    let speech = LocalSpeech(credentialRead: { _ = passive.read(); return nil },
                             credentialAuthorize: { authorization.read() })
    defer { passive.unblock(); speech.shutdown() }
    speech.select(.cloud)
    for await _ in passive.entered { break }
    for _ in 0..<20 { speech.authorizeCloudCredential() }
    #expect(authorization.observations.0 == 0)
    passive.unblock()
    for _ in 0..<100 where !speech.cloudCredentialReady {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(speech.cloudCredentialReady)
    #expect(passive.count == 1)
    #expect(authorization.observations.0 == 1)
}

@MainActor @Test func backendChangeClearsPendingCredentialAuthorization() async {
    let passive = BlockingReadProbe()
    let authorization = ReadProbe()
    let speech = LocalSpeech(credentialRead: { _ = passive.read(); return nil },
                             credentialAuthorize: { authorization.read() })
    defer { passive.unblock(); speech.shutdown() }
    speech.select(.cloud)
    for await _ in passive.entered { break }
    speech.authorizeCloudCredential()
    speech.select(.apple)
    passive.unblock()
    for _ in 0..<100 where speech.credentialReadPending {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(!speech.credentialReadPending)
    #expect(!speech.cloudCredentialReady)
    #expect(authorization.observations.0 == 0)
}

private final class StalledReadProbe: @unchecked Sendable {
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    func read() -> String? {
        lock.lock(); calls += 1; lock.unlock()
        _ = release.wait(timeout: .now() + 10)
        return "original-synthetic-credential"
    }
    func unblock() { release.signal() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
}

@MainActor @Test func stalledCredentialLookupReportsRecoveryWithoutStartingAnotherRead() async throws {
    let passive = StalledReadProbe()
    let authorization = ReadProbe()
    let speech = LocalSpeech(credentialRead: { passive.read() },
                             credentialAuthorize: { authorization.read() })
    defer { passive.unblock(); speech.shutdown() }
    speech.select(.cloud)
    try await Task.sleep(for: .seconds(5))
    // The watchdog's report arrives through a discovery task; allow it to run.
    for _ in 0..<200 where !speech.discovery.contains("not responding") {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(speech.discovery.contains("not responding"))
    #expect(speech.credentialReadPending)
    for _ in 0..<20 { speech.authorizeCloudCredential(); speech.select(.cloud) }
    #expect(passive.count == 1)
    #expect(authorization.observations.0 == 0)
    passive.unblock()
    for _ in 0..<100 where speech.credentialReadPending {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!speech.cloudCredentialReady)
    #expect(authorization.observations.0 == 0)
    speech.select(.apple)
    #expect(speech.backend == .apple)
}

@MainActor @Test func stalledInteractiveAuthorizationExpiresAndDiscardsItsLateCredential() async throws {
    let authorization = StalledReadProbe()
    let speech = LocalSpeech(credentialRead: { nil }, credentialAuthorize: { authorization.read() },
                             interactiveCredentialDeadline: .milliseconds(20))
    defer { authorization.unblock(); speech.shutdown() }
    speech.select(.cloud)
    for _ in 0..<100 where speech.credentialReadPending {
        try await Task.sleep(for: .milliseconds(10))
    }
    speech.authorizeCloudCredential()
    // The 20 ms watchdog is a task: under a busy test run it can take longer than any fixed sleep to run.
    for _ in 0..<200 where !speech.discovery.contains("not responding") {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(speech.discovery.contains("not responding"))
    #expect(speech.credentialReadPending)
    speech.authorizeCloudCredential()
    #expect(authorization.count == 1)
    speech.select(.apple)
    authorization.unblock()
    for _ in 0..<100 where speech.credentialReadPending {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!speech.credentialReadPending)
    #expect(!speech.cloudCredentialReady)
    #expect(speech.backend == .apple)
}

@Test func credentialPersistenceIsScopedAndPreservesAccessControls() {
    for provider in CloudCredentials.Provider.allCases {
        var adds = 0, updates = 0
        let result = CloudCredentials.persist("original-synthetic-key", provider: provider, add: { raw in
            let item = raw as NSDictionary
            #expect(item[kSecAttrService] as? String == (provider == .openRouter ? "au.com.mykoala.mercurius.openrouter" : "au.com.mykoala.mercurius.elevenlabs"))
            #expect(item[kSecAttrSynchronizable] as? Bool == false)
            #expect(item[kSecAttrAccess] == nil)
            adds += 1; return errSecDuplicateItem
        }, update: { raw, changes in
            let query = raw as NSDictionary, changes = changes as NSDictionary
            #expect(query[kSecAttrAccount] as? String == (provider == .openRouter ? "OpenRouter API key" : "ElevenLabs API key"))
            #expect(query[kSecValueData] == nil)
            #expect(changes.count == 1 && changes[kSecValueData] is Data)
            updates += 1; return errSecSuccess
        })
        #expect(result == errSecSuccess && adds == 1 && updates == 1)
    }
    var calls = 0
    #expect(CloudCredentials.persist("bad\nkey", provider: .openRouter, add: { _ in calls += 1; return errSecSuccess }, update: { _,_ in calls += 1; return errSecSuccess }) == errSecParam)
    #expect(calls == 0)
}

private final class CredentialWriteProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var writes: [(String, CloudCredentials.Provider)] = []
    private var onMain = false
    let release = DispatchSemaphore(value: 0)
    let result: OSStatus
    init(result: OSStatus = errSecSuccess) { self.result = result }
    func store(_ value: String, _ provider: CloudCredentials.Provider) -> OSStatus {
        lock.lock(); writes.append((value, provider)); onMain = onMain || Thread.isMainThread; lock.unlock()
        _ = release.wait(timeout: .now() + 2)
        return result
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return writes.count }
    var mainThreadUsed: Bool { lock.lock(); defer { lock.unlock() }; return onMain }
    var provider: CloudCredentials.Provider? { lock.lock(); defer { lock.unlock() }; return writes.last?.1 }
}

@MainActor @Test func credentialFormRequiresExplicitSaveAndCoalescesClicks() async throws {
    let probe = CredentialWriteProbe()
    let form = CredentialSetupWindow(store: { probe.store($0, $1) })
    defer { probe.release.signal(); form.panel.window.close() }
    #expect(form.key.stringValue.isEmpty && probe.count == 0)
    form.key.stringValue = "original-synthetic-key"
    #expect(probe.count == 0)
    form.saveButton.performClick(nil)
    #expect(form.key.stringValue.isEmpty)
    #expect(form.isSaving && !form.saveButton.isEnabled)
    #expect(form.closeButton.title.contains("save continues"))
    form.panel.window.close()
    #expect(form.isSaving && form.key.stringValue.isEmpty)
    for _ in 0..<20 { form.save() }
    for _ in 0..<100 where probe.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(probe.count == 1 && probe.provider == .openRouter && !probe.mainThreadUsed)
    probe.release.signal()
    for _ in 0..<100 where form.isSaving { try await Task.sleep(for: .milliseconds(5)) }
    #expect(!form.isSaving && form.status.stringValue.contains("have not been checked"))
    #expect(!form.status.stringValue.contains("original-synthetic-key"))
}

@MainActor @Test func credentialFormClearsOnProviderChangeAndCloseAndRejectsInvalidInput() async throws {
    let probe = CredentialWriteProbe(result: errSecAuthFailed)
    let form = CredentialSetupWindow(store: { probe.store($0, $1) })
    defer { probe.release.signal(); form.panel.window.close() }
    form.key.stringValue = "first-synthetic-key"
    form.provider.selectItem(at: 1); form.providerChanged()
    #expect(form.key.stringValue.isEmpty && probe.count == 0)
    form.key.stringValue = "bad key"; form.save()
    #expect(probe.count == 0 && form.key.stringValue.isEmpty)
    form.key.stringValue = "second-synthetic-key"; form.save()
    for _ in 0..<100 where probe.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(probe.provider == .elevenLabs)
    probe.release.signal()
    for _ in 0..<100 where form.isSaving { try await Task.sleep(for: .milliseconds(5)) }
    #expect(form.status.stringValue.contains("did not confirm"))
    form.key.stringValue = "third-synthetic-key"
    form.panel.window.close()
    #expect(form.key.stringValue.isEmpty)
}

@MainActor @Test func renderCredentialSetupForReview() throws {
    guard let directory = ProcessInfo.processInfo.environment["CURSUS_CREDENTIAL_RENDER"] else { return }
    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["CURSUS_RENDER_DARK"] == nil ? .aqua : .darkAqua)
    let form = CredentialSetupWindow(store: { _,_ in errSecNotAvailable })
    defer { form.panel.window.close() }
    let window = form.panel.window
    let view = try #require(window.contentView?.superview)
    window.contentView?.layoutSubtreeIfNeeded(); view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: image)
    try #require(image.representation(using: .png, properties: [:]))
        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("provider-setup.png"))
    #expect(form.key.accessibilityLabel() == "Existing provider API key")
    #expect(form.saveButton.accessibilityLabel() == "Save provider key to Keychain")
    #expect(form.key.frame.width > 300)
}

@MainActor @Test func slowKeychainSaveOffersRecoveryWithoutStartingAnotherWrite() async throws {
    let probe = CredentialWriteProbe()
    let form = CredentialSetupWindow(store: { probe.store($0, $1) }, waitNotice: .milliseconds(20))
    defer { probe.release.signal(); form.panel.window.close() }
    form.key.stringValue = "original-synthetic-key"; form.save()
    for _ in 0..<100 where !form.status.stringValue.contains("taking longer") { try await Task.sleep(for: .milliseconds(5)) }
    #expect(form.status.stringValue.contains("taking longer") && form.isSaving)
    for _ in 0..<20 { form.save() }
    #expect(probe.count == 1)
    probe.release.signal()
    for _ in 0..<100 where form.isSaving { try await Task.sleep(for: .milliseconds(5)) }
    #expect(!form.isSaving)
}


@MainActor @Test func credentialActionsClearAttachedSecureEditorsAndUndo() async throws {
    for action in 0..<3 {
        let probe = CredentialWriteProbe()
        let form = CredentialSetupWindow(store: { probe.store($0, $1) })
        defer { probe.release.signal(); form.panel.window.close() }
        let editor = try #require(form.panel.window.fieldEditor(true, for: form.key) as? NSTextView)
        #expect(form.panel.window.makeFirstResponder(form.key))
        #expect(form.key.currentEditor() === editor)
        editor.insertText("original-synthetic-key", replacementRange: NSRange(location: 0, length: 0))
        #expect(editor.string == "original-synthetic-key")
        // Secure AppKit editors may prohibit undo entirely. If present, exercise it before clearing.
        if editor.allowsUndo, let undo = editor.undoManager {
            undo.registerUndo(withTarget: editor) { $0.string = "original-synthetic-key" }
            #expect(undo.canUndo)
        }
        switch action {
        case 0: form.save()
        case 1: form.provider.selectItem(at: 1); form.providerChanged()
        default: form.panel.window.close()
        }
        #expect(form.key.stringValue.isEmpty)
        #expect(editor.string.isEmpty)
        #expect(editor.undoManager?.canUndo != true)
        probe.release.signal()
        for _ in 0..<100 where form.isSaving { try await Task.sleep(for: .milliseconds(5)) }
    }
}
