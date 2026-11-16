import AVFoundation
import Speech
import ObjectiveC

// Words on screen while the user talks. Apple's on-device speech hears the same
// 16 kHz audio as the recording and its rough text is shown in the pill. The
// preview is never pasted, logged or kept: on release the selected engine's text
// replaces it. Without on-device speech (no permission or no installed model)
// there is simply no preview.
@MainActor final class LivePreview {
    enum Unavailable: Equatable {
        case permission, localRecognizer, recognition
        var message: String {
            switch self {
            case .permission: "Live words need Speech Recognition access. Open Mercurius setup."
            case .localRecognizer: "Live words need an installed on-device English recognizer. Final transcription can still work."
            case .recognition: "Live words stopped. Check Speech Recognition in Mercurius setup after recording."
            }
        }
    }
    private(set) var unavailable: Unavailable?
    private let authorization: () -> SFSpeechRecognizerAuthorizationStatus
    init(authorization: @escaping () -> SFSpeechRecognizerAuthorizationStatus = { SFSpeechRecognizer.authorizationStatus() }) {
        self.authorization = authorization
    }
    // Words the recogniser has settled on, and the words it may still change.
    private(set) var settled = ""
    private(set) var volatile = ""
    var changed: (() -> Void)?
    var keyterms: () -> [String] = { [] }
    private(set) var localeIdentifier: String?
    private var session = 0
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var tasks: [Task<Void, Never>] = []
    // About a minute of speech; the pill shows only the tail anyway.
    static let characterLimit = 2000
    // About 20 s of audio while the recogniser starts (each chunk is ~21 ms, under 1 KB); later chunks are dropped.
    nonisolated static let queueLimit = 1000

    var isEmpty: Bool { settled.isEmpty && volatile.isEmpty }

    // Returns the audio tap at once so no opening words are missed; the
    // recogniser catches up on the buffered audio once it is ready.
    func begin() -> @Sendable (AVAudioPCMBuffer, AudioLease) -> Void {
        end()
        session += 1
        let id = session
        localeIdentifier = nil
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(Self.queueLimit))
        input = continuation
        let held = HeldLeases()
        leases = held
        tasks.append(Task { [weak self] in await self?.run(stream, id: id) })
        return { buffer, lease in
            // A chunk the queue refuses gives its lease straight back.
            if case .enqueued = continuation.yield(AnalyzerInput(buffer: buffer)) { held.add(lease, buffer: buffer) }
        }
    }
    private var leases: HeldLeases?

    @discardableResult func end() -> Task<Void, Never> {
        session += 1
        input?.finish(); input = nil
        let held = leases; leases = nil
        let ending = tasks; tasks = []
        ending.forEach { $0.cancel() }
        let analyzer = analyzer
        let released = Self.releaseLeases(held) {
            await analyzer?.cancelAndFinishNow()
            for task in ending { await task.value }
        }
        self.analyzer = nil
        let needsUpdate = !isEmpty || unavailable != nil
        settled = ""; volatile = ""; unavailable = nil
        if needsUpdate { changed?() }
        return released
    }

    // A stuck SDK drain must not retain the side array forever. Buffer owners
    // still hold their associated leases after the deadline clears the array.
    static func releaseLeases(_ held: HeldLeases?, deadline: Duration = .seconds(1),
                              finish: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let timeout = Task {
            do { try await Task.sleep(for: deadline) } catch { return }
            // SDK-retained buffers keep their leases charged until the PCM is actually released.
            held?.clear()
        }
        Task {
            await finish()
            held?.clear()
            timeout.cancel()
        }
        return timeout
    }

    private func run(_ stream: AsyncStream<AnalyzerInput>, id: Int) async {
        guard id == session, !Task.isCancelled else { return finish(id) }
        guard authorization() == .authorized else { return finish(id, unavailable: .permission) }
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechLanguageStore.locale(),
              id == session else { return await runLegacy(stream, id: id) }
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                       reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        guard await AssetInventory.status(forModules: [module]) == .installed,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]),
              // The recording is 16 kHz mono Int16; anything else would need a converter.
              format.commonFormat == .pcmFormatInt16, format.sampleRate == 16_000, format.channelCount == 1,
              id == session else { return await runLegacy(stream, id: id) }
        localeIdentifier = locale.identifier
        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer
        tasks.append(Task { [weak self] in
            do {
                for try await result in module.results {
                    guard let self, id == session else { return }
                    let words = String(result.text.characters).trimmingCharacters(in: .whitespaces)
                    if result.isFinal {
                        let joined = settled.isEmpty || words.isEmpty ? settled + words : settled + " " + words
                        settled = String(joined.suffix(Self.characterLimit)); volatile = ""
                    } else {
                        volatile = String(words.suffix(Self.characterLimit))
                    }
                    changed?()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.finish(id, unavailable: .recognition)
            }
        })
        do { try await analyzer.start(inputSequence: stream) }
        catch { if !Task.isCancelled { finish(id, unavailable: .recognition) } }
    }

    // An existing legacy on-device asset can provide partial words even when
    // the newer SpeechTranscriber asset is absent. Never fall back to a server.
    private func runLegacy(_ stream: AsyncStream<AnalyzerInput>, id: Int) async {
        guard id == session, !Task.isCancelled else { return }
        let recognizer = SpeechLanguageStore.recognitionOrder.compactMap { SFSpeechRecognizer(locale: Locale(identifier: $0)) }
            .first { $0.isAvailable && $0.supportsOnDeviceRecognition }
        guard let recognizer else { return finish(id, unavailable: .localRecognizer) }
        localeIdentifier = recognizer.locale.identifier
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = Array(keyterms().prefix(100))
        let recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self, self.session == id else { return }
                if let text {
                    if final { self.settled = String(text.suffix(Self.characterLimit)); self.volatile = "" }
                    else { self.volatile = String(text.suffix(Self.characterLimit)) }
                    self.changed?()
                }
                if failed { self.finish(id, unavailable: .recognition) }
            }
        }
        defer { request.endAudio(); recognition.cancel() }
        for await input in stream {
            guard id == session, !Task.isCancelled else { break }
            request.append(input.buffer)
        }
        withExtendedLifetime(recognizer) {}
    }

    // No preview this time: stop buffering audio for it.
    private func finish(_ id: Int, unavailable reason: Unavailable? = nil) {
        guard id == session else { return }
        input?.finish(); input = nil
        if let reason, unavailable != reason { unavailable = reason; changed?() }
    }
}

// Hold every accepted lease through session teardown. Buffer ownership also keeps
// queued PCM charged if the framework retains it after teardown has returned.
final class HeldLeases: @unchecked Sendable {
    private nonisolated(unsafe) static var leaseKey: UInt8 = 0
    private let lock = NSLock()
    private var leases: [AudioLease] = []
    func add(_ lease: AudioLease, buffer: AVAudioPCMBuffer) {
        objc_setAssociatedObject(buffer, &Self.leaseKey, lease, .OBJC_ASSOCIATION_RETAIN)
        lock.withLock { leases.append(lease) }
    }
    func clear() { lock.withLock { leases.removeAll() } }
}
