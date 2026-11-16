import Foundation
import Testing
@testable import CursusCore
struct AppPresetTests {
    let global = RecoveryConfiguration(engine: .cloud,speechModel: "global-speech",cleanupModel: "global-clean",cleanupEnabled: true,smart: true)
    @Test func exactIdentityAndStrictPolicyWin() {
        let presets = [AppPreset(bundleID: "owned.App",engine: .local,speechModel: "chosen",style: .natural)]
        let chosen = AppPreset.resolve(bundleID: "owned.App",presets: presets,global: global,strictApps: [], literalApps: [])
        #expect(chosen.configuration.engine == .local); #expect(chosen.configuration.speechModel == "chosen")
        var inherited = global; inherited.writingStyle = "natural"
        #expect(AppPreset.resolve(bundleID: "owned.app",presets: presets,global: global,strictApps: [], literalApps: []).configuration == inherited)
        let strict = AppPreset.resolve(bundleID: "owned.App",presets: presets,global: global,strictApps: ["owned.App"], literalApps: [])
        #expect(strict.style == .strict); #expect(!strict.configuration.cleanupEnabled)
    }
    @Test func resolvedValueDoesNotChangeWithLaterPresetEdits() throws {
        var presets = [AppPreset(bundleID: "owned.App",cleanupModel: "chosen",style: .concise)]
        let snapshot = AppPreset.resolve(bundleID: "owned.App",presets: presets,global: global,strictApps: [], literalApps: [])
        presets[0].style = .natural; presets[0].cleanupModel = "other"
        #expect(snapshot.style == .concise); #expect(snapshot.configuration.cleanupModel == "chosen")
        #expect(!snapshot.configuration.smart); #expect(snapshot.cleanupOverride)
        #expect(try JSONDecoder().decode([AppPreset].self,from: JSONEncoder().encode(presets)) == presets)
    }
}

@Test func styleOverrideDoesNotEnableGloballyDisabledCleanup() {
    let global = RecoveryConfiguration(engine: .local, speechModel: "local", cleanupEnabled: false)
    for style in AppPreset.Style.allCases {
        let result = AppPreset.resolve(bundleID: "owned.App", presets: [.init(bundleID: "owned.App", style: style)], global: global, strictApps: [], literalApps: [])
        #expect(!result.configuration.cleanupEnabled)
    }
}
