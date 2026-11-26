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

// A clip is named after the page, not the browser window's title bar
// ("… - YouTube - Audio playing - Comet" became the note's title and file name).
@Test func clipTitleDropsBrowserAndTabStateSuffixes() {
    func title(_ window: String, url: String?, app: String?) -> String {
        ScreenText.Capture(title: window, url: url, blocks: [.line("words")]).note(site: app).title
    }
    #expect(title("[1hr Talk] Intro to Large Language Models - YouTube - Audio playing - Comet",
                  url: "https://www.youtube.com/watch?v=zjkBMFhNj_g", app: "Comet") == "[1hr Talk] Intro to Large Language Models")
    #expect(title("Mercury (mythology) - Wikipedia - Comet", url: "https://en.wikipedia.org/wiki/Mercury_(mythology)",
                  app: "Comet") == "Mercury (mythology) - Wikipedia")
    #expect(title("Pricing - Audio muted - Google Chrome", url: "https://example.com", app: "Google Chrome") == "Pricing")
    #expect(title("Shopping List", url: nil, app: "Notes") == "Shopping List")
    // Only the trailing " - YouTube" is the site's; a title may contain the words itself.
    #expect(title("Best of 2026 - YouTube Rewind - YouTube - Comet", url: "https://youtu.be/zjkBMFhNj_g",
                  app: "Comet") == "Best of 2026 - YouTube Rewind")
    // An app name alone is not stripped down to nothing.
    #expect(title("Comet", url: nil, app: "Comet") == "Comet")
}

// A page clip starts at the page's content. Seen on the real AX trees of YouTube, Perplexity and
// Wikipedia in Comet: banner ("AU", "Sign in"), search, navigation and complementary (sidebar) landmarks
// sit around one main landmark, and the clip used to open with them.
@MainActor private func pageWalk(_ roles: [String], subroles: [String?], children: [[Int]], texts: [Int: String],
                                 page: Bool = true) -> [ScreenText.Block] {
    let nodes = roles.indices.map { AXUIElementCreateApplication(pid_t($0 + 1)) }
    var walker = ScreenReader.Walker(deadline: Date().addingTimeInterval(1), readAttribute: { element, name in
        let index = nodes.firstIndex { CFEqual($0, element) }!
        switch name {
        case "AXRole": return .init(value: roles[index], status: .success)
        case "AXSubrole": return .init(value: subroles[index], status: subroles[index] == nil ? .noValue : .success)
        case "AXChildren": return .init(value: children[index].map { nodes[$0] }, status: .success)
        case "AXValue": return .init(value: texts[index], status: texts[index] == nil ? .noValue : .success)
        default: return .init(value: nil, status: .attributeUnsupported)
        }
    }, secureInput: { false })
    if page { walker.walkPage(nodes[0]) } else { walker.walk(nodes[0]) }
    return walker.blocks
}

@MainActor @Test func pageClipReadsTheMainLandmarkWithoutItsSidebars() {
    let long = Array(repeating: "word", count: 30).joined(separator: " ")
    //  0 web: 1 banner(2 "Sign in"), 3 nav(4 "Home Library"), 5 main(6 heading(7 "Title"), 8 body, 9 aside(10 "Related"))
    let blocks = pageWalk(["AXWebArea", "AXGroup", "AXStaticText", "AXGroup", "AXStaticText", "AXGroup", "AXHeading",
                           "AXStaticText", "AXStaticText", "AXGroup", "AXStaticText"],
                          subroles: [nil, "AXLandmarkBanner", nil, "AXLandmarkNavigation", nil, "AXLandmarkMain", nil, nil, nil,
                                     "AXLandmarkComplementary", nil],
                          children: [[1, 3, 5], [2], [], [4], [], [6, 8, 9], [7], [], [], [10], []],
                          texts: [2: "Sign in", 4: "Home Library", 7: "Title", 8: long, 10: "Related"])
    #expect(blocks == [.heading("Title"), .line(long)])
}

@MainActor @Test func pageWithoutAMainLandmarkStillSkipsNavigation() {
    let long = Array(repeating: "word", count: 30).joined(separator: " ")
    let blocks = pageWalk(["AXWebArea", "AXGroup", "AXStaticText", "AXGroup", "AXStaticText"],
                          subroles: [nil, "AXLandmarkNavigation", nil, nil, nil],
                          children: [[1, 3], [2], [], [4], []], texts: [2: "New Automations Artifacts", 4: long])
    #expect(blocks == [.line(long)])
}

@MainActor @Test func nearlyEmptyMainFallsBackToTheWholePage() {
    let long = Array(repeating: "word", count: 30).joined(separator: " ")
    // A page whose main landmark holds only a loading label keeps the rest of its readable content.
    let blocks = pageWalk(["AXWebArea", "AXGroup", "AXStaticText", "AXGroup", "AXStaticText"],
                          subroles: [nil, "AXLandmarkMain", nil, nil, nil],
                          children: [[1, 3], [2], [], [4], []], texts: [2: "Loading", 4: long])
    #expect(blocks == [.line("Loading"), .line(long)])
}

// On a big page with no main landmark, the search for one must leave time to read the page.
@MainActor @Test func mainLandmarkSearchLeavesTimeForTheWholePage() {
    let count = 3000
    let nodes = (0...count).map { AXUIElementCreateApplication(pid_t($0 + 1)) }
    var walker = ScreenReader.Walker(deadline: Date().addingTimeInterval(1), readAttribute: { element, name in
        usleep(500)  // a slow page: half a millisecond per Accessibility read
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let index = Int(pid) - 1
        switch name {
        case "AXRole": return .init(value: index == 0 ? "AXWebArea" : "AXStaticText", status: .success)
        case "AXChildren": return .init(value: index == 0 ? Array(nodes.dropFirst()) : [], status: .success)
        case "AXValue": return .init(value: "line \(index)", status: .success)
        default: return .init(value: nil, status: .noValue)
        }
    }, secureInput: { false })
    walker.walkPage(nodes[0])
    #expect(!walker.blocks.isEmpty)
}

// A node that fails to read while looking for main doesn't mark a clean main clip partial.
@MainActor @Test func aReadErrorWhileFindingMainIsNotAPartialClip() {
    let long = Array(repeating: "word", count: 30).joined(separator: " ")
    // 0 web: 1 flaky ad group, 2 main(3 text)
    let nodes = (0..<4).map { AXUIElementCreateApplication(pid_t($0 + 1)) }
    var walker = ScreenReader.Walker(deadline: Date().addingTimeInterval(1), readAttribute: { element, name in
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let index = Int(pid) - 1
        switch (index, name) {
        case (1, _): return .init(value: nil, status: .cannotComplete)
        case (_, "AXRole"): return .init(value: ["AXWebArea", "AXGroup", "AXGroup", "AXStaticText"][index], status: .success)
        case (2, "AXSubrole"): return .init(value: "AXLandmarkMain", status: .success)
        case (0, "AXChildren"): return .init(value: [nodes[1], nodes[2]], status: .success)
        case (2, "AXChildren"): return .init(value: [nodes[3]], status: .success)
        case (3, "AXValue"): return .init(value: long, status: .success)
        default: return .init(value: nil, status: .noValue)
        }
    }, secureInput: { false })
    walker.walkPage(nodes[0])
    #expect(walker.blocks == [.line(long)])
    #expect(!walker.partial && !walker.readFailed)
}
