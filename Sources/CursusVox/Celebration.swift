import AppKit
import QuartzCore

// A short burst around Koa when a dictation ends: orange, cream, gold, mint and eucalyptus
// confetti for a result, a small grey puff for a failure. It plays in its own transparent
// panel that ignores the mouse, so clicks reach the app underneath, and it does
// nothing at all when Reduce Motion is on.
@MainActor final class Celebration {
    enum Kind: Equatable { case success, failure }
    static let size = NSSize(width: 460, height: 340)
    // Where the particles start inside the panel: Koa's middle.
    static let origin = CGPoint(x: size.width / 2, y: 48)
    // A short pop that ends with the popup (about a second after a paste).
    static let burst: TimeInterval = 0.1
    static let duration: TimeInterval = 1.3
    var pouring: Bool { emitter.birthRate > 0 || emitter.animation(forKey: "burst") != nil }   // tests
    var burstLength: CFTimeInterval? { emitter.animation(forKey: "burst")?.duration }        // tests
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    let panel: NSPanel
    private let emitter = CAEmitterLayer()
    // A thin accent ring that pushes out behind Koa's head on a result.
    let ring = CAShapeLayer()
    private var play = 0
    private static let spaces: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    private(set) var playCount = 0

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = Self.spaces
        let view = NSView(frame: NSRect(origin: .zero, size: Self.size))
        view.wantsLayer = true
        emitter.frame = view.bounds
        emitter.emitterPosition = Self.origin
        emitter.emitterShape = .circle
        emitter.emitterSize = CGSize(width: 18, height: 10)
        ring.frame = CGRect(x: Self.origin.x - 30, y: Self.origin.y - 30, width: 60, height: 60)
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        ring.fillColor = nil; ring.lineWidth = 2.5; ring.opacity = 0
        view.layer?.addSublayer(ring)
        view.layer?.addSublayer(emitter)
        panel.contentView = view
    }

    // `koa` is Koa's middle on screen. Returns whether anything played.
    @discardableResult
    func play(_ kind: Kind, koa: NSPoint) -> Bool {
        guard !reduceMotion() else { stop(); return false }
        playCount += 1
        play += 1
        let current = play
        panel.setFrameOrigin(NSPoint(x: (koa.x - Self.origin.x).rounded(), y: (koa.y - Self.origin.y).rounded()))
        emitter.emitterCells = Self.cells(for: kind) + Self.extraCells(for: kind)
        emitter.beginTime = CACurrentMediaTime()
        // The burst ends inside Core Animation, so it stops even if the main actor never gets back
        // to it (a busy app, a test run): the confetti can never keep pouring.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        emitter.birthRate = 0
        CATransaction.commit()
        let pour = CABasicAnimation(keyPath: "birthRate")
        pour.fromValue = 1; pour.toValue = 1; pour.duration = Self.burst
        emitter.add(pour, forKey: "burst")
        ring.removeAllAnimations()
        if kind == .success {
            ring.strokeColor = RecordingPill.accent.cgColor
            let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 0.4; grow.toValue = 1.6
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0.85; fade.toValue = 0
            let wave = CAAnimationGroup(); wave.animations = [grow, fade]; wave.duration = 0.45
            wave.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(wave, forKey: "shockwave")
        }
        panel.orderInOnActiveSpace(behavior: Self.spaces)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.duration))
            guard let self, current == self.play else { return }
            self.panel.orderOut(nil)
            self.emitter.emitterCells = nil
        }
        return true
    }

    func stop() {
        play += 1
        emitter.removeAnimation(forKey: "burst")
        emitter.birthRate = 0
        ring.removeAllAnimations()
        emitter.emitterCells = nil
        panel.orderOut(nil)
    }

    nonisolated static func cells(for kind: Kind) -> [CAEmitterCell] {
        switch kind {
        case .success:
            let colors = [NSColor(srgbRed: 1, green: 0.55, blue: 0.33, alpha: 1),     // Koa orange
                          NSColor(srgbRed: 1, green: 0.93, blue: 0.82, alpha: 1),     // warm cream
                          NSColor(srgbRed: 0.49, green: 0.88, blue: 0.80, alpha: 1)]  // eucalyptus mint
            return colors.enumerated().map { index, color in
                let cell = CAEmitterCell()
                cell.contents = index == 1 ? star ?? piece : piece
                cell.color = color.cgColor
                cell.birthRate = 105
                cell.lifetime = 0.9; cell.lifetimeRange = 0.2
                cell.velocity = 270; cell.velocityRange = 100
                cell.emissionLongitude = .pi / 2; cell.emissionRange = .pi / 2.3   // upwards, fanned
                cell.yAcceleration = -560                                         // then falling
                cell.xAcceleration = index == 0 ? -18 : (index == 2 ? 18 : 0)
                cell.spin = 3.5; cell.spinRange = 9
                cell.scale = 0.58; cell.scaleRange = 0.26
                cell.alphaSpeed = -0.9
                return cell
            }
        case .failure:
            let cell = CAEmitterCell()
            cell.contents = dot
            cell.color = NSColor(srgbRed: 0.62, green: 0.62, blue: 0.66, alpha: 0.7).cgColor
            cell.birthRate = 45
            cell.lifetime = 0.7; cell.lifetimeRange = 0.2
            cell.velocity = 55; cell.velocityRange = 30
            cell.emissionRange = .pi * 2
            cell.scale = 0.35; cell.scaleSpeed = 0.5
            cell.alphaSpeed = -1.3
            return [cell]
        }
    }

    // Extra festive shapes (golden stars, eucalyptus leaves, coral ribbons) layered onto live bursts.
    nonisolated static func extraCells(for kind: Kind) -> [CAEmitterCell] {
        guard kind == .success else { return [] }
        let specs: [(CGImage?, NSColor, CGFloat, CGFloat)] = [
            (star, NSColor(srgbRed: 1.0, green: 0.80, blue: 0.28, alpha: 1), 245, 24),   // golden sparkle
            (leaf, NSColor(srgbRed: 0.38, green: 0.82, blue: 0.62, alpha: 1), 195, -24), // eucalyptus leaf
            (ribbon, NSColor(srgbRed: 1.0, green: 0.44, blue: 0.48, alpha: 1), 210, 12)  // warm coral ribbon
        ]
        return floaters() + [sparkle()] + specs.map { contents, color, velocity, drift in
            let cell = CAEmitterCell()
            cell.contents = contents ?? piece
            cell.color = color.cgColor
            cell.birthRate = 72
            cell.lifetime = 0.95; cell.lifetimeRange = 0.2
            cell.velocity = velocity * 1.15; cell.velocityRange = 85
            cell.emissionLongitude = .pi / 2; cell.emissionRange = .pi / 2.1
            cell.yAcceleration = -520
            cell.xAcceleration = drift
            cell.spin = 4.2; cell.spinRange = 10
            cell.scale = 0.56; cell.scaleRange = 0.24
            cell.scaleSpeed = -0.08
            cell.alphaSpeed = -0.85
            return cell
        }
    }

    // Golden sparkles close around Koa that swell and blink out, like a twinkle.
    nonisolated static func sparkle() -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = star ?? dot
        cell.color = NSColor(srgbRed: 1.0, green: 0.86, blue: 0.38, alpha: 1).cgColor
        cell.birthRate = 60
        cell.lifetime = 0.55; cell.lifetimeRange = 0.2
        cell.velocity = 120; cell.velocityRange = 80
        cell.emissionRange = .pi * 2
        cell.scale = 0.25; cell.scaleSpeed = 0.9
        cell.alphaRange = 0.4; cell.alphaSpeed = -1.7
        return cell
    }

    // A second, slower layer: big eucalyptus leaves and paper that rise high, then drift down past Koa
    // while the fast confetti has already fallen, so the burst has depth and a soft ending.
    nonisolated static func floaters() -> [CAEmitterCell] {
        let specs: [(CGImage?, NSColor, CGFloat)] = [
            (bigLeaf, NSColor(srgbRed: 0.42, green: 0.74, blue: 0.58, alpha: 1), -30),
            (bigLeaf, NSColor(srgbRed: 0.62, green: 0.84, blue: 0.70, alpha: 1), 30),
            (piece, NSColor(srgbRed: 1, green: 0.36, blue: 0.09, alpha: 1), 0)]   // Koa orange paper
        return specs.map { contents, color, drift in
            let cell = CAEmitterCell()
            cell.contents = contents ?? piece
            cell.color = color.cgColor
            cell.birthRate = 36
            cell.lifetime = 1.05; cell.lifetimeRange = 0.2
            cell.velocity = 330; cell.velocityRange = 70
            cell.emissionLongitude = .pi / 2; cell.emissionRange = .pi / 2.6
            cell.yAcceleration = -420
            cell.xAcceleration = drift
            cell.spin = 1.6; cell.spinRange = 3.5          // a slow flutter, not a spin
            cell.scale = 0.9; cell.scaleRange = 0.3
            cell.alphaSpeed = -0.8
            return cell
        }
    }
    nonisolated static let bigLeaf = image(size: CGSize(width: 22, height: 12)) { ctx in
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 0.5, y: 6))
        ctx.addQuadCurve(to: CGPoint(x: 21.5, y: 6), control: CGPoint(x: 11, y: 13))
        ctx.addQuadCurve(to: CGPoint(x: 0.5, y: 6), control: CGPoint(x: 11, y: -1))
        ctx.closePath(); ctx.fillPath()
    }

    // Confetti shapes drawn white so each cell's color tints them.
    nonisolated static let piece = image(size: CGSize(width: 10, height: 6)) {
        let path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 10, height: 6), cornerWidth: 2, cornerHeight: 2, transform: nil)
        $0.addPath(path); $0.fillPath()
    }
    nonisolated static let dot = image(size: CGSize(width: 16, height: 16)) {
        $0.fillEllipse(in: CGRect(x: 0, y: 0, width: 16, height: 16))
    }
    nonisolated static let star = image(size: CGSize(width: 14, height: 14)) { ctx in
        let center = CGPoint(x: 7, y: 7)
        ctx.beginPath()
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4
            let radius: CGFloat = i.isMultiple(of: 2) ? 6.8 : 2.5
            let pt = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if i == 0 { ctx.move(to: pt) } else { ctx.addLine(to: pt) }
        }
        ctx.closePath(); ctx.fillPath()
    }
    nonisolated static let leaf = image(size: CGSize(width: 12, height: 8)) { ctx in
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 0.5, y: 4))
        ctx.addQuadCurve(to: CGPoint(x: 11.5, y: 4), control: CGPoint(x: 6, y: 8))
        ctx.addQuadCurve(to: CGPoint(x: 0.5, y: 4), control: CGPoint(x: 6, y: 0))
        ctx.closePath(); ctx.fillPath()
    }
    nonisolated static let ribbon = image(size: CGSize(width: 14, height: 5)) { ctx in
        let path = CGPath(roundedRect: CGRect(x: 0, y: 0.5, width: 14, height: 4), cornerWidth: 2, cornerHeight: 2, transform: nil)
        ctx.addPath(path); ctx.fillPath()
    }
    private nonisolated static func image(size: CGSize, draw: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        draw(context)
        return context.makeImage()
    }
}
