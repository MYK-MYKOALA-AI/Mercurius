import Testing
import ApplicationServices
import Foundation
@testable import CursusVox

@MainActor @Test(arguments: [
    "https://docs.google.com/document/d/synthetic-document-00000001/edit",
    "https://docs.google.com/spreadsheets/d/synthetic-sheet-000000001/edit#gid=7",
    "https://docs.google.com/presentation/d/synthetic-slides-00000001/edit"
]) func emptyCanvasPreservesAXURLForDocumentExport(address: String) throws {
    let node = AXUIElementCreateApplication(1)
    let attribute: (AXUIElement, String) -> ScreenText.Attribute = { _, name in
        switch name {
        case "AXRole": return .init(value: "AXWebArea", status: .success)
        case "AXURL": return .init(value: address, status: .success)
        case "AXChildren": return .init(value: [AXUIElement](), status: .success)
        default: return .init(value: nil, status: .attributeUnsupported)
        }
    }
    let windowDocument = attribute(node, "AXDocument").value as? String
    #expect(windowDocument == nil && GoogleDocs.export(for: windowDocument) == nil)
    var walker = ScreenReader.Walker(deadline: Date().addingTimeInterval(1),
                                     readAttribute: attribute, secureInput: { false })
    walker.walk(node)
    let canvas = ScreenText.Capture(title: "Canvas", url: attribute(node, "AXURL").value as? String,
                                    blocks: walker.blocks, partial: walker.partial, readFailed: walker.readFailed)
    #expect(canvas.words == 0)
    // Fn+T must reach its URL-based export fallback before rejecting missing accessible words.
    let seen = try ScreenText.result(from: canvas, cancelled: false).get()
    #expect(seen.url == address)
    #expect(GoogleDocs.export(for: seen.url) != nil)
    #expect(seen.textProblem == .empty)
}

@MainActor @Test func emptyCaptureKeepsSpecificFailureAfterFallbacks() throws {
    let url = "https://example.test/empty"
    for (partial, readFailed, problem) in [(false, false, ScreenText.Problem.empty),
                                          (true, false, .timedOut), (true, true, .readFailed)] {
        let capture = ScreenText.Capture(title: "Empty", url: url, blocks: [], partial: partial, readFailed: readFailed)
        let seen = try ScreenText.result(from: capture, cancelled: false).get()
        #expect(seen.url == url && GoogleDocs.export(for: seen.url) == nil)
        #expect(seen.textProblem == problem)
    }
}

@MainActor @Test func cancelledOrChangedCanvasCannotReachExportFallback() {
    let canvas = ScreenText.Capture(title: "Canvas", url: "https://docs.google.com/document/d/synthetic-document-00000001/edit", blocks: [])
    for (capture, cancelled, problem) in [(Optional(canvas), true, ScreenText.Problem.cancelled),
                                          (nil, false, .changedOrigin), (nil, true, .cancelled)] {
        guard case let .failure(actual) = ScreenText.result(from: capture, cancelled: cancelled) else {
            Issue.record("Invalid capture retained export metadata"); continue
        }
        #expect(actual == problem)
    }
}

@MainActor @Test func desktopContainersRetainContentAndExcludeSecureSubtrees() {
    let nodes = (1...7).map { AXUIElementCreateApplication(pid_t($0)) }
    let roles = ["AXWindow", "AXTabGroup", "AXSplitter", "AXHeading", "AXStaticText", "AXSecureTextField", "AXStaticText"]
    let children = [[1], [2,5], [3], [4], [], [6], []]
    var walker = ScreenReader.Walker(deadline: Date().addingTimeInterval(1), readAttribute: { element, name in
        let index = nodes.firstIndex { CFEqual($0, element) }!
        switch name {
        case "AXRole": return .init(value: roles[index], status: .success)
        case "AXChildren": return .init(value: children[index].map { nodes[$0] }, status: .success)
        case "AXValue": return .init(value: index == 4 ? "Visible desktop content" : "PRIVATE", status: .success)
        default: return .init(value: nil, status: .attributeUnsupported)
        }
    }, secureInput: { false })
    walker.walk(nodes[0])
    #expect(walker.blocks == [.heading("Visible desktop content")])
    #expect(!walker.partial)
}

@MainActor @Test func inaccessibleTextIsNotReportedAsAnEmptyWindow() {
    let node = AXUIElementCreateApplication(1)
    var walker = ScreenReader.Walker(deadline: Date().addingTimeInterval(1), readAttribute: { _, name in
        .init(value: name == "AXRole" ? "AXTextArea" : nil, status: name == "AXRole" ? .success : .cannotComplete)
    }, secureInput: { false })
    walker.walk(node)
    #expect(walker.blocks.isEmpty && walker.partial && walker.readFailed)
    #expect(ScreenText.Problem.readFailed.message != ScreenText.Problem.empty.message)
}

@MainActor @Test func interruptedCaptureCannotCommitAfterAnAwaitedOriginIsRestored() async {
    let began = AsyncStream<Void>.makeStream()
    var release: CheckedContinuation<Bool, Never>?
    let permit = EffectPermit(expiresAt: ProcessInfo.processInfo.systemUptime + 10)
    var retained = 0, copied = 0
    let work = Task {
        let admitted = await CaptureExecution.allows(permit, secureInput: { false }) {
            // A checked continuation deliberately ignores task cancellation until the adapter replies.
            await withCheckedContinuation { continuation in
                release = continuation; began.continuation.yield(())
            }
        }
        if admitted { retained += 1; copied += 1 }
    }
    for await _ in began.stream { break }
    CaptureExecution.interrupt(work, permit: permit)
    release?.resume(returning: true)
    await work.value
    #expect(retained == 0 && copied == 0 && !permit.valid)
}
