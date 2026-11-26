import AppKit
import QuartzCore
import os

// Text-free popup trace: `log stream --predicate 'subsystem == "au.com.mykoala.mercurius" AND category == "pill"'`.
enum PillTrace { static let log = Logger(subsystem: "au.com.mykoala.mercurius", category: "pill") }
extension NSWindow {
    // A live panel can lose .canJoinAllSpaces in WindowServer and stay pinned to one desktop while AppKit
    // still calls it visible (seen 2026-11-09: Space [3] while on Space 31). Ordering it in again never
    // brings it back; clearing the behaviour and restoring it on a later main-queue turn does (restoring
    // in the same turn does nothing). Takes the behaviour as a value: a second call during the turn would
    // otherwise read the cleared one.
    func orderInOnActiveSpace(behavior: NSWindow.CollectionBehavior) {
        orderFrontRegardless()
        guard !isOnActiveSpace else { return }
        PillTrace.log.notice("window off the active Space, rejoining all Spaces")
        collectionBehavior = []
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            collectionBehavior = behavior
            if isVisible { orderFrontRegardless() }
        }
    }
}
struct PillVisibility: Equatable, CustomStringConvertible {
    let isVisible, onActiveSpace, onScreen, occlusionVisible: Bool
    let frame: CGRect
    let alpha: CGFloat
    let above: [String]
    var description: String {
        "visible=\(isVisible) space=\(onActiveSpace) onScreen=\(onScreen) occlusionVisible=\(occlusionVisible) "
            + "frame=\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height)) "
            + "alpha=\(String(format: "%.2f", alpha)) above=\(above)"
    }
}

// The dictation indicator at the bottom of the screen: a compact dark capsule with
// Koa (Koa.swift), who listens, thinks and then says the result, the voice as bars,
// and above it, only once words are heard, a small chat bubble with the live words.
// It never takes focus, so text still lands in the app you were typing in.
@MainActor final class PillPanel: NSPanel {
    var clicked: (() -> Void)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func mouseDown(with event: NSEvent) { clicked?() }
}

// The voice as thin bars that enter on the right and scroll left, fading out at both
// edges. Levels arrive 20 times a second and each bar eases to its own, so the motion
// stays smooth. While the text is made the bars melt into a slow rolling wave.
// Adapted from ElevenLabs UI LiveWaveform (MIT).
@MainActor final class Waveform: NSView {
    nonisolated static let barWidth: CGFloat = 3, barGap: CGFloat = 1, fadeWidth: CGFloat = 24
    private var target: [CGFloat] = []   // newest last
    private var shown: [CGFloat] = []
    private var live: [CGFloat] = []     // the bars when thinking began; the wave grows out of them
    private var time: CGFloat = 0, blend: CGFloat = 0
    var thinking = false {
        didSet { guard thinking != oldValue else { return }; live = shown; time = 0; blend = 0; needsDisplay = true }
    }
    var color = RecordingPill.accent
    var currentVoiceLevel: CGFloat { shown.reduce(0, +) / CGFloat(max(1, shown.count)) }
    var barCount: Int { Self.barCount(width: bounds.width) }

    nonisolated static func barCount(width: CGFloat) -> Int { max(1, Int((width + barGap) / (barWidth + barGap))) }
    // Speech RMS is small; lift it so normal talking fills most of the height.
    nonisolated static func level(_ rms: Float) -> CGFloat { min(1, max(0.05, sqrt(CGFloat(max(0, rms))) * 1.8)) }
    nonisolated static func processingBars(count: Int, time: CGFloat) -> [CGFloat] {
        (0..<count).map { index in
            let i = CGFloat(index), half = CGFloat(count) / 2
            let position = (i - half) / max(1, half)
            let wave = 0.25 * sin(time * 1.5 + i * 0.15) + 0.2 * sin(time * 0.8 - i * 0.1) + 0.15 * cos(time * 2 + i * 0.05)
            return min(1, max(0.05, (0.2 + wave) * (1 - abs(position) * 0.4)))
        }
    }
    // 0 at either edge, 1 once a bar is fadeWidth in (at most 30 % of the width).
    nonisolated static func fade(x: CGFloat, width: CGFloat) -> CGFloat {
        let ramp = min(fadeWidth, width * 0.3)
        guard ramp > 0 else { return 1 }
        return min(1, max(0, min(x, width - x) / ramp))
    }

    func push(_ level: Float) {
        target.append(Self.level(level)); shown.append(shown.last ?? 0.05)
        let extra = target.count - barCount
        if extra > 0 { target.removeFirst(extra); shown.removeFirst(extra) }
    }
    // One display frame (30 a second): ease every bar towards its level, or roll the wave.
    func frame() {
        // The original steps 0.03 and 0.02 per 60 fps frame; doubled for 30 fps.
        if thinking { time += 0.06; blend = min(1, blend + 0.04) }
        for index in shown.indices { shown[index] += (target[index] - shown[index]) * 0.32 }
        needsDisplay = true
    }
    func settle() { shown = target; blend = 1; needsDisplay = true }   // for snapshots
    func reset() { target = []; shown = []; live = []; time = 0; blend = 0; needsDisplay = true }
    // What draw() paints, left to right, and where the first bar starts.
    func bars() -> (values: [CGFloat], start: CGFloat) {
        let step = Self.barWidth + Self.barGap
        guard thinking else { return (shown, bounds.width - CGFloat(shown.count) * step + Self.barGap) }
        let count = barCount, wave = Self.processingBars(count: count, time: time)
        guard !live.isEmpty, blend < 1 else { return (wave, 0) }
        return (wave.indices.map { live[min(live.count - 1, $0 * live.count / count)] * (1 - blend) + wave[$0] * blend }, 0)
    }
    override func draw(_ dirtyRect: NSRect) {
        let (values, start) = bars()
        for (index, value) in values.enumerated() {
            let x = start + CGFloat(index) * (Self.barWidth + Self.barGap)
            let alpha = (0.4 + value * 0.6) * Self.fade(x: x + Self.barWidth / 2, width: bounds.width)
            guard alpha > 0 else { continue }
            let height = max(4, value * bounds.height * 0.8)
            color.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: (bounds.height - height) / 2, width: Self.barWidth, height: height),
                         xRadius: Self.barWidth / 2, yRadius: Self.barWidth / 2).fill()
        }
    }
}

// Koa's thought while the text is made: two small puffs rising from his head and a cloud
// with three accent dots that bounce in turn. Still under Reduce Motion.
@MainActor final class ThinkingCloud: NSView {
    static let size = NSSize(width: 80, height: 42)
    private let dots = (0..<3).map { _ in CALayer() }
    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        let fill = NSColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 0.92).cgColor
        let edge = NSColor.white.withAlphaComponent(0.14).cgColor
        for (rect, radius) in [(CGRect(x: 2, y: 2, width: 6, height: 6), 3.0), (CGRect(x: 10, y: 9, width: 9, height: 9), 4.5),
                               (CGRect(x: 18, y: 15, width: 60, height: 26), 13.0)] {
            let puff = CALayer()
            puff.frame = rect; puff.cornerRadius = radius; puff.cornerCurve = .continuous
            puff.backgroundColor = fill; puff.borderWidth = 0.5; puff.borderColor = edge
            layer?.addSublayer(puff)
        }
        for (index, dot) in dots.enumerated() {
            dot.frame = CGRect(x: 48 - 3.5 + CGFloat(index - 1) * 13, y: 28 - 3.5, width: 7, height: 7)
            dot.cornerRadius = 3.5
            layer?.addSublayer(dot)
        }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    var color = RecordingPill.accent { didSet { for dot in dots { dot.backgroundColor = color.cgColor } } }
    func start(moving: Bool) {
        for dot in dots { dot.backgroundColor = color.cgColor; dot.removeAllAnimations() }
        guard moving else { return }
        let now = CACurrentMediaTime()
        for (index, dot) in dots.enumerated() {
            let bounce = CAKeyframeAnimation(keyPath: "transform.translation.y")
            bounce.values = [0, 4, 0, 0]; bounce.keyTimes = [0, 0.2, 0.4, 1]
            bounce.duration = 1.1; bounce.repeatCount = .infinity
            bounce.beginTime = now + Double(index) * 0.16
            bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(bounce, forKey: "bounce")
        }
        let entry = CABasicAnimation(keyPath: "opacity")
        entry.fromValue = 0; entry.toValue = 1; entry.duration = 0.22
        layer?.add(entry, forKey: "entry")
    }
    func stop() { layer?.removeAllAnimations(); for dot in dots { dot.removeAllAnimations() } }
    var isMoving: Bool { dots.contains { $0.animation(forKey: "bounce") != nil } }   // tests
}

@MainActor final class RecordingPill {
    var clicked: (() -> Void)? { didSet { panel.clicked = clicked } }
    // Which engine makes the final text; shown as the capsule's tooltip, not on screen.
    var engine = "" { didSet { capsule.toolTip = engine.isEmpty ? nil : "Mercurius · \(engine)" } }
    let panel: PillPanel
    private let root = NSView()
    private let capsule = NSView()
    private let bubble = NSView()
    private let koa = KoaView()
    private let wave = Waveform()
    private let cloud = ThinkingCloud()
    // A soft accent light that runs along the capsule's edge while the text is made.
    private let shimmer = CAGradientLayer()
    let celebration = Celebration()
    private let result = NSTextField(labelWithString: "")
    private let words = NSTextField(wrappingLabelWithString: "")
    private var animator: Timer?
    private var hideAt: TimeInterval?
    private var fading = false
    static let spaces: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    private var stillMotion = false
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var motionReduced: Bool { stillMotion || reduceMotion() }
    private var successCelebrated = false
    private var bubbleShown = false
    private(set) var isAnimating = false
    var bubbleFrame: NSRect { bubble.frame }
    var capsuleFrame: NSRect { capsule.frame }
    private var targetFrame: NSRect?
    // The empty room left of the capsule that balances the bubble on its right.
    private var overhang: CGFloat = 0
    // The text cursor's line on screen (Cocoa coordinates). nil: the popup sits bottom-centre.
    var anchor: NSRect? { didSet { if content != nil, anchor != oldValue { layout() } } }
    private(set) var content: PillContent?
    var thinkingCloudVisible: Bool { !cloud.isHidden }   // tests
    var thinkingCloudMoving: Bool { cloud.isMoving }     // tests
    var shimmering: Bool { shimmer.animation(forKey: "run") != nil }   // tests
    var mascotVisible: Bool { !capsule.isHidden && !koa.isHidden }   // tests
    var waveformVisible: Bool { !capsule.isHidden && !wave.isHidden }
    // The live words while listening; they leave the screen at release.
    private var spoken: (settled: String, volatile: String) = ("", "")
    // A failure too long for the capsule: the capsule says so briefly and this wraps in the bubble above.
    private var detail = ""
    private var previewNotice = ""
    var shownPreview: String { words.stringValue }
    // Koa says the result: it types out at about 60 characters a second.
    private var said = ""
    private var saidFrom: TimeInterval = 0

    static private(set) var accent = PillStyle.current.theme.color
    static let accentDeep = NSColor(srgbRed: 0.49, green: 0.88, blue: 0.80, alpha: 1)  // teal, used by the clip card
    static let capsuleHeight: CGFloat = 58
    // Koa sits on the pill: its head rises above the capsule's top edge.
    static let koaSize: CGFloat = 104
    static let koaOverflow: CGFloat = 48
    static let listeningWidth: CGFloat = 248
    static let bubbleMaxWidth: CGFloat = 380
    static let bubblePadding = NSEdgeInsets(top: 9, left: 13, bottom: 9, right: 13)
    static let gap: CGFloat = 8
    // Where the bubble starts, measured from the capsule's left edge: just past Koa's head.
    static let koaBeside: CGFloat = 96
    // Room the thought cloud needs above Koa's head.
    static let cloudRise: CGFloat = 26
    // Below or above the text line, never on it.
    nonisolated static let anchorGap: CGFloat = 10
    // The tallest the popup gets: the capsule plus the thought cloud (132) or a three-line bubble beside Koa (~131).
    // Below the caret the capsule sits this far down, so the popup grows upward without ever reaching the line.
    nonisolated static let tallest: CGFloat = 136
    static let maxLines = 3
    static let textFont = NSFont.systemFont(ofSize: 13.5, weight: .medium)
    static var textWidth: CGFloat { bubbleMaxWidth - bubblePadding.left - bubblePadding.right }
    static let previewWidth = bubbleMaxWidth

    init() {
        panel = PillPanel(contentRect: NSRect(x: 0, y: 0, width: Self.listeningWidth, height: Self.capsuleHeight),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        // Joining Spaces alone does not opt a floating overlay into other apps'
        // full-screen and Stage Manager groups.
        panel.collectionBehavior = Self.spaces
        panel.contentView = root
        root.wantsLayer = true

        // Capsule: solid near-black, a hairline border and a soft shadow.
        capsule.wantsLayer = true
        capsule.layer?.backgroundColor = NSColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 0.96).cgColor
        capsule.layer?.cornerRadius = 15; capsule.layer?.cornerCurve = .continuous
        capsule.layer?.borderWidth = 0.5; capsule.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        capsule.layer?.shadowColor = NSColor.black.cgColor; capsule.layer?.shadowOpacity = 0.35
        capsule.layer?.shadowRadius = 10; capsule.layer?.shadowOffset = CGSize(width: 0, height: -3)
        result.font = .systemFont(ofSize: 13.5, weight: .semibold); result.textColor = .white
        result.lineBreakMode = .byTruncatingTail
        for view in [koa, wave, result] { capsule.addSubview(view) }
        capsule.clipsToBounds = false   // Koa's head rises above the capsule

        // Bubble: near-opaque dark above the capsule, live words wrapping to three lines.
        // Blurred glass let busy windows show through and made the words hard to read.
        bubble.wantsLayer = true
        bubble.layer?.backgroundColor = NSColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 0.92).cgColor
        bubble.layer?.cornerRadius = 14; bubble.layer?.cornerCurve = .continuous
        bubble.layer?.masksToBounds = true
        bubble.layer?.borderWidth = 0.5; bubble.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        words.font = Self.textFont; words.maximumNumberOfLines = Self.maxLines
        words.lineBreakMode = .byWordWrapping; words.preferredMaxLayoutWidth = Self.textWidth
        bubble.addSubview(words)
        root.addSubview(bubble); root.addSubview(capsule); root.addSubview(cloud)
        bubble.isHidden = true; cloud.isHidden = true
        let edge = CAShapeLayer()
        edge.fillColor = nil; edge.strokeColor = NSColor.black.cgColor; edge.lineWidth = 1.5
        shimmer.mask = edge
        shimmer.startPoint = CGPoint(x: 0, y: 0.5); shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.locations = [-0.3, -0.15, 0]
        shimmer.isHidden = true
        capsule.layer?.insertSublayer(shimmer, at: 0)
        koa.reduceMotion = { [weak self] in self?.motionReduced ?? true }
        celebration.reduceMotion = { [weak self] in self?.motionReduced ?? true }
        capsule.setAccessibilityElement(true); capsule.setAccessibilityLabel("Mercurius dictation status")
    }

    func applyAppearance() {
        let style = PillStyle.current
        Self.accent = style.theme.color
        stillMotion = style.motion == .still
        wave.color = style.theme.color
        cloud.color = style.theme.color
        koa.motionAmount = style.motion.amount
        koa.reduceMotion = { [weak self] in self?.motionReduced ?? true }
        celebration.reduceMotion = { [weak self] in self?.motionReduced ?? true }
        if motionReduced { stopEffects() }
        koa.advance(now: ProcessInfo.processInfo.systemUptime)
    }

    // Shows a state. Results disappear on their own; active states stay until
    // the controller moves on.
    func show(_ value: PillContent, now: TimeInterval) {
        let changed = content != value
        let fresh = content == nil || (changed && value == .starting)
        if changed {
            if content == nil || (!value.isTerminal && content?.isTerminal == true) || value == .starting {
                successCelebrated = false
                celebration.stop()
            }
            if value == .starting || content == nil { koa.begin(now: now) }
            content = value
            apply(value)
            koa.set(Self.mood(value), now: now)
            saidFrom = now
            switch value {
            case .done, .delivered:
                if !successCelebrated { successCelebrated = true; celebrate(.success) }
            case .failed, .blockedDelivery: celebrate(.failure)
            default: break
            }
        }
        if changed {
            switch value {
            case let .done(text): hideAt = now + max(2.2, Double(text.count) / 60 + 1.5)
            // A paste is a quick "✓ Inserted" and gone; a note to act on stays long enough to read.
            case let .delivered(status, _):
                let label = Self.insertedLabel(status)
                hideAt = now + (label.needsReading ? max(2.2, Double(label.text.count) / 15) : 1.0)
            // Long enough to read: about 15 characters a second, 3.5 to 9 seconds.
            case .blockedDelivery: hideAt = now + 9
            case let .failed(text): hideAt = now + min(9, max(3.5, Double(text.count) / 15))
            default: hideAt = nil
            }
        }
        // A disconnected display or restored window frame can leave an active
        // popup outside every visible screen even while its content is unchanged.
        if !NSScreen.screens.isEmpty,
           !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            layout()
        }
        // After sleep, wake or a Space change AppKit can still call the panel visible
        // while WindowServer has dropped it, so every new session orders it in again.
        if !panel.isVisible || fresh || !panel.isOnActiveSpace {
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderInOnActiveSpace(behavior: Self.spaces)
        }
        if fresh { confirmOnScreen() }
        // Also cancels a fade-out still running from the last result.
        if fading {
            // An animated fade-in does not replace the fade-out still running, which then
            // finishes at 0, so a stopped fade jumps straight back to full opacity.
            fading = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0; panel.animator().alphaValue = 1
            }
            panel.alphaValue = 1
        } else if panel.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = motionReduced ? 0 : 0.16; panel.animator().alphaValue = 1
            }
        }
        startAnimating()
    }
    // Confetti from behind Koa for a result; a grey puff and a small shake for a failure.
    private func celebrate(_ kind: Celebration.Kind) {
        let frame = targetFrame ?? panel.frame
        let center = NSPoint(x: frame.minX + capsule.frame.minX + koa.frame.midX, y: frame.minY + capsule.frame.minY + koa.frame.midY)
        guard celebration.play(kind, koa: center), kind == .failure else { return }
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -6, 6, -4, 4, -2, 0]
        shake.duration = 0.4
        capsule.layer?.add(shake, forKey: "shake")
    }
    func level(_ value: Float) {
        guard content == .listening || content == .starting else { return }
        wave.push(value); koa.hear(value, now: ProcessInfo.processInfo.systemUptime)
    }
    // Koa's words so far, at about 60 characters a second. A late or skipped frame jumps ahead,
    // and once enough time has passed the whole text shows, never a stuck prefix.
    nonisolated static func typed(_ text: String, elapsed: TimeInterval) -> String {
        let count = Int(max(0, elapsed) * 60)
        return count >= text.count ? text : String(text.prefix(count))
    }
    // What Koa does for each state. Nothing heard is a shrug; anything else that failed is an oops.
    nonisolated static func mood(_ content: PillContent) -> KoaDirector.Mood {
        switch content {
        case .starting, .listening: return .listening
        case .transcribing, .busy: return .thinking
        case .done, .delivered: return .happy
        case .blockedDelivery: return .oops
        case let .failed(text):
            let lowered = text.lowercased()
            return ["too short", "no speech", "nothing", "didn't hear", "silence"].contains(where: lowered.contains) ? .shrug : .oops
        }
    }
    // Words heard so far: settled ones bright, ones still changing dimmer.
    func preview(settled: String, volatile: String, unavailable: LivePreview.Unavailable? = nil) {
        guard content == .listening || content == .starting else { return }
        // The preview ending (on release) sends nothing new; the words leave when the text is made (apply(.transcribing)).
        if settled.isEmpty && volatile.isEmpty && unavailable == nil { return }
        spoken = (settled, volatile)
        previewNotice = unavailable?.message ?? ""
        layout()
    }
    func tick(now: TimeInterval) {
        if let hideAt, now >= hideAt { hide() }
    }
    func hide(caller: StaticString = #fileID, line: Int = #line) {
        // Only a hide that removes something: Secure Input calls this on every poll while a screen is locked.
        if content != nil { PillTrace.log.notice("hide from \(caller, privacy: .public):\(line, privacy: .public)") }
        hideAt = nil; content = nil; spoken = ("", ""); said = ""; detail = ""; previewNotice = ""; anchor = nil
        onScreenCheck?.cancel(); onScreenCheck = nil
        // Dictated text leaves the screen and the accessibility tree with the card.
        words.stringValue = ""; result.stringValue = ""; capsule.setAccessibilityValue(nil); bubble.setAccessibilityValue(nil)
        stopAnimating()
        // The confetti finishes on its own (about a second) after a quick result has gone.
        stopEffects(keepConfetti: true)
        bubbleShown = false
        bubble.isHidden = true; cloud.isHidden = true
        guard panel.isVisible else { wave.reset(); return }
        fading = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = motionReduced ? 0 : 0.2; panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.content == nil, self.fading else { return }
                self.fading = false; self.panel.orderOut(nil); self.wave.reset()
            }
        })
    }
    // After wake, a display change or a Space switch: an idle panel leaves the window list
    // so the next show orders it in from scratch; an active one is laid out and ordered in again.
    func reattach() {
        guard content != nil else {
            fading = false; panel.orderOut(nil); panel.alphaValue = 0; wave.reset()
            return
        }
        // Measure a result Koa is still typing with its whole text, then put back what he has said so far.
        let typed = result.stringValue
        if !result.isHidden { result.stringValue = said }
        layout()
        result.stringValue = typed
        panel.orderInOnActiveSpace(behavior: Self.spaces)
    }
    func visibilityReport() -> PillVisibility {
        PillVisibility(isVisible: panel.isVisible, onActiveSpace: panel.isOnActiveSpace, onScreen: Self.isOnScreen(panel),
                       occlusionVisible: panel.occlusionState.contains(.visible), frame: panel.frame,
                       alpha: panel.alphaValue, above: Self.windowsAbove(panel))
    }
    // Owner and layer of on-screen windows in front of the panel and overlapping it. Names of apps only, never titles.
    private static func windowsAbove(_ panel: NSWindow) -> [String] {
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        guard let index = windows.firstIndex(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == panel.windowNumber }) else { return [] }
        let top = (NSScreen.screens.first?.frame.height ?? 0) - panel.frame.maxY
        let mine = CGRect(x: panel.frame.minX, y: top, width: panel.frame.width, height: panel.frame.height)
        return windows[..<index].compactMap { window in
            guard let bounds = (window[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  bounds.intersects(mine) else { return nil }
            return "\(window[kCGWindowOwnerName as String] as? String ?? "?")@\((window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1)"
        }
    }
    // Whether WindowServer lists the panel on screen; AppKit's isVisible can disagree.
    static func isOnScreen(_ panel: NSWindow) -> Bool {
        guard panel.windowNumber > 0 else { return false }
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains {
            ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == panel.windowNumber
                && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier
        }
    }
    // Shortly after a session starts, checks the panel really reached the screen and orders it in once more if not.
    private var onScreenCheck: Task<Void, Never>?
    private func confirmOnScreen() {
        onScreenCheck?.cancel()
        onScreenCheck = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, self.content != nil, !self.fading, !Self.isOnScreen(self.panel) else { return }
            self.panel.orderOut(nil)
            self.panel.orderInOnActiveSpace(behavior: Self.spaces)
        }
    }
    // Draws the final frame without waiting for animation (offscreen renders).
    func settleForSnapshot() {
        wave.settle(); result.stringValue = said; koa.advance(now: saidFrom + 10)
        if let targetFrame { panel.setFrame(targetFrame, display: true) }
    }

    private func apply(_ value: PillContent) {
        detail = ""
        switch value {
        case .starting, .listening:
            if value == .starting { spoken = ("", ""); previewNotice = ""; wave.reset() }
            wave.thinking = false
            capsule.setAccessibilityValue(value == .starting ? "Starting" : "Listening")
        case .transcribing:
            // The words leave the screen and the accessibility tree at release; Koa thinks instead.
            spoken = ("", ""); previewNotice = ""; words.stringValue = ""; bubble.setAccessibilityValue(nil)
            wave.thinking = true
            capsule.setAccessibilityValue("Processing")
        case let .done(text):
            spoken = ("", "")
            result.stringValue = text
            capsule.setAccessibilityValue(text)
        case let .delivered(status, _):
            // No transcript here: it is in Activity. A long note wraps in the bubble instead.
            spoken = ("", "")
            let label = Self.insertedLabel(status).text
            result.stringValue = label
            if ceil(result.intrinsicContentSize.width) > Self.bubbleMaxWidth - Self.koaSize - 26 {
                detail = label; result.stringValue = Self.inserted
            }
            capsule.setAccessibilityValue(label)
        case let .busy(text):
            spoken = ("", "")
            result.stringValue = text
            capsule.setAccessibilityValue(text)
        case let .failed(text): applyFailure(text)
        case .blockedDelivery: applyFailure(PillDisplay.blockedMessage)
        }
        layout()
        // Measured with the whole text; Koa then types it out from the start.
        said = result.stringValue
        result.stringValue = ""
    }

    static let inserted = "✓ Inserted"
    // A paste's capsule line: "✓ Inserted", plus only the notes the user should act on.
    nonisolated static func insertedLabel(_ status: String) -> (text: String, needsReading: Bool) {
        let notes = status.components(separatedBy: " · ").dropFirst()
            .filter { $0.hasPrefix("not cleaned") || $0.contains("Grok is off") }
        return notes.isEmpty ? ("✓ Inserted", false) : ((["✓ Inserted"] + notes).joined(separator: " · "), true)
    }

    private func applyFailure(_ text: String) {
        spoken = ("", "")
        result.stringValue = text
        if ceil(result.intrinsicContentSize.width) > Self.bubbleMaxWidth - Self.koaSize - 26 {
            detail = text; result.stringValue = "Needs your attention"
        }
        capsule.setAccessibilityValue(text)
    }

    // Lays out the capsule (bottom) and the bubble (beside Koa's head, when there are words),
    // then sizes the panel around them.
    private func layout() {
        let finished: Bool = {
            switch content { case .done, .delivered, .failed, .blockedDelivery, .busy: return true; default: return false }
        }()
        wave.isHidden = finished; result.isHidden = !finished
        // Capsule.
        let capsuleWidth: CGFloat
        // Koa sits at the left in every state; the bars, dots or Koa's words fill the rest.
        let textStart = Self.koaSize + 6
        koa.frame = NSRect(x: 2, y: Self.capsuleHeight + Self.koaOverflow - Self.koaSize, width: Self.koaSize, height: Self.koaSize)
        if finished {
            // A label needs a little more than its text's width, or the last word truncates.
            let textWidth = min(Self.bubbleMaxWidth - textStart - 16, ceil(result.intrinsicContentSize.width) + 4)
            capsuleWidth = max(Self.listeningWidth, textWidth + textStart + 16)
            result.frame = NSRect(x: textStart, y: (Self.capsuleHeight - 18) / 2 - 1, width: textWidth, height: 19)
        } else {
            capsuleWidth = Self.listeningWidth
            wave.frame = NSRect(x: textStart, y: (Self.capsuleHeight - 22) / 2, width: capsuleWidth - textStart - 16, height: 22)
        }
        // Koa's thought cloud and the edge light while the text is made.
        let thinking = content == .transcribing
        let cloudEntering = thinking && cloud.isHidden
        cloud.isHidden = !thinking
        if cloudEntering { cloud.start(moving: !motionReduced) } else if !thinking { cloud.stop() }
        updateShimmer(on: thinking && !motionReduced, width: capsuleWidth)
        // Bubble.
        let liveText = spokenText()
        let previewText = liveText.length == 0 && !previewNotice.isEmpty
            ? NSAttributedString(string: previewNotice, attributes: [.foregroundColor: NSColor.white, .font: Self.textFont]) : liveText
        let text = !finished ? previewText
            : detail.isEmpty ? NSAttributedString()
            : NSAttributedString(string: detail, attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.95), .font: Self.textFont])
        let showBubble = text.length > 0
        let entering = showBubble && !bubbleShown
        bubbleShown = showBubble
        bubble.isHidden = !showBubble
        var bubbleSize = NSSize.zero
        if showBubble {
            // Live words show their newest lines; terminal details read from the start.
            let fitted = detail.isEmpty || !finished ? Self.lastLines(text) : Self.firstLines(text)
            words.attributedStringValue = fitted
            let size = Self.measure(fitted)
            bubbleSize = NSSize(width: Self.bubbleMaxWidth,
                                height: Self.lineHeight * CGFloat(Self.maxLines) + Self.bubblePadding.top + Self.bubblePadding.bottom)
            words.frame = NSRect(x: Self.bubblePadding.left, y: bubbleSize.height - Self.bubblePadding.top - size.height,
                                 width: Self.textWidth, height: size.height)
        }
        // The bubble sits to Koa's right, just above the capsule, so it never covers him.
        // The panel keeps room for it on both sides, so the capsule stays centred and never jumps when words appear.
        overhang = max(0, Self.koaBeside + Self.bubbleMaxWidth - capsuleWidth)
        let width = capsuleWidth + 2 * overhang
        let height = Self.capsuleHeight + max(Self.koaOverflow + (thinking ? Self.cloudRise : 0),
                                              showBubble ? Self.gap / 2 + bubbleSize.height : 0)
        capsule.frame = NSRect(x: overhang, y: 0, width: capsuleWidth, height: Self.capsuleHeight)
        cloud.frame = NSRect(origin: NSPoint(x: capsule.frame.minX + 64, y: Self.capsuleHeight + Self.koaOverflow - 16),
                             size: ThinkingCloud.size)
        bubble.frame = NSRect(x: capsule.frame.minX + Self.koaBeside, y: Self.capsuleHeight + Self.gap / 2,
                              width: bubbleSize.width, height: bubbleSize.height)
        resize(NSSize(width: width, height: height))
        if entering && !motionReduced {
            let entry = CABasicAnimation(keyPath: "opacity")
            entry.fromValue = 0; entry.toValue = 1; entry.duration = 0.16
            bubble.layer?.add(entry, forKey: "entry")
        }
    }
    private func spokenText() -> NSAttributedString {
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: spoken.settled, attributes:
            [.foregroundColor: NSColor.white.withAlphaComponent(0.95), .font: Self.textFont]))
        if !spoken.volatile.isEmpty {
            text.append(NSAttributedString(string: (spoken.settled.isEmpty ? "" : " ") + spoken.volatile, attributes:
                [.foregroundColor: Self.accent.withAlphaComponent(0.8), .font: Self.textFont]))
        }
        return text
    }
    private func updateShimmer(on: Bool, width: CGFloat) {
        guard on else { shimmer.removeAllAnimations(); shimmer.isHidden = true; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shimmer.frame = CGRect(x: 0, y: 0, width: width, height: Self.capsuleHeight)
        (shimmer.mask as? CAShapeLayer)?.path = CGPath(roundedRect: shimmer.bounds.insetBy(dx: 0.75, dy: 0.75),
                                                        cornerWidth: 14.25, cornerHeight: 14.25, transform: nil)
        shimmer.colors = [NSColor.clear.cgColor, Self.accent.withAlphaComponent(0.9).cgColor, NSColor.clear.cgColor]
        shimmer.isHidden = false
        CATransaction.commit()
        guard shimmer.animation(forKey: "run") == nil else { return }
        let run = CABasicAnimation(keyPath: "locations")
        run.fromValue = [-0.3, -0.15, 0]; run.toValue = [1, 1.15, 1.3]
        run.duration = 1.4; run.repeatCount = .infinity
        shimmer.add(run, forKey: "run")
    }

    // The tail of the text that fits in three lines, starting at a word.
    static func lastLines(_ text: NSAttributedString) -> NSAttributedString {
        var start = 0
        let string = text.string as NSString
        let limit = lineHeight * CGFloat(maxLines) + 1
        while start < string.length, measure(text.attributedSubstring(from: NSRange(location: start,
                length: string.length - start))).height > limit {
            let next = string.range(of: " ", range: NSRange(location: start, length: string.length - start))
            // No space left (unspaced scripts, one long token): step by whole characters instead.
            // Always moves forward, even past a long cluster of combining marks.
            start = next.location == NSNotFound
                ? max(start + 1, NSMaxRange(string.rangeOfComposedCharacterSequence(at: min(start + 8, string.length - 1))))
                : next.location + 1
            if next.location == NSNotFound && start >= string.length - 1 { break }
        }
        let tail = text.attributedSubstring(from: NSRange(location: start, length: string.length - start))
        guard start > 0, tail.length > 0 else { return tail }
        let shown = NSMutableAttributedString(string: "… ", attributes: tail.attributes(at: 0, effectiveRange: nil))
        shown.append(tail)
        return measure(shown).height > limit ? tail : shown
    }
    // The start of the text that fits in three lines, ending at a word with "…".
    static func firstLines(_ text: NSAttributedString) -> NSAttributedString {
        let limit = lineHeight * CGFloat(maxLines) + 1
        guard measure(text).height > limit else { return text }
        let attributes = text.attributes(at: 0, effectiveRange: nil)
        var words = text.string.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        while words.count > 1 {
            words.removeLast()
            let shown = NSAttributedString(string: words.joined(separator: " ") + "…", attributes: attributes)
            if measure(shown).height <= limit { return shown }
        }
        return NSAttributedString(string: String(text.string.prefix(80)) + "…", attributes: attributes)
    }
    // Measured the way the label lays text out, so "fits in three lines" agrees with what shows.
    private static let measurer: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = textFont; field.lineBreakMode = .byWordWrapping
        return field
    }()
    static var lineHeight: CGFloat { measure(NSAttributedString(string: "Ag", attributes: [.font: textFont])).height }
    // The text's size when wrapped to the bubble: as narrow as a short line needs, three lines at most.
    static func measure(_ text: NSAttributedString) -> NSSize {
        measurer.attributedStringValue = text
        let size = measurer.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 10_000)) ?? .zero
        measurer.stringValue = ""   // no copy of the dictation stays behind
        return NSSize(width: min(textWidth, ceil(size.width)), height: ceil(size.height))
    }

    // The panel keeps its bottom edge and grows upward. Only content opacity animates.
    private func resize(_ size: NSSize) {
        let frame = NSRect(origin: origin(for: size), size: size)
        targetFrame = frame
        guard panel.frame != frame else { return }
        // Commit geometry before fading the bubble in, so the window never clips its new content.
        panel.setFrame(frame, display: true)
    }
    private func origin(for size: NSSize) -> NSPoint {
        let point = anchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return panel.frame.origin }
        return Self.origin(for: size, anchor: anchor, area: area, leftSlack: overhang)
    }
    // Centred on the caret, below its line with the capsule's bottom fixed, so the popup grows upward and never
    // jumps or reaches the line; above the line when the tallest popup wouldn't fit below. No caret, or one scrolled
    // out of sight: bottom-centre of the screen. leftSlack: empty room at the panel's left that may hang off the screen.
    nonisolated static func origin(for size: NSSize, anchor: NSRect?, area: NSRect, leftSlack: CGFloat = 0) -> NSPoint {
        guard let anchor, area.intersects(anchor) else {
            return NSPoint(x: (area.midX - size.width / 2).rounded(), y: area.minY + 18)
        }
        let x = min(max(anchor.midX - size.width / 2, area.minX + 8 - leftSlack), area.maxX - size.width - 8)
        let below = anchor.minY - anchorGap - tallest
        let y = below >= area.minY + 8 ? below : anchor.maxY + anchorGap
        return NSPoint(x: x.rounded(), y: min(max(y, area.minY), area.maxY - size.height).rounded())
    }
    // AX reports screen rectangles from the primary display's top-left corner; Cocoa from its bottom-left.
    nonisolated static func cocoaRect(fromAX rect: CGRect, primaryTop: CGFloat) -> NSRect {
        NSRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    // 30 updates per second while visible; the source clips contain 24 frames per second.
    private func startAnimating() {
        guard animator == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.content != nil else { return }
                guard self.panel.isVisible else { self.stopAnimating(); self.stopEffects(); return }
                self.animationFrame(now: ProcessInfo.processInfo.systemUptime)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animator = timer
        isAnimating = true
    }
    private func stopAnimating() { animator?.invalidate(); animator = nil; isAnimating = false }
    private func stopEffects(keepConfetti: Bool = false) {
        if !keepConfetti { celebration.stop() }
        capsule.layer?.removeAllAnimations()
        bubble.layer?.removeAllAnimations()
        cloud.stop(); shimmer.removeAllAnimations(); shimmer.isHidden = true
    }
    // One frame: the bars or dots, Koa, and Koa saying the result a few characters at a time.
    func animationFrame(now: TimeInterval) {
        guard content != nil, panel.isVisible else { stopAnimating(); stopEffects(); return }
        if motionReduced { stopEffects(); wave.settle() } else { wave.frame() }
        koa.advance(now: now)
        let voiceGlow = (content == .listening || content == .starting) ? wave.currentVoiceLevel : 0
        if voiceGlow > 0.12 {
            capsule.layer?.borderColor = Self.accent.withAlphaComponent(0.18 + 0.35 * voiceGlow).cgColor
        } else {
            capsule.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        }
        if !result.isHidden, result.stringValue != said { result.stringValue = motionReduced ? said : Self.typed(said, elapsed: now - saidFrom) }
    }
    var shownResult: String { result.stringValue }   // what Koa has said so far (tests)
    var resultWidth: CGFloat { result.frame.width }   // tests
}
