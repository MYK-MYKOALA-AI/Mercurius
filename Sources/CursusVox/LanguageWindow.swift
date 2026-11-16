import AppKit
import CursusCore
import Speech

// Which languages on-device speech uses. Nothing downloads until someone chooses a language here.
@MainActor enum SpeechLanguageStore {
    private static var defaults: UserDefaults { .standard }
    static var choice: SpeechLanguageChoice {
        get { SpeechLanguageChoice(chosen: defaults.stringArray(forKey: "speechLanguages") ?? [], active: defaults.string(forKey: "speechLanguage")) }
        set {
            defaults.set(newValue.chosen, forKey: "speechLanguages")
            if let active = newValue.active { defaults.set(active, forKey: "speechLanguage") } else { defaults.removeObject(forKey: "speechLanguage") }
        }
    }
    static var preferred: [String] {
        let region = Locale.current.language.languageCode.flatMap { code in
            Locale.current.region.map { "\(code.identifier)_\($0.identifier)" }
        }
        return [region].compactMap { $0 } + Locale.preferredLanguages
    }
    // A chosen language is the only one used, so audio is never recognised in another language.
    static var recognitionOrder: [String] {
        choice.active.map { [$0] } ?? SpeechLanguageChoice.lookupOrder(active: nil, preferred: preferred)
    }
    static func locale() async -> Locale? {
        var supported: [Locale] = []
        for id in recognitionOrder {
            if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) { supported.append(locale) }
        }
        // Nothing chosen yet: keep using a language already ready on this Mac before one that isn't.
        if choice.active == nil {
            for locale in supported where await AssetInventory.status(forModules: [SpeechTranscriber(locale: locale, preset: .transcription)]) == .installed {
                return locale
            }
        }
        return supported.first
    }
    static func name(_ id: String) -> String { Locale.current.localizedString(forIdentifier: id) ?? id }

    // Asks Apple for a chosen language. A language already on this Mac becomes usable with no download.
    static func install(_ id: String, progress: @escaping @MainActor (Double) -> Void = { _ in }) async throws {
        let module = SpeechTranscriber(locale: Locale(identifier: id), preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            let watcher = Task { @MainActor in
                while !Task.isCancelled {
                    progress(request.progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            defer { watcher.cancel() }
            try await request.downloadAndInstall()
        }
        // No request also means nothing to fetch, so ask Apple whether it's really ready.
        guard await AssetInventory.status(forModules: [module]) == .installed else { throw CocoaError(.featureUnsupported) }
    }
    // After launch, so a language chosen earlier is ready again. Does nothing if none were chosen.
    static func prepareChosen() async {
        for id in choice.chosen { try? await install(id) }
    }
}

@MainActor final class LanguageWindow {
    private let panel = FeatureWindow(title: "Speech languages")
    private var pending = SpeechLanguageChoice()
    private var boxes: [String: NSButton] = [:]
    private let active = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var working = false
    var changed: (() -> Void)?

    func show() {
        panel.show()
        // Rebuilding mid-install would reset the choice being installed.
        guard !working else { return }
        Task { await build() }
    }
    private func build() async {
        panel.clear(); boxes = [:]
        panel.text("Which languages do you speak? Only the ones you tick are installed. They run on this Mac, and you can change them any time.")
        let supported = await SpeechTranscriber.supportedLocales.map(\.identifier)
        guard !supported.isEmpty else { panel.text("On-device speech isn't available on this Mac."); return }
        pending = SpeechLanguageStore.choice
        if pending.chosen.isEmpty, let suggested = SpeechLanguageChoice.suggested(preferred: SpeechLanguageStore.preferred, supported: supported) {
            pending.toggle(suggested)
        }
        let order = supported.sorted { a, b in
            let ta = pending.chosen.contains(a), tb = pending.chosen.contains(b)
            return ta != tb ? ta : SpeechLanguageStore.name(a).localizedCaseInsensitiveCompare(SpeechLanguageStore.name(b)) == .orderedAscending
        }
        panel.button("Install and use") { [weak self] in Task { await self?.apply() } }
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        panel.stack.addArrangedSubview(status)
        let speak = NSStackView(views: [NSTextField(labelWithString: "Dictate in"), active]); speak.orientation = .horizontal
        active.target = self; active.action = #selector(activeChanged); active.setAccessibilityLabel("Language to dictate in")
        panel.stack.addArrangedSubview(speak)
        for id in order {
            let box = NSButton(checkboxWithTitle: SpeechLanguageStore.name(id), target: self, action: #selector(toggled(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(id)
            box.state = pending.chosen.contains(id) ? .on : .off
            boxes[id] = box; panel.stack.addArrangedSubview(box)
        }
        refresh()
    }
    private func refresh() {
        active.removeAllItems()
        for id in pending.chosen {
            active.addItem(withTitle: SpeechLanguageStore.name(id)); active.lastItem?.representedObject = id
        }
        if let current = pending.active, let index = pending.chosen.firstIndex(of: current) { active.selectItem(at: index) }
        let full = pending.chosen.count >= SpeechLanguageChoice.limit
        for (id, box) in boxes { box.isEnabled = !working && (!full || pending.chosen.contains(id)) }
        active.isEnabled = !working && pending.chosen.count > 1
        if !working {
            status.stringValue = full ? "That's the limit of \(SpeechLanguageChoice.limit) languages." : pending.chosen.isEmpty ? "Tick at least one language." : ""
        }
    }
    @objc private func toggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        pending.toggle(id); refresh()
    }
    @objc private func activeChanged() {
        if let id = active.selectedItem?.representedObject as? String { pending.activate(id) }
    }
    private func apply() async {
        guard !working, !pending.chosen.isEmpty else { return }
        working = true; refresh()
        let target = pending
        let removed = SpeechLanguageStore.choice.chosen.filter { !target.chosen.contains($0) }
        var failed: [String] = []
        for id in target.chosen {
            let name = SpeechLanguageStore.name(id)
            status.stringValue = "Getting \(name) ready…"
            do {
                try await SpeechLanguageStore.install(id) { [weak self] fraction in
                    self?.status.stringValue = "Getting \(name) ready, about \(Int(fraction * 100))%"
                }
            } catch { failed.append(name) }
        }
        // The result is set after refresh(), which would otherwise wipe it.
        guard failed.isEmpty else {
            working = false; refresh()
            status.stringValue = "Couldn't install \(failed.joined(separator: ", ")). Check your connection and try again."
            return
        }
        for id in removed { _ = await AssetInventory.release(reservedLocale: Locale(identifier: id)) }
        SpeechLanguageStore.choice = target
        changed?()
        working = false; refresh()
        status.stringValue = "Ready."
    }
}
