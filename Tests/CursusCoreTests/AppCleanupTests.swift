import Testing
import CursusCore

@Test func strictAppsOverrideOnlyTheGlobalDefault() {
    let apps: Set<String> = ["com.apple.Terminal", "com.t3tools.t3code"]
    for id in apps { #expect(AppCleanup.style(bundleID: id, strictApps: apps, defaultSmart: true) == .strict) }
    #expect(AppCleanup.style(bundleID: "com.tinyspeck.slackmacgap", strictApps: apps, defaultSmart: true) == .smart)
    #expect(AppCleanup.style(bundleID: "com.tinyspeck.slackmacgap", strictApps: apps, defaultSmart: false) == .strict)
    for id in [nil, "", "unknown"] as [String?] {
        #expect(AppCleanup.style(bundleID: id, strictApps: apps, defaultSmart: true) == .smart)
        #expect(AppCleanup.style(bundleID: id, strictApps: apps, defaultSmart: false) == .strict)
    }
    #expect(AppCleanup.style(bundleID: "com.apple.Terminal", strictApps: [], defaultSmart: true) == .smart)
}

@Test func strictAppsParserDropsInvalidLinesAndBoundsSavedInput() {
    #expect(AppCleanup.parseApps("\n com.apple.Terminal \ncom.apple.Terminal\ninvalid id\ncom.t3tools.t3code\nwrong/id\né.app")
        == ["com.apple.Terminal", "com.t3tools.t3code"])
    #expect(AppCleanup.parseApps("").isEmpty)
    #expect(AppCleanup.parseApps(String(repeating: "a", count: 256)).isEmpty)
    #expect(AppCleanup.parseApps((0..<110).map { "com.fixture.\($0)" }.joined(separator: "\n")).count == 100)
}
