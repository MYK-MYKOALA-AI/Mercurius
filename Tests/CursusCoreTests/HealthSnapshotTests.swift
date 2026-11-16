import Foundation
import Testing
@testable import CursusCore
struct HealthSnapshotTests {
    @Test func staleProviderResultCannotReplaceNewCheck() {
        var checks = HealthChecks(); let now = Date(timeIntervalSince1970: 10)
        let old = checks.begin(.openRouter,now: now); let new = checks.begin(.openRouter,now: now)
        let stale = checks.complete(.openRouter,token: old,status: .ready,detail: "old",now: now)
        #expect(!stale)
        let fresh = checks.complete(.openRouter,token: new,status: .needsAttention,detail: "new",now: now)
        #expect(fresh)
        #expect(checks.row(.openRouter,now: now).status == .needsAttention)
        #expect(checks.row(.openRouter,now: now.addingTimeInterval(60)).status == .unknown)
    }
    @Test func exportedDiagnosticsExcludeAllFreeformDetails() {
        let row = HealthRow(id: .microphone,status: .ready,detail: "synthetic-secret and private transcript",checkedAt: Date())
        let snapshot = HealthSnapshot(build: "fixture",engine: .local,latestFailure: .recognitionFailed,rows: [row])
        #expect(snapshot.diagnostics.hasPrefix("Mercurius build: fixture\n"))
        #expect(!snapshot.diagnostics.contains("synthetic-secret")); #expect(!snapshot.diagnostics.contains("transcript"))
        #expect(snapshot.diagnostics.contains("microphone: ready")); #expect(snapshot.diagnostics.contains("recognitionFailed"))
    }
}

@Test func healthSeparatesCredentialsConnectivityMicrophoneAndTranscription() {
    var checks = HealthChecks()
    let at = Date(timeIntervalSince1970: 100)
    let token = checks.begin(.openRouter, now: at)
    checks.complete(.openRouter, token: token, status: .ready, detail: "Provider metadata available", now: at)
    #expect(checks.row(.openRouter, now: at).status == .ready)
    for id: HealthCheckID in [.credential, .microphoneCapture, .transcription] {
        #expect(checks.row(id, now: at).status == .unknown)
    }
    #expect(checks.row(.microphoneCapture, now: at).detail.contains("Test microphone"))
    #expect(checks.row(.transcription, now: at).detail.contains("Record explicitly"))
}
