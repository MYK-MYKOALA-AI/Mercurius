import AppKit
import Testing
import CursusCore
@testable import CursusVox

@MainActor @Suite(.serialized) struct PermissionPromptsTests {
    @Test func observingSetupDoesNotInvokeAnyPermissionAdapter() async {
        var requests: [PermissionSetup.Permission] = []
        let prompts = PermissionPrompts { requests.append($0); return .completed }
        await prompts.receive(.opened)
        await prompts.receive(.refreshed)
        #expect(requests.isEmpty)
        #expect(!prompts.isRequesting)
        for permission in PermissionSetup.Permission.allCases {
            await prompts.receive(.request(permission))
            #expect(requests.last == permission)
            #expect(!prompts.isRequesting)
        }
        #expect(requests == PermissionSetup.Permission.allCases)
    }

    @Test func pendingDialogBlocksRepeatedClicksAndCannotBeCompletedByAnExternalEvent() async throws {
        var requests: [PermissionSetup.Permission] = []
        var continuation: CheckedContinuation<Void, Never>?
        let prompts = PermissionPrompts {
            requests.append($0)
            await withCheckedContinuation { continuation = $0 }
            return .completed
        }
        var busy: [Bool] = []
        prompts.changed = { [weak prompts] in busy.append(prompts?.isRequesting == true) }
        let first = Task { await prompts.receive(.request(.microphone)) }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let response = try #require(continuation)
        #expect(prompts.isRequesting)
        await prompts.receive(.completed(.microphone))
        await prompts.receive(.resumed)
        await prompts.receive(.request(.speech))
        await prompts.receive(.request(.microphone))
        #expect(requests == [.microphone])
        #expect(prompts.isRequesting)
        // Even a cancelled OS request owns the gate until its callback returns.
        first.cancel()
        response.resume()
        await first.value
        #expect(!prompts.isRequesting)
        #expect(busy == [true, false])
        #expect(requests == [.microphone])
    }

    @Test func cancelledActionDoesNotPromptAndReleasesAdmission() async {
        var requests: [PermissionSetup.Permission] = []
        let prompts = PermissionPrompts { requests.append($0); return .completed }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await prompts.receive(.request(.microphone))
        }
        await task.value
        #expect(requests.isEmpty)
        #expect(!prompts.isRequesting)
        await prompts.receive(.request(.speech))
        #expect(requests == [.speech])
    }

    @Test func actualSetupButtonsRequestOnlyTheirNamedPermissionAndRefreshWithoutPrompts() async throws {
        _ = NSApplication.shared
        let view = Onboarding()
        var requests: [PermissionSetup.Permission] = []
        let prompts = PermissionPrompts { requests.append($0); return .completed }
        view.rows = {
            [.init(title: "Microphone", detail: "Needed to hear you", status: .todo, button: "Allow",
                   action: { Task { await prompts.receive(.request(.microphone)) } })]
        }
        view.refresh(force: true)
        func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
        let root = try #require(view.window.contentView)
        let button = try #require(descendants(root).compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "Allow Microphone" })
        #expect(requests.isEmpty)
        #expect(!descendants(root).compactMap { $0 as? NSButton }.contains { $0.title == "Allow everything" })
        button.performClick(nil)
        for _ in 0..<100 where requests.isEmpty { await Task.yield() }
        #expect(requests == [.microphone])
        view.refresh(force: true)
        #expect(requests == [.microphone])
        view.showDictationKey(fn: false)
        #expect(descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Hold Control+Option") })
        #expect(descendants(root).compactMap { $0 as? NSTextField }.contains { $0.placeholderString?.contains("Control+Option") == true })
        view.rows = { [.init(title: "Microphone", detail: "Waiting for macOS", status: .todo,
                            button: "Allow", action: {}, enabled: false)] }
        view.refresh(force: true)
        #expect(descendants(root).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Allow Microphone" }?.isEnabled == false)
    }

    @Test func returningFromAnAdapterDoesNotFinishAnExternalPermissionInteraction() async {
        var requests: [PermissionSetup.Permission] = []
        let prompts = PermissionPrompts { permission in
            requests.append(permission)
            return permission == .accessibility ? .settingsOpened : .completed
        }
        await prompts.receive(.request(.accessibility))
        #expect(prompts.isRequesting)
        #expect(prompts.awaitingSettings)
        await prompts.receive(.refreshed)
        await prompts.receive(.request(.microphone))
        await prompts.receive(.completed(.accessibility))
        #expect(requests == [.accessibility])
        #expect(prompts.isRequesting)
        await prompts.receive(.resumed)
        #expect(!prompts.isRequesting)
        #expect(!prompts.awaitingSettings)
        await prompts.receive(.request(.microphone))
        #expect(requests == [.accessibility, .microphone])
    }
}
