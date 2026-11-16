import AppKit
import AVFoundation
import QuartzCore

// Koa, the koala who listens, thinks and answers in the recording pill. The motion comes from
// short rendered clips (Design/Koa, HEVC with alpha, 24 fps). The microphone selects
// a calm or expressive listening loop; the rig supplies the face, head and ear motion.

enum KoaClip: String, CaseIterable, Sendable {
    case popIn = "pop_in", listenCalm = "listen_calm", listenLoud = "listen_loud", think, happy, oops, shrug

    var frameCount: Int {
        switch self {
        case .popIn: 12
        case .listenCalm, .listenLoud, .think: 48
        case .happy, .oops: 19
        case .shrug: 14
        }
    }
    var loops: Bool { self == .listenCalm || self == .listenLoud || self == .think }
}

// Which clip and frame to show. Pure, so the choreography is testable without a screen.
struct KoaDirector: Equatable {
    enum Mood: Equatable { case listening, thinking, happy, oops, shrug }
    static let fps: Double = 24
    // Speaking up switches to the lively loop; it settles back only when the voice drops well
    // below, so Koa doesn't flicker between the two.
    static let loudAbove: CGFloat = 0.45, calmBelow: CGFloat = 0.25

    private(set) var mood: Mood = .listening
    private(set) var clip: KoaClip = .popIn
    private(set) var startedAt: TimeInterval = 0
    private(set) var voice: CGFloat = 0          // smoothed level, 0...1

    // A new recording starts with the pop-in, which hands over to listening.
    mutating func begin(now: TimeInterval) { mood = .listening; clip = .popIn; startedAt = now; voice = 0 }

    mutating func set(_ mood: Mood, now: TimeInterval) {
        guard mood != self.mood else { return }
        self.mood = mood
        switch mood {
        case .listening: switchTo(voice > Self.loudAbove ? .listenLoud : .listenCalm, now: now, keepPhase: false)
        case .thinking: switchTo(.think, now: now, keepPhase: false)
        case .happy: switchTo(.happy, now: now, keepPhase: false)
        case .oops: switchTo(.oops, now: now, keepPhase: false)
        case .shrug: switchTo(.shrug, now: now, keepPhase: false)
        }
    }

    // `level` is the raw microphone level; speech is quiet, so it is lifted like the bars.
    mutating func hear(_ level: Float, now: TimeInterval) {
        let lifted = min(1, sqrt(CGFloat(max(0, level))) * 1.8)
        voice += (lifted - voice) * 0.25
        guard mood == .listening, clip != .popIn else { return }
        if clip == .listenCalm, voice > Self.loudAbove { switchTo(.listenLoud, now: now, keepPhase: true) }
        else if clip == .listenLoud, voice < Self.calmBelow { switchTo(.listenCalm, now: now, keepPhase: true) }
    }

    // The frame to draw. One-shot clips hold their last frame; the pop-in hands over to listening.
    mutating func frame(now: TimeInterval, count: (KoaClip) -> Int) -> (clip: KoaClip, index: Int) {
        var frames = max(1, count(clip))
        var elapsed = Int(max(0, now - startedAt) * Self.fps)
        if clip == .popIn, elapsed >= frames {
            switchTo(mood == .thinking ? .think : voice > Self.loudAbove ? .listenLoud : .listenCalm,
                     now: startedAt + Double(frames) / Self.fps, keepPhase: false)
            frames = max(1, count(clip)); elapsed = Int(max(0, now - startedAt) * Self.fps)
        }
        return (clip, clip.loops ? elapsed % frames : min(elapsed, frames - 1))
    }

    // The two listening loops have the same length, so a swap keeps the frame and looks continuous.
    private mutating func switchTo(_ next: KoaClip, now: TimeInterval, keepPhase: Bool) {
        if !keepPhase { startedAt = now }
        clip = next
    }
}

// Small shifts inside Koa's reserved space. The clips have no walking feet or side views.
struct KoaMotion: Equatable {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var turn: CGFloat = 0

    static func pose(mood: KoaDirector.Mood, elapsed: TimeInterval, amount: CGFloat) -> Self {
        let t = max(0, elapsed)
        let strength = min(1, max(0, amount))
        let entrance = min(1, t / 0.5)
        switch mood {
        case .listening:
            let sway = sin(t * .pi / 3)
            return Self(x: 3 * sway * strength * entrance,
                        y: 0.8 * (1 - cos(t * .pi / 3)) * strength * entrance,
                        turn: -0.018 * sway * strength * entrance)
        case .thinking:
            return Self(x: 1.5 * sin(t * .pi / 4) * strength * entrance,
                        y: 0.6 * (1 - cos(t * .pi / 2)) * strength * entrance)
        case .happy, .oops, .shrug:
            return Self() // Let the one-shot reaction's rig do the work.
        }
    }
}

// Every clip decoded once into small frames, off the main thread. About 17 MB at 144 px.
final class KoaFrames: @unchecked Sendable {
    static let shared = KoaFrames()
    static let pixels = 144
    private let lock = NSLock()
    private var frames: [KoaClip: [CGImage]] = [:]
    private var loading: [KoaClip: (id: UUID, task: Task<[CGImage], Never>)] = [:]

    func images(_ clip: KoaClip) -> [CGImage] { lock.withLock { frames[clip] ?? [] } }
    var loaded: Bool { lock.withLock { frames.count == KoaClip.allCases.count } }

    // Loads from the app bundle's Koa folder, or any folder holding the same clips.
    func load(from folder: URL? = Bundle.main.resourceURL?.appendingPathComponent("Koa", isDirectory: true)) async {
        guard let folder else { return }
        for clip in KoaClip.allCases where images(clip).isEmpty {
            let job: (id: UUID, task: Task<[CGImage], Never>)? = lock.withLock {
                if frames[clip]?.count == clip.frameCount { return nil }
                if let existing = loading[clip] { return existing }
                let task = Task.detached { await Self.decode(folder.appendingPathComponent(clip.rawValue + ".mov")) }
                let job = (id: UUID(), task: task); loading[clip] = job; return job
            }
            guard let job else { continue }
            let decoded = await job.task.value
            lock.withLock {
                if loading[clip]?.id == job.id { loading.removeValue(forKey: clip) }
                if frames[clip] == nil, decoded.count == clip.frameCount { frames[clip] = decoded }
            }
        }
    }

    static func decode(_ url: URL) async -> [CGImage] {
        guard let clip = KoaClip(rawValue: url.deletingPathExtension().lastPathComponent) else { return [] }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds.isFinite,
              duration.seconds > 0, (duration.seconds * KoaDirector.fps).rounded() == Double(clip.frameCount) else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: pixels, height: pixels)
        let count = clip.frameCount
        var images: [CGImage] = []
        for index in 0..<count {
            guard !Task.isCancelled else { return [] }
            let time = CMTime(seconds: (Double(index) + 0.5) / KoaDirector.fps, preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image else { break }
            images.append(image)
        }
        return images
    }
}

// Rendered 3D poses retain their lighting; voice selects the calm or expressive rig loop.
@MainActor final class KoaView: NSView {
    private let sprite = CALayer()
    private let ground = CALayer()
    var motionAmount: CGFloat = 0.55
    private var director = KoaDirector()
    private var motionStartedAt: TimeInterval = 0
    private(set) var pose = KoaMotion()
    private let frames: KoaFrames
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private(set) var shown: (clip: KoaClip, index: Int)?

    init(frame: NSRect = .zero, frames: KoaFrames = .shared) {
        self.frames = frames
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        sprite.contentsGravity = .resizeAspect
        sprite.shadowColor = NSColor.black.cgColor
        sprite.shadowOpacity = 0.28
        sprite.shadowRadius = 6
        sprite.shadowOffset = CGSize(width: 0, height: -2)
        ground.backgroundColor = NSColor.black.withAlphaComponent(0.20).cgColor
        ground.shadowColor = NSColor.black.cgColor; ground.shadowOpacity = 0.25
        ground.shadowRadius = 5
        layer?.addSublayer(ground)
        layer?.addSublayer(sprite)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        let transform = sprite.transform
        sprite.transform = CATransform3DIdentity
        sprite.frame = NSRect(x: 4, y: 4, width: max(0, bounds.width - 8), height: max(0, bounds.height - 8))
        sprite.transform = transform
        ground.frame = NSRect(x: bounds.width * 0.27, y: bounds.height * 0.19, width: bounds.width * 0.46, height: bounds.height * 0.08)
        ground.cornerRadius = ground.bounds.height / 2

    }

    func begin(now: TimeInterval) { motionStartedAt = now; director.begin(now: now); advance(now: now) }
    func set(_ mood: KoaDirector.Mood, now: TimeInterval) {
        if director.mood != mood { motionStartedAt = now }
        director.set(mood, now: now); advance(now: now)
    }
    func hear(_ level: Float, now: TimeInterval) { director.hear(level * Float(max(0,motionAmount)), now: now) }

    // One display frame.
    func advance(now: TimeInterval) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let still = reduceMotion()
        if still {
            shown = (.listenCalm, 0)
        } else {
            shown = director.frame(now: now) { [frames] in frames.images($0).count }
        }
        if let shown, let image = frames.images(shown.clip).dropFirst(shown.index).first { sprite.contents = image }
        pose = still ? KoaMotion() : KoaMotion.pose(mood: director.mood,
            elapsed: now - motionStartedAt, amount: motionAmount)
        let translation = CATransform3DMakeTranslation(pose.x, pose.y, 0)
        sprite.transform = CATransform3DRotate(translation, pose.turn, 0, 0, 1)
    }
}
