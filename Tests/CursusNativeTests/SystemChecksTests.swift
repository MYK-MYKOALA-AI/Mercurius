import Testing
@testable import CursusVox

@Test func globeKeyIsFreeOnlyWhenSetToDoNothing() {
    #expect(SystemChecks.globeKeyIsFree(0))
    // Unset means the macOS default, which acts on the key itself.
    #expect(!SystemChecks.globeKeyIsFree(nil))
    for value in [1, 2, 3] { #expect(!SystemChecks.globeKeyIsFree(value)) }
}
@Test func wisprFlowIsDetectedByItsBundleIdentifiers() {
    #expect(SystemChecks.wisprRunning(bundleIDs: ["com.apple.finder", "com.electron.wispr-flow"]))
    #expect(SystemChecks.wisprRunning(bundleIDs: ["com.electron.wispr-flow.accessibility-mac-app"]))
    #expect(!SystemChecks.wisprRunning(bundleIDs: ["com.apple.finder", nil, "com.electron.slack"]))
}
@Test func setupIsCompleteOnlyWithTheThreeRequiredGrants() {
    #expect(SystemChecks.requiredGranted(microphone: true, accessibility: true, inputMonitoring: true))
    #expect(!SystemChecks.requiredGranted(microphone: false, accessibility: true, inputMonitoring: true))
    #expect(!SystemChecks.requiredGranted(microphone: true, accessibility: false, inputMonitoring: true))
    #expect(!SystemChecks.requiredGranted(microphone: true, accessibility: true, inputMonitoring: false))
}
