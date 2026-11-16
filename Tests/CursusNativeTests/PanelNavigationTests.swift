import AppKit
import Testing
@testable import CursusVox

@MainActor @Suite(.serialized) struct PanelNavigationTests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func root(_ panel: HomePanel) throws -> NSView { try #require(panel.popover.contentViewController?.view) }
    private func segment(_ name: String, in view: NSView) throws -> NSSegmentedControl {
        try #require(descendants(view).compactMap { $0 as? NSSegmentedControl }.first { $0.accessibilityLabel() == name })
    }
    private func choose(_ index: Int, _ control: NSSegmentedControl) {
        control.selectedSegment = index
        _ = control.sendAction(control.action, to: control.target)
    }
    private func button(_ name: String, in view: NSView) throws -> NSButton {
        try #require(descendants(view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == name || $0.title == name })
    }

    @Test func primaryNavigationHasThreeTabsAndDictionaryRemainsInSettings() throws {
        let panel = HomePanel(), view = try root(panel)
        let navigation = try segment("Main navigation", in: view)
        #expect(navigation.segmentCount == 3)
        #expect((0..<3).map { navigation.label(forSegment: $0) } == ["Activity", "Clipboard", "Settings"])
        panel.select(.dictionary)
        #expect(navigation.selectedSegment == 2)
        #expect(try button("Back to Settings", in: view).isHiddenOrHasHiddenAncestor == false)
        panel.select(.settings)
        var opened = 0
        panel.manageCredentials = { opened += 1 }
        #expect(opened == 0)
        try button("Provider keys…", in: view).performClick(nil)
        #expect(opened == 1)
    }

    @Test func captureHelpTracksTheSelectedBinding() throws {
        let panel = HomePanel(), view = try root(panel)
        panel.showDictationKey(fn: false); panel.select(.settings)
        #expect(panel.emptyTitle.stringValue == "Hold Control + Option and talk")
        choose(1, try segment("Settings category", in: view))
        let lines = descendants(view).compactMap { $0 as? NSTextField }.filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue)
        #expect(lines.contains { $0.contains("Control + Option + T") && !$0.contains("Control + Option + W") })
        #expect(!lines.contains { $0.contains("fn + W") || $0.contains("fn + T") })
        panel.showDictationKey(fn: true)
        #expect(panel.screenText.accessibilityHelp()?.contains("Fn + T") == true)
    }

    @Test func popoverContentKeepsANonVibrantOpaqueAppearance() throws {
        let panel = HomePanel(), surface = try root(panel)
        let material = NSVisualEffectView()
        material.material = .popover; material.state = .active
        material.appearance = NSAppearance(named: .vibrantDark)
        material.addSubview(surface)
        #expect(panel.popover.contentSize == HomePanel.size)
        #expect(surface.frame.size == HomePanel.size)
        #expect(surface.isOpaque)
        #expect(!surface.allowsVibrancy)
        #expect(surface.appearance?.allowsVibrancy == false)
        #expect(surface.effectiveAppearance.name != .vibrantDark)
        var foreground: NSColor?, background: NSColor?
        surface.effectiveAppearance.performAsCurrentDrawingAppearance {
            foreground = NSColor.labelColor.usingColorSpace(.sRGB)
            background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)
        }
        func luminance(_ color: NSColor) -> Double {
            func linear(_ value: CGFloat) -> Double {
                let x = Double(value); return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
        }
        let a = luminance(try #require(foreground)), b = luminance(try #require(background))
        #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5)
    }

    @Test func panelTracksApplicationAppearanceChanges() async throws {
        let app = NSApplication.shared
        let previous = app.appearance
        defer { app.appearance = previous }
        app.appearance = NSAppearance(named: .aqua)
        let surface = PanelSurface(content: NSView())
        #expect(surface.effectiveAppearance.name == .aqua)
        app.appearance = NSAppearance(named: .darkAqua)
        await Task.yield()
        #expect(surface.effectiveAppearance.name == .darkAqua)
        app.appearance = NSAppearance(named: .aqua)
        await Task.yield()
        #expect(surface.effectiveAppearance.name == .aqua)
    }

    @Test func panelMarginsLeaveFourHundredPointsForNavigation() throws {
        let panel = HomePanel(), surface = try root(panel)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: HomePanel.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = surface
        surface.layoutSubtreeIfNeeded()
        let navigation = try segment("Main navigation", in: surface)
        let frame = navigation.convert(navigation.bounds, to: surface)
        #expect(abs(frame.minX - 16) < 0.5)
        #expect(abs(frame.width - 400) < 0.5)
        #expect(abs(surface.bounds.width - frame.maxX - 16) < 0.5)
    }

    @Test func retentionAndCleanupMeaningRemainAccessible() throws {
        let panel = HomePanel(), view = try root(panel)
        let notice = try #require(descendants(view).compactMap { $0 as? NSTextField }.first {
            $0.stringValue == "Dictation text clears after 10 minutes or when you quit."
        })
        #expect(!notice.isHiddenOrHasHiddenAncestor)
        panel.select(.settings); panel.refreshPrices()
        #expect(panel.cleanupStyle.accessibilityHelp()?.isEmpty == false)
        choose(1, try segment("Main navigation", in: view))
        #expect(try segment("Clipboard item kind", in: view).segmentCount == 4)
        #expect(descendants(view).compactMap { $0 as? NSTextField }.contains {
            $0.stringValue.contains("Unsaved clips: 48 h unless Pin") && !$0.isHiddenOrHasHiddenAncestor
        })
    }

    @Test func clipboardNavigationSearchAndCopyUseTheFilteredItem() throws {
        let panel = HomePanel(), view = try root(panel)
        let first = ClipboardStore.Item(id: UUID(), kind: .capture, title: "Release checklist", source: "Notes", at: Date(), bytes: 20)
        let second = ClipboardStore.Item(id: UUID(), kind: .capture, title: "Shopping", source: "Safari", at: Date(), bytes: 15)
        panel.clipboardItems = { [first, second] }
        var copied: UUID?
        panel.clipboardAction = { action, item in if action == .copy { copied = item.id }; return nil }
        choose(1, try segment("Main navigation", in: view))
        let search = try #require(descendants(view).compactMap { $0 as? NSSearchField }.first)
        search.stringValue = "Notes"
        _ = search.sendAction(search.action, to: search.target)
        let labels = descendants(view).compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(labels.contains(first.title))
        #expect(!labels.contains(second.title))
        try button("Copy", in: view).performClick(nil)
        #expect(copied == first.id)
        search.stringValue = "Does not exist"
        _ = search.sendAction(search.action, to: search.target)
        #expect(descendants(view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "No matches" && !$0.isHiddenOrHasHiddenAncestor })
        search.stringValue = ""
        _ = search.sendAction(search.action, to: search.target)
        #expect(descendants(view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == second.title })
    }

    @Test func settingsVocabularyReturnsToGeneralAndKeepsPrimaryNavigation() throws {
        let panel = HomePanel(), view = try root(panel)
        choose(2, try segment("Main navigation", in: view))
        let categories = try segment("Settings category", in: view)
        choose(2, categories)
        let dictionary = try #require(descendants(view).compactMap { $0 as? NavRow }.first { $0.accessibilityLabel() == "Dictionary" })
        #expect(dictionary.accessibilityPerformPress())
        try button("Back to Settings", in: view).performClick(nil)
        #expect(categories.selectedSegment == 2)
        #expect(!dictionary.isHiddenOrHasHiddenAncestor)
        #expect(try segment("Main navigation", in: view).selectedSegment == 2)
    }

    @Test func oneDailySummaryKeepsHistoricalBilledModelsInItsDisclosure() throws {
        let panel = HomePanel(), view = try root(panel)
        panel.todaysCosts = { ("Today $0.008 · 123 words spoken", "gpt-oss-120b $0.008") }
        panel.refreshCosts()
        func visible(_ text: String) -> [NSTextField] {
            descendants(view).compactMap { $0 as? NSTextField }.filter { !$0.isHiddenOrHasHiddenAncestor && $0.stringValue.contains(text) }
        }
        #expect(visible("Today $0.008").count == 1)
        #expect(visible("gpt-oss-120b").isEmpty)
        try button("Daily usage details", in: view).performClick(nil)
        #expect(visible("gpt-oss-120b").count == 1)
        choose(2, try segment("Main navigation", in: view))
        #expect(visible("Today $0.008").count == 1)
    }

    @Test func dictationDetailsRevealActualChargesAndCopyTheCompleteText() throws {
        let panel = HomePanel(), view = try root(panel)
        let text = String(repeating: "Words spoken. ", count: 50)
        panel.update(history: [.init(text: text, at: Date(), raw: "Original words", detail: "On-device · 0.5 s", costs: "gpt-oss-120b $0.00017")])
        let charge = try #require(descendants(view).compactMap { $0 as? NSTextField }.first { $0.stringValue.contains("Reported usage") })
        #expect(charge.isHiddenOrHasHiddenAncestor)
        try button("Details", in: view).performClick(nil)
        #expect(!charge.isHiddenOrHasHiddenAncestor)
        #expect(charge.stringValue.contains("gpt-oss-120b $0.00017"))
        var copied: String?
        panel.copy = { copied = $0 }
        try button("Copy latest dictation", in: view).performClick(nil)
        #expect(copied == text)
        panel.update(history: [])
        #expect(charge.stringValue.isEmpty)
        #expect(charge.isHiddenOrHasHiddenAncestor)
    }

    @Test func earlierDetailsAndCopyKeepTheirOwnTranscriptIdentity() throws {
        let panel = HomePanel(), view = try root(panel)
        let earlier = HistoryEntry(text: "Earlier synthetic transcript", at: Date(), raw: "Original earlier words")
        let latest = HistoryEntry(text: "Latest synthetic transcript", at: Date())
        var selected: HistoryEntry?, copied: HistoryEntry?
        panel.showEntry = { selected = $0 }; panel.copyEntry = { copied = $0 }
        panel.update(history: [earlier, latest])
        try button("Details for earlier dictation", in: view).performClick(nil)
        #expect(selected == earlier); #expect(copied == nil)
        try button("Copy latest dictation", in: view).performClick(nil)
        #expect(copied == latest)
    }

    @Test func deliveryMetadataUpdatesKeepTheSameTranscriptDetailsOpen() throws {
        let panel = HomePanel(), view = try root(panel)
        var entry = HistoryEntry(text: "Synthetic transcript", at: Date(), raw: "Original synthetic transcript", costs: "fixture $0.01")
        panel.update(history: [entry])
        try button("Details", in: view).performClick(nil)
        let charge = try #require(descendants(view).compactMap { $0 as? NSTextField }.first { $0.stringValue.contains("Reported usage") })
        #expect(!charge.isHiddenOrHasHiddenAncestor)
        entry.outcomes = [.copied]
        panel.update(history: [entry])
        #expect(!charge.isHiddenOrHasHiddenAncestor)
        #expect(descendants(view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Copied to clipboard") })
    }
}
