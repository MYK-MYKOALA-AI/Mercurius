import Foundation
import Testing
import CursusCore
@testable import CursusVox

// Which windows a clip may read. Deliberately not the paste exclusion list: Finder refuses a paste
// because Cmd-V acts on files there, but its window holds only file names, so a window clip must
// still read it (2026-11-01).
@Suite struct CaptureTargetTests {
    @Test func findersWindowIsReadableEvenThoughFinderNeverReceivesAPaste() {
        #expect(NativeTargets.classifyAppLevel(bundleID: "com.apple.finder", name: "Finder") == .custom)
        #expect(NativeTargets.classifyCapture(bundleID: "com.apple.finder", name: "Finder") == .normal)
    }
    @Test func credentialAndSystemChromeWindowsAreNeverRead() {
        for bundle in ["com.apple.loginwindow", "com.apple.dock", "com.apple.systemuiserver"] {
            #expect(NativeTargets.classifyCapture(bundleID: bundle, name: nil) == .custom)
        }
    }
    @Test func remoteDesktopsAndUnknownProcessesAreNeverRead() {
        #expect(NativeTargets.classifyCapture(bundleID: "com.apple.ScreenSharing", name: "Screen Sharing") == .remote)
        #expect(NativeTargets.classifyCapture(bundleID: "com.realvnc.vncviewer", name: nil) == .remote)
        #expect(NativeTargets.classifyCapture(bundleID: nil, name: "Some App") == .unknown)
        #expect(NativeTargets.classifyCapture(bundleID: "", name: nil) == .unknown)
    }
    @Test func ordinaryAppsIncludingTextEditorsAndTerminalsAreReadable() {
        for (bundle, name) in [("com.apple.TextEdit", "TextEdit"), ("com.apple.Notes", "Notes"),
                               ("com.t3tools.t3code", "T3 Code"), ("com.apple.Terminal", "Terminal"),
                               ("ai.perplexity.comet", "Comet")] {
            #expect(NativeTargets.classifyCapture(bundleID: bundle, name: name) == .normal)
        }
    }
}
