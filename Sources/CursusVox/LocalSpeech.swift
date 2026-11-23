import Foundation
import AVFoundation
import Speech
import CursusCore

enum SpeechBackend: String { case apple, cloud }

// Engines to try, in order, for one recording. Choosing Apple never uploads.
enum RecognitionPlan {
    static func engines(selected: SpeechBackend, cloudKey: Bool, appleReady: Bool) -> [SpeechBackend] {
        switch selected {
        case .apple: return appleReady ? [.apple] : []
        case .cloud: return (cloudKey ? [.cloud] : []) + (appleReady ? [.apple] : [])
        }
    }
}

@MainActor final class LocalSpeech {
    private(set) var discovery = "Checking installed local speech"
    private(set) var backend: SpeechBackend = .apple
    private(set) var audioHighWater = 0
    // Which engine produced the latest transcript, for the recording pill.
    private(set) var lastEngine: SpeechBackend?
    // Per-recording facts for the delivery log: recognition time and, when the
    // selected engine failed over, why.
    private(set) var lastSpeechMillis: Int?
    private(set) var lastFallbackReason: String?
    // Why the cloud engine failed last, shown with a failed dictation; never response text.
    private var lastCloudFailure: String?
    private(set) var lastSpeechCost: Double?
    private(set) var lastSpeechModel: String?   // the OpenRouter model that transcribed it
    // The user's dictionary terms, read per recording and sent to Grok as key terms.
    var keyterms: () -> [String] = { Vocabulary.seed }
    var replacements: () -> [String: String] = { [:] }
    // Runs between recognition and delivery (rule pass, then optional AI pass).
    // Gets the time left before the policy's finalisation deadline and whether
    // the selected engine already failed over (then the AI pass is skipped).
    var cleanup: ((String, _ budget: TimeInterval, _ fellBack: Bool, CleanupContext) async -> CleanupOutcome)?
    // Completed provider work is billed even when cancellation prevents delivery.
    var usage: ((UsageEvent) -> Void)? {
        didSet { cloud.usage = usage; scribe.usage = usage }
    }
    var usageAdmission: ((UsageEvent) -> Bool)? {
        didSet { cloud.usageAdmission = usageAdmission; scribe.usageAdmission = usageAdmission }
    }
    var recordedFacts: ((Facts) -> Void)?
    var recoveryConfiguration: RecoveryConfiguration?
    private var activeRecoveryConfiguration: RecoveryConfiguration?
    private var activeKeyterms: [String] = []
    private(set) var effectiveSpeechModel = CloudSpeech.model
    private(set) var cleanupContext = CleanupContext()
    private var recognizing: UInt64?
    func isFinalizing(_ generation: UInt64) -> Bool { recognizing == generation }
    // Margin kept between cleanup and the policy's 15-second finalisation deadline.
    static let finalizeLimit: TimeInterval = 15
    static let deliveryMargin: TimeInterval = 1
    // What happened to the latest recording, for History and the delivery log.
    // It holds transcript text, so it expires with the recovery window.
    struct Facts: Equatable {
        let generation: UInt64
        let raw: String
        let engine: SpeechBackend
        let speechMillis: Int
        let fallback: String?
        var cleanup: CleanupOutcome?
        let at: TimeInterval
        var speechCost: Double? = nil   // US$ OpenRouter charged for the transcription
        var speechModel: String? = nil  // which OpenRouter model transcribed it
        var usageRecordingID: UUID? = nil
        var dictionaryCorrections: [String] = []
        var speechCredits = false       // billed to ElevenLabs credits, not dollars
        func expired(now: TimeInterval) -> Bool { now - at >= Policy.recoveryLifetime }
    }
    enum Retention { case recoverable, transient }
    private let retention: Retention
    private(set) var lastFacts: Facts?
    func purgeExpiredFacts(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if lastFacts?.expired(now: now) == true { lastFacts = nil }
    }
    var level: Float { audio.level }
    // Rough on-device text shown while the user talks; never delivered.
    let preview = LivePreview()
    var previewEnabled = true
    private let audio = NativeAudio()
    private var discoveryTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var cleanupSerial: UInt64 = 0
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var providerFormat: AVAudioFormat?
    private let cloud = CloudSpeech()
    private var selectedCloudKey: String?
    private var credentialTask: Task<Void, Never>?
    private var credentialWatchdog: Task<Void, Never>?
    private var credentialUnresponsive = false
    private let passiveCredentialDeadline: Duration
    private let interactiveCredentialDeadline: Duration
    private var stopped = false
    private let credentialRead: @Sendable () -> String?
    private let credentialAuthorize: @Sendable () -> String?
    private let scribeCredentialRead: @Sendable () -> String?
    private var credentialInteractive = false
    private var authorizationPending = false
    init(credentialRead: @escaping @Sendable () -> String? = { CloudCredentials.load() },
         credentialAuthorize: @escaping @Sendable () -> String? = { CloudCredentials.authorize() },
         scribeCredentialRead: @escaping @Sendable () -> String? = { CloudCredentials.loadElevenLabs() },
         passiveCredentialDeadline: Duration = .seconds(5),
         interactiveCredentialDeadline: Duration = .seconds(30),
         retention: Retention = .recoverable) {
        self.retention = retention
        self.scribeCredentialRead = scribeCredentialRead
        self.credentialRead = credentialRead
        self.credentialAuthorize = credentialAuthorize
        self.passiveCredentialDeadline = passiveCredentialDeadline
        self.interactiveCredentialDeadline = interactiveCredentialDeadline
    }
    var cloudCredentialReady: Bool { elevenLabsDirect ? elevenLabsKey != nil : selectedCloudKey != nil }
    var credentialReadPending: Bool { elevenLabsDirect ? scribeCredentialTask != nil : credentialTask != nil }
    var credentialUnresponsiveNow: Bool { elevenLabsDirect ? scribeCredentialUnresponsive : credentialUnresponsive }
    private var admitted: UInt64?
    private var running = false
    var updated: (() -> Void)?
    var event: ((Event) -> Void)?

    // Transcribes a saved recording again with the cloud engine (Grok or one-step).
    func retry(_ item: AudioOutbox.Item, oneStep: Bool, clean: Bool? = nil,
               outbox: AudioOutbox = .shared, protocolClasses: [AnyClass]? = nil, recordingID: UUID = UUID(), vocabulary: Vocabulary? = nil) async -> (text: String, costUSD: Double?)? {
        retryUsedScribeBackup = false
        let config = item.configuration ?? RecoveryConfiguration(engine: elevenLabsDirect ? .elevenLabs : backend == .apple ? .local : oneStep ? .oneStep : .cloud,
            speechModel: elevenLabsDirect ? ScribeSpeech.id(scribeModel) : transcriptionModel)
        guard let wav = outbox.data(item) else { return nil }
        let group = recordingID
        if config.engine == .local {
            guard let url = outbox.url(for: item) else { return nil }
            var attempt = UsageEvent(recordingID: group, provider: "apple-local", model: "apple-speech", operation: .retry, charge: 0)
            usage?(attempt)
            let text = await LocalFileRetry.transcribe(url)
            attempt.outcome = text == nil ? .failed : .succeeded; usage?(attempt)
            return text.map { ($0, nil) }
        }
        if config.engine == .elevenLabs {
            guard let key = elevenLabsKey ?? CloudCredentials.loadElevenLabs() else { return nil }
            let direct = ScribeSpeech(protocolClasses: protocolClasses); direct.usage = usage; direct.usageAdmission = usageAdmission
            direct.usageOperation = .retry; direct.usageRecordingID = group
            direct.model = ScribeSpeech.model(config.speechModel)
            guard let text = try? await direct.transcribe(wav: wav, key: key, keyterms: vocabulary?.terms ?? []), !text.isEmpty else { return nil }
            return (text, nil)
        }
        guard let key = cloudKey ?? CloudCredentials.load() else { return nil }
        let engine = CloudSpeech(protocolClasses: protocolClasses); engine.oneStep = config.engine == .oneStep
        engine.usage = usage; engine.usageAdmission = usageAdmission; engine.usageOperation = .retry; engine.usageRecordingID = group
        engine.transcriptionModel = config.speechModel; engine.liveModels = cloud.liveModels
        engine.cleans = { config.cleanupEnabled && config.smart }
        let rules = vocabulary.map { Dictionary($0.replacements.map { ($0.from, $0.to) }, uniquingKeysWith: { a,_ in a }) }
        engine.replacements = rules.map { value in { value } } ?? replacements
        do {
            let result = try await engine.transcribe(wav: wav, key: key, keyterms: vocabulary?.terms ?? keyterms())
            return (result.text, result.costUSD)
        } catch {
            // Same backup as live dictation: Scribe, when its key is saved, after a 404 or 5xx.
            guard config.engine == .cloud, CloudSpeech.tryNextModel(after: error),
                  let scribeKey = backupScribeKey ?? CloudCredentials.loadElevenLabs() else { return nil }
            let direct = ScribeSpeech(protocolClasses: protocolClasses); direct.usage = usage; direct.usageAdmission = usageAdmission
            direct.usageOperation = .retry; direct.usageRecordingID = group; direct.model = scribeModel
            guard let text = try? await direct.transcribe(wav: wav, key: scribeKey, keyterms: vocabulary?.terms ?? []), !text.isEmpty else { return nil }
            retryUsedScribeBackup = true
            return (text, nil)
        }
    }

    // Direct ElevenLabs Scribe on the user's credits instead of OpenRouter cloud.
    var elevenLabsDirect = false
    // The Scribe model picked in Settings, persisted by App. A direct recording freezes it
    // in its recovery configuration; the OpenRouter backup uses the current choice.
    var scribeModel = ScribeSpeech.defaultModel
    private(set) var elevenLabsKey: String?
    private var scribeCredentialTask: Task<Void, Never>?
    private var scribeCredentialWatchdog: Task<Void, Never>?
    private var scribeCredentialUnresponsive = false
    private func readScribeCredential(interactive: Bool = false) {
        guard !stopped, elevenLabsDirect, elevenLabsKey == nil, scribeCredentialTask == nil else { return }
        scribeCredentialUnresponsive = false
        scribeCredentialWatchdog = Task { [weak self] in
            do { try await Task.sleep(for: interactive ? .seconds(30) : .seconds(5)) } catch { return }
            guard let self, !stopped, scribeCredentialTask != nil else { return }
            scribeCredentialUnresponsive = true
            discover()
        }
        let read = scribeCredentialRead
        scribeCredentialTask = Task { [weak self] in
            let key = await Task.detached {
                interactive ? CloudCredentials.authorizeElevenLabs() : read()
            }.value
            guard let self else { return }
            scribeCredentialWatchdog?.cancel(); scribeCredentialWatchdog = nil
            scribeCredentialTask = nil
            guard !Task.isCancelled, !stopped, elevenLabsDirect, !scribeCredentialUnresponsive else { return }
            elevenLabsKey = CloudCredentials.validated(key)
            discover()
        }
    }
    // An ElevenLabs key saved for direct Scribe also backs up OpenRouter speech. Read once,
    // off the main actor and without a prompt; nil when none is saved.
    private var backupScribeKey: String?
    private var backupScribeRead: Task<Void, Never>?
    // Re-read on every cloud selection, so a key saved or replaced later is picked up.
    private func readBackupScribeKey() {
        backupScribeRead?.cancel(); backupScribeRead = nil
        guard !stopped, !elevenLabsDirect else { backupScribeKey = nil; return }
        let read = scribeCredentialRead
        backupScribeRead = Task { [weak self] in
            let key = await Task.detached { CloudCredentials.validated(read()) }.value
            guard let self, !Task.isCancelled, !stopped else { return }
            backupScribeKey = key; backupScribeRead = nil
        }
    }
    // Set when Scribe backed up OpenRouter: shown in History and the badge like any fallback,
    // because the audio went to a provider with standard retention. (A switch between
    // OpenRouter models is recorded as the delivery's speechModel instead.)
    private var cloudBackupNote: String?
    private var scribeBackupFailure: String?
    // The last panel retry went to ElevenLabs Scribe as a backup; App says so in History.
    private(set) var retryUsedScribeBackup = false
    // Scribe takes over only after a quick refusal (gone or provider down) and never for one-step,
    // whose single call already cleans; a key, credit or rate refusal is not a model problem.
    nonisolated static func scribeBacksUp(_ error: Error, oneStep: Bool, elapsed: TimeInterval) -> Bool {
        !oneStep && elapsed < 3 && CloudSpeech.tryNextModel(after: error)
    }
    private var speechCredentialReady: Bool { elevenLabsDirect ? elevenLabsKey != nil : cloudKey != nil }
    private let scribe = ScribeSpeech()
    // Cloud speech as one step (hear and clean in one call) instead of Grok then cleanup.
    var liveSpeechModels: Set<String>? {
        get { cloud.liveModels }
        set { cloud.liveModels = newValue }
    }
    var oneStep: Bool {
        get { cloud.oneStep }
        set { cloud.oneStep = newValue }
    }
    var cloudModel: String { elevenLabsDirect ? ScribeSpeech.id(scribeModel) : cloud.model }
    // The picked transcription model, persisted by App; Grok until changed.
    var transcriptionModel: String {
        get { cloud.transcriptionModel }
        set { cloud.transcriptionModel = newValue }
    }
    // On-device speech with AI cleanup: the audio stays on this Mac, only the text is cleaned
    // in the cloud (measured 2026-10-13: 5.5% WER, cheapest of every engine tested).
    var cloudCleanupOnDevice = false
    func select(_ value: SpeechBackend) {
        guard !stopped else { return }
        if let admitted { close(admitted) }
        backend = value
        if value == .cloud && elevenLabsDirect { readScribeCredential() }
        else { elevenLabsKey = nil }
        if value == .cloud { readBackupScribeKey() }
        if value == .apple && !cloudCleanupOnDevice { selectedCloudKey = nil; authorizationPending = false }
        else if value == .apple, selectedCloudKey == nil, credentialTask == nil {
            startCredentialRead(credentialRead, interactive: false)
        }
        else if selectedCloudKey == nil && credentialTask == nil {
            startCredentialRead(credentialRead, interactive: false)
        }
        discover()
    }
    func authorizeCloudCredential() {
        if elevenLabsDirect {
            guard backend == .cloud, elevenLabsKey == nil else { return }
            readScribeCredential(interactive: true)
            discover(); return
        }
        guard !stopped, needsCloudKey, selectedCloudKey == nil else { return }
        if credentialTask != nil {
            guard !credentialUnresponsive else { return }
            // An explicit request survives one pending passive read, but repeated
            // clicks never queue another OS dialogue behind an active one.
            if !credentialInteractive { authorizationPending = true }
            return
        }
        startCredentialRead(credentialAuthorize, interactive: true)
        discover()
    }
    private func startCredentialRead(_ read: @escaping @Sendable () -> String?, interactive: Bool) {
        guard !stopped, credentialTask == nil else { return }
        credentialInteractive = interactive
        credentialUnresponsive = false
        let deadline = interactive ? interactiveCredentialDeadline : passiveCredentialDeadline
        credentialWatchdog = Task { [weak self] in
            do { try await Task.sleep(for: deadline) } catch { return }
            guard let self, !stopped, credentialTask != nil else { return }
            credentialUnresponsive = true
            authorizationPending = false
            if needsCloudKey { discover() }
        }
        // Native Security calls cannot be canceled. Retain one owner until the
        // call returns, then discard a result for a changed backend or shutdown.
        credentialTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { read() }.value
            guard let self else { return }
            credentialWatchdog?.cancel(); credentialWatchdog = nil
            credentialTask = nil; credentialInteractive = false
            let requested = authorizationPending
            authorizationPending = false
            guard !Task.isCancelled, !stopped, needsCloudKey else { return }
            guard !credentialUnresponsive else { discover(); return }
            selectedCloudKey = CloudCredentials.validated(result)
            if selectedCloudKey == nil && requested {
                startCredentialRead(credentialAuthorize, interactive: true)
            }
            discover()
        }
    }
    private var cloudKey: String? {
        selectedCloudKey
    }
    // The OpenRouter key, loaded only while Grok is selected. On-device mode keeps
    // text on the Mac too, so it gets the rule pass and no AI cleanup.
    // Grok, or on-device speech whose text is cleaned in the cloud.
    private var needsCloudKey: Bool { backend == .cloud || (backend == .apple && cloudCleanupOnDevice) }
    func cleanupKey(saved: RecoveryConfiguration?) async -> String? {
        guard let saved else { return openRouterKey }
        guard saved.cleanupEnabled, !stopped else { return nil }
        if let selectedCloudKey { return selectedCloudKey }
        let read = credentialRead
        let key = await Task.detached { CloudCredentials.validated(read()) }.value
        guard !stopped, !Task.isCancelled else { return nil }
        return key
    }
    var openRouterKey: String? { backend == .cloud || cloudCleanupOnDevice ? selectedCloudKey : nil }
    private func microphoneStatus() -> Authorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .unknown
        default: return .denied
        }
    }
    private func speechStatus() -> Authorization {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .authorized
        case .notDetermined: return .unknown
        default: return .denied
        }
    }
    private func inspectApple() async -> (Availability, SpeechTranscriber?) {
        guard SpeechTranscriber.isAvailable else {
            return (Availability(frameworkAvailable: false, localeSupported: false,
                assetsInstalled: false, microphone: microphoneStatus(), speech: speechStatus()), nil)
        }
        guard let locale = await SpeechLanguageStore.locale() else {
            return (Availability(frameworkAvailable: true, localeSupported: false,
                assetsInstalled: false, microphone: microphoneStatus(), speech: speechStatus()), nil)
        }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        let installed = await AssetInventory.status(forModules: [module]) == .installed
        return (Availability(frameworkAvailable: true, localeSupported: true,
            assetsInstalled: installed, microphone: microphoneStatus(), speech: speechStatus()), module)
    }
    func discover() {
        discoveryTask?.cancel()
        let selected = backend
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            if selected == .cloud {
                if elevenLabsDirect {
                    discovery = scribeCredentialUnresponsive ? "ElevenLabs Keychain is not responding; using on-device speech"
                        : scribeCredentialTask != nil ? "Checking ElevenLabs key…"
                        : elevenLabsKey == nil ? "ElevenLabs not set up; using on-device speech" : "ElevenLabs key available; see Health for connection status"
                } else {
                discovery = credentialUnresponsive
                    ? "Keychain is not responding; using on-device speech"
                    : credentialReadPending ? "Checking Grok key…"
                    : cloudKey == nil ? "Grok not set up; using on-device speech"
                    : "OpenRouter key available; see Health for connection status"
                }
            } else {
                let (value, _) = await inspectApple()
                guard !Task.isCancelled, backend == selected else { return }
                discovery = value.assetsInstalled ? "On-device speech ready" : value.explanation
            }
            guard !Task.isCancelled, backend == selected else { return }
            updated?()
        }
    }
    private func valid(_ id: UInt64) -> Bool { admitted == id && !Task.isCancelled }
    func startup(_ generation: UInt64, context: CleanupContext = CleanupContext(), cleanOneStep: Bool = true) {
        if let admitted { close(admitted) }
        guard !stopped, startupTask == nil, recognitionTask == nil, cleanupTask == nil else {
            event?(.recognitionFailed(generation, "Previous recording is still releasing its resources; try again when cleanup finishes"))
            return
        }
        admitted = generation
        activeRecoveryConfiguration = recoveryConfiguration
        cleanupContext = context
        effectiveSpeechModel = context.preset?.configuration.speechModel ?? cloud.transcriptionModel
        activeKeyterms = context.vocabulary?.terms ?? keyterms()
        let frozenTerms = activeKeyterms
        preview.keyterms = { frozenTerms }
        let frozenRules = context.vocabulary.map { Dictionary($0.replacements.map { ($0.from, $0.to) }, uniquingKeysWith: { a,_ in a }) } ?? replacements()
        cloud.replacements = { frozenRules }
        cleanupContext.recordingID = UUID()
        cloud.usageRecordingID = cleanupContext.recordingID
        scribe.usageRecordingID = cleanupContext.recordingID
        cleanupContext.oneStep = oneStep
        cloud.cleans = { cleanOneStep }
        lastSpeechCost = nil; lastSpeechModel = nil
        let selected = backend
        startupTask = Task { [weak self] in
            guard let self else { return }
            defer { startupTask = nil }
            do {
                guard valid(generation) else { return }
                var module: SpeechTranscriber?
                if selected == .apple {
                    let (availability, inspected) = await inspectApple()
                    guard valid(generation) else { return }
                    guard availability.frameworkAvailable, availability.localeSupported,
                          availability.assetsInstalled, let inspected else {
                        event?(.startupCompleted(generation, availability, acquiredAdapter: false))
                        return
                    }
                    module = inspected
                } else if !speechCredentialReady {
                    let (availability, _) = await inspectApple()
                    guard valid(generation) else { return }
                    guard availability.assetsInstalled, speechStatus() == .authorized else {
                        fail(generation, "The speech provider is not set up and on-device speech is not ready; open Mercurius setup")
                        return
                    }
                }
                // This method is called only by an admitted explicit Record gesture.
                if microphoneStatus() == .unknown {
                    _ = await AVCaptureDevice.requestAccess(for: .audio)
                }
                guard valid(generation) else { return }
                guard microphoneStatus() == .authorized else {
                    fail(generation, "Microphone permission is required; allow it in System Settings")
                    return
                }
                if selected == .apple {
                    if speechStatus() == .unknown {
                        let _: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
                            let reply: @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void = {
                                result in continuation.resume(returning: result)
                            }
                            SFSpeechRecognizer.requestAuthorization(reply)
                        }
                    }
                    guard valid(generation) else { return }
                    guard speechStatus() == .authorized, let module else {
                        fail(generation, "Speech permission is required; allow it in System Settings")
                        return
                    }
                    // Nothing downloads here: languages are installed only from the language picker.
                    guard await AssetInventory.status(forModules: [module]) == .installed,
                          valid(generation) else {
                        if valid(generation) { fail(generation, "Choose your language for on-device speech in Settings") }
                        return
                    }
                    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]),
                          valid(generation) else {
                        if valid(generation) { fail(generation, "Local speech has no compatible audio format") }
                        return
                    }
                    let analyzer = SpeechAnalyzer(modules: [module])
                    self.analyzer = analyzer
                    self.transcriber = module
                    providerFormat = format
                    do {
                        try await analyzer.prepareToAnalyze(in: format)
                    } catch {
                        retireAnalyzer(analyzer)
                        throw error
                    }
                    guard valid(generation) else {
                        retireAnalyzer(analyzer)
                        return
                    }
                }
                try audio.prepare()
                guard valid(generation) else { audio.close(); return }
                event?(.startupCompleted(generation, Availability(frameworkAvailable: true,
                    localeSupported: true, assetsInstalled: true, microphone: .authorized,
                    speech: .authorized), acquiredAdapter: true))
            } catch {
                if valid(generation) { fail(generation, "Recording setup failed; no audio result was produced") }
            }
        }
    }
    private func retireAnalyzer(_ instance: SpeechAnalyzer) {
        if analyzer === instance {
            analyzer = nil; transcriber = nil; providerFormat = nil
        }
        let previous = cleanupTask
        cleanupSerial &+= 1
        let serial = cleanupSerial
        cleanupTask = Task { [weak self] in
            await previous?.value
            await instance.cancelAndFinishNow()
            guard self?.cleanupSerial == serial else { return }
            self?.cleanupTask = nil
            self?.updated?()
        }
    }
    func capture(_ generation: UInt64) {
        guard admitted == generation else { return }
        do {
            try audio.start(); running = true
            if previewEnabled { audio.setPreviewTap(preview.begin()) }
        }
        catch { fail(generation, "Microphone capture could not start") }
    }
    func poll() {
        guard let admitted, running else { return }
        if audio.durationLimitReached {
            event?(.captureLimitReached(admitted))
            return
        }
        if let error = audio.failure {
            fail(admitted, error == .limit || error == .overflow
                ? "Audio capacity exceeded; recording cancelled without a transcript"
                : "Microphone or audio conversion failed; recording cancelled")
        }
    }
    func finalize(_ generation: UInt64) {
        guard admitted == generation, running else { return }
        running = false
        preview.end()
        let batch: AudioBatch
        do { batch = try audio.finish() }
        catch {
            fail(generation, "Audio capture could not be finalized; no transcript was produced")
            return
        }
        if batch.durationLimitReached { event?(.captureLimitReached(generation)) }
        let selected = backend
        let stoppedAt = ProcessInfo.processInfo.systemUptime
        let context = cleanupContext
        recognizing = generation
        recognitionTask = Task { [weak self] in
            guard let self else { return }
            defer { recognitionTask = nil; recognizing = nil; updated?() }
            do {
                let raw = try await recognize(batch, id: generation, selected: selected)
                audioHighWater = batch.budget.highWater
                guard let engine = lastEngine else { return }
                let facts = Facts(generation: generation, raw: raw, engine: engine,
                    speechMillis: lastSpeechMillis ?? 0, fallback: lastFallbackReason, cleanup: nil,
                    at: ProcessInfo.processInfo.systemUptime, speechCost: engine == .cloud ? lastSpeechCost : nil,
                    speechModel: engine == .cloud ? lastSpeechModel : nil,
                    usageRecordingID: cleanupContext.recordingID, speechCredits: engine == .cloud && ScribeSpeech.isDirect(lastSpeechModel))
                let left = Self.finalizeLimit - Self.deliveryMargin - (ProcessInfo.processInfo.systemUptime - stoppedAt)
                guard let text = await finishRecognized(facts, context: context, budget: left,
                    isCurrent: { self.valid(generation) }) else { return }
                guard text.utf8.count <= Policy.textLimit else {
                    fail(generation, "Result exceeds 256 KiB")
                    return
                }
                event?(.final(generation, text))
            } catch {
                audioHighWater = batch.budget.highWater
                if valid(generation) {
                    // Keep the audio so it can be retried instead of spoken again.
                    var kept = false
                    if !(error is CancellationError) { kept = retainFailedAudio(batch) }
                    let reason = lastCloudFailure.map { " (\($0))" } ?? ""
                    let failure = retention == .transient
                        ? "Transcription failed\(reason). Audio was not retained; record the command again."
                        : AudioOutbox.shared.problem ?? "Transcription failed\(reason) or exceeded a limit; no final transcript was produced"
                    fail(generation, kept ? "Transcription failed\(reason); the recording is kept for 10 minutes. Retry it from the panel." : failure)
                }
            }
        }
    }
    // Command audio must never enter ordinary dictation recovery.
    func retainFailedAudio(_ batch: AudioBatch, outbox: AudioOutbox = .shared) -> Bool {
        guard retention == .recoverable, let (wav, lease) = try? NativeAudio.wav(batch) else { return false }
        defer { withExtendedLifetime(lease) {} }
        return outbox.save(wav, configuration: activeRecoveryConfiguration) != nil
    }
    // Tries each planned engine in order. A cloud failure (network, status,
    // timeout, missing key) falls back to installed on-device speech.
    private func recognize(_ batch: AudioBatch, id: UInt64, selected: SpeechBackend) async throws -> String {
        let (availability, _) = selected == .apple && analyzer != nil
            ? (Availability(frameworkAvailable: true, localeSupported: true, assetsInstalled: true,
                            microphone: .authorized, speech: .authorized), nil)
            : await inspectApple()
        let appleReady = availability.assetsInstalled && speechStatus() == .authorized
        var lastError: Error = CancellationError()
        let cloudReady = speechCredentialReady
        var fallback: String? = selected == .cloud && !cloudReady ? "Speech provider not set up" : nil
        lastCloudFailure = fallback; cloudBackupNote = nil; scribeBackupFailure = nil
        let began = ProcessInfo.processInfo.systemUptime
        for engine in RecognitionPlan.engines(selected: selected, cloudKey: cloudReady, appleReady: appleReady) {
            guard valid(id) else { throw CancellationError() }
            do {
                let text = engine == .cloud ? try await recognizeCloud(batch, id: id)
                                            : try await recognizeAppleOnDemand(batch, id: id)
                lastEngine = engine
                lastSpeechMillis = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
                lastFallbackReason = fallback ?? cloudBackupNote
                return text
            } catch {
                lastError = error
                if engine == .cloud {
                    fallback = Self.describe(error) + (scribeBackupFailure.map { "; ElevenLabs Scribe backup also failed: \($0)" } ?? "")
                    lastCloudFailure = fallback
                }
            }
        }
        throw lastError
    }
    private func recognizeAppleOnDemand(_ source: AudioBatch, id: UInt64) async throws -> String {
        if analyzer == nil {
            let (_, inspected) = await inspectApple()
            guard valid(id), let module = inspected,
                  let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]),
                  valid(id) else { throw CancellationError() }
            let analyzer = SpeechAnalyzer(modules: [module])
            self.analyzer = analyzer; transcriber = module; providerFormat = format
            do {
                try await analyzer.prepareToAnalyze(in: format)
            } catch {
                retireAnalyzer(analyzer)
                throw error
            }
            guard valid(id) else {
                retireAnalyzer(analyzer)
                throw CancellationError()
            }
        }
        return try await recognizeApple(source, id: id)
    }
    private func recognizeApple(_ source: AudioBatch, id: UInt64) async throws -> String {
        guard valid(id), let analyzer, let transcriber, let providerFormat else { throw CancellationError() }
        var attempt = UsageEvent(recordingID: cleanupContext.recordingID, provider: "apple-local", model: "apple-speech", operation: .speech, charge: 0)
        usage?(attempt)
        defer { if attempt.outcome == .interrupted { attempt.outcome = Task.isCancelled ? .cancelled : .failed }; usage?(attempt) }
        let text = try await BatchSpeechRecognition.transcribe(source, analyzer: analyzer,
            transcriber: transcriber, format: providerFormat)
        guard valid(id) else { throw CancellationError() }
        attempt.outcome = .succeeded
        return text
    }

    private func recognizeCloud(_ batch: AudioBatch, id: UInt64) async throws -> String {
        if let config = activeRecoveryConfiguration, config.engine == .cloud { cloud.transcriptionModel = config.speechModel }
        if elevenLabsDirect {
            guard valid(id), let key = elevenLabsKey else { throw CancellationError() }
            scribe.model = activeRecoveryConfiguration.map { ScribeSpeech.model($0.speechModel) } ?? scribeModel
            let text = try await scribe.transcribe(batch, key: key, keyterms: activeKeyterms)
            lastSpeechCost = nil; lastSpeechModel = ScribeSpeech.id(scribe.lastModel)
            return text
        }
        guard valid(id), let key = cloudKey else { throw CancellationError() }
        let began = ProcessInfo.processInfo.systemUptime
        let result: CloudSpeech.Result
        do {
            result = try await cloud.transcribe(batch, key: key, keyterms: activeKeyterms, oneStep: cleanupContext.oneStep, model: effectiveSpeechModel)
        } catch {
            // Every OpenRouter model refused quickly: ElevenLabs Scribe, when its key is saved,
            // gets the same audio while on-device speech still fits the deadline.
            guard let scribeKey = backupScribeKey, valid(id), Self.scribeBacksUp(error, oneStep: cleanupContext.oneStep,
                  elapsed: ProcessInfo.processInfo.systemUptime - began) else { throw error }
            scribe.timeout = CloudSpeech.requestTimeout - (ProcessInfo.processInfo.systemUptime - began)
            defer { scribe.timeout = CloudSpeech.requestTimeout }
            let text: String
            scribe.model = scribeModel
            do { text = try await scribe.transcribe(batch, key: scribeKey, keyterms: activeKeyterms) }
            catch let backup {
                // The audio already went to ElevenLabs, so say so; OpenRouter's reason stays first.
                scribeBackupFailure = Self.describe(backup)
                throw error
            }
            lastSpeechCost = nil; lastSpeechModel = ScribeSpeech.id(scribe.lastModel)
            cloudBackupNote = "\(Self.describe(error)); ElevenLabs Scribe transcribed it (standard retention)"
            return text
        }
        lastSpeechCost = result.costUSD
        lastSpeechModel = cleanupContext.oneStep ? CloudSpeech.oneStepModel : result.model ?? effectiveSpeechModel
        return result.text
    }
    // Keep billing facts before deciding whether this result can still be delivered.
    func finishRecognized(_ recognized: Facts, context: CleanupContext, budget: TimeInterval,
                          isCurrent: () -> Bool) async -> String? {
        var facts = recognized
        facts.dictionaryCorrections = context.vocabulary?.appliedCorrections(in: facts.raw) ?? []
        if isCurrent(), !facts.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let cleanup {
            // Only an on-device fallback skips AI cleanup; a cloud backup (Scribe) still gets it.
            facts.cleanup = await cleanup(facts.raw, budget, facts.fallback != nil && facts.engine != .cloud, context)
        }
        lastFacts = retention == .recoverable ? facts : nil
        recordedFacts?(facts)
        guard isCurrent() else { return nil }
        return facts.cleanup?.text ?? facts.raw
    }
    // A short, text-free reason for the log: never the response body.
    private static func describe(_ error: Error) -> String {
        switch error {
        case let failure as URLError where failure.code == .timedOut: "Speech provider timed out"
        case is URLError: "Speech provider network error"
        case CloudFailure.accountingUnavailable: "Usage could not be saved. Open Usage & budget before retrying."
        case let CloudFailure.status(code):
            code == 401 ? "Speech provider key rejected (HTTP 401)" : code == 402 ? "Speech provider credit required (HTTP 402)"
                : code == 429 ? "Speech provider rate limited (HTTP 429)" : "Speech provider returned HTTP \(code)"
        case AudioFailure.conversion: "Speech provider returned an unreadable reply"
        case AudioFailure.limit: "Speech provider response too large"
        default: "Speech provider failed"
        }
    }
    private func fail(_ id: UInt64, _ message: String) {
        guard admitted == id else { return }
        audioHighWater = audio.budget.highWater
        event?(.recognitionFailed(id, message))
    }
    func close(_ generation: UInt64) {
        guard admitted == generation else { return }
        admitted = nil
        running = false
        preview.end()
        // Retain owners until their SDK operation actually returns. A canceled
        // Task is not proof that Apple's non-cancellable work has finished.
        startupTask?.cancel()
        recognitionTask?.cancel()
        cloud.cancel(); scribe.cancel()
        audioHighWater = max(audioHighWater, audio.budget.highWater)
        audio.close()
        if let analyzer {
            retireAnalyzer(analyzer)
        }
        analyzer = nil; transcriber = nil; providerFormat = nil
    }
    func shutdown() {
        stopped = true
        authorizationPending = false
        credentialWatchdog?.cancel(); credentialWatchdog = nil
        credentialTask?.cancel()
        if let admitted { close(admitted) }
        discoveryTask?.cancel(); discoveryTask = nil
        event = nil; updated = nil
        selectedCloudKey = nil; elevenLabsKey = nil
        scribeCredentialWatchdog?.cancel(); scribeCredentialWatchdog = nil
        scribeCredentialTask?.cancel()
        backupScribeRead?.cancel(); backupScribeRead = nil; backupScribeKey = nil
    }
    var permissionsRevoked: Bool {
        microphoneStatus() == .denied || (backend == .apple && speechStatus() == .denied)
    }
}
