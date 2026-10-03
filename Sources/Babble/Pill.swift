import AppKit
import QuartzCore

/// Small floating black capsule with a springy level meter. Never takes focus, ignores the mouse,
/// and only animates while listening.
@MainActor
final class Pill {
    private static let size = NSSize(width: 66, height: 26)
    private static let barCount = 7
    private static let barWidth: CGFloat = 3
    private static let barGap: CGFloat = 3
    private static let minBarHeight: CGFloat = 3
    private static let maxBarHeight: CGFloat = 15

    /// Bell-curve weights: the middle bars react most, the edges least.
    private static let weights: [Double] = (0..<barCount).map { i in
        let offset = Double(i - barCount / 2) / 1.6
        return 0.3 + 0.7 * exp(-offset * offset / 2)
    }

    /// One bar's spring state. Height is 0...1 of the bar's travel.
    private struct Bar {
        let layer: CALayer
        let weight: Double
        let stiffness: Double  // stiffer in the middle, so those bars snap up fastest
        let wobbleSpeed: Double  // per-bar drift so loud passages don't look like a flat block
        let wobblePhase: Double
        var height = 0.0
        var velocity = 0.0
    }

    private let panel: NSPanel
    private var bars: [Bar]
    private var level: () -> Float = { 0 }
    private var envelope = 0.0
    private var displayLink: CADisplayLink?

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false

        let view = NSView(frame: NSRect(origin: .zero, size: Self.size))
        view.wantsLayer = true
        let root = view.layer!
        root.backgroundColor = NSColor.black.cgColor
        root.cornerRadius = Self.size.height / 2
        root.cornerCurve = .continuous
        root.borderWidth = 0.5
        root.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        panel.contentView = view

        let totalWidth = CGFloat(Self.barCount) * (Self.barWidth + Self.barGap) - Self.barGap
        let originX = ((Self.size.width - totalWidth) / 2).rounded()
        bars = Self.weights.enumerated().map { i, weight in
            let layer = CALayer()
            layer.backgroundColor = NSColor.white.cgColor
            layer.cornerRadius = Self.barWidth / 2
            layer.frame.origin.x = originX + CGFloat(i) * (Self.barWidth + Self.barGap)
            layer.frame.size.width = Self.barWidth
            root.addSublayer(layer)
            return Bar(
                layer: layer, weight: weight, stiffness: 120 + 260 * weight,
                wobbleSpeed: 5 + Double(i * 7 % 5), wobblePhase: Double(i) * 1.9)
        }
    }

    /// Shows the pill near the bottom of the screen under the mouse; each frame samples `level` (0...1).
    func show(level: @escaping () -> Float) {
        self.level = level
        settle()

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: (frame.midX - Self.size.width / 2).rounded(), y: frame.minY + 24))
        }
        panel.orderFrontRegardless()

        displayLink?.invalidate()
        let link = panel.contentView!.displayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Freezes the bars flat while the transcript is finalized.
    func showProcessing() {
        stopAnimating()
        settle()
    }

    func hide() {
        stopAnimating()
        panel.orderOut(nil)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let dt = min(link.targetTimestamp - link.timestamp, 1.0 / 30)
        // Envelope: rises almost instantly with the voice, falls back gently.
        let input = Double(level())
        envelope += (input - envelope) * (input > envelope ? 0.6 : 0.12)

        for i in bars.indices {
            let wobble = 0.8 + 0.2 * sin(link.timestamp * bars[i].wobbleSpeed + bars[i].wobblePhase)
            let target = min(envelope * bars[i].weight * wobble, 1)
            // Under-damped spring: a little overshoot gives the bars their bounce.
            let stiffness = bars[i].stiffness
            let damping = 2 * 0.55 * stiffness.squareRoot()
            bars[i].velocity += (stiffness * (target - bars[i].height) - damping * bars[i].velocity) * dt
            bars[i].height = max(0, bars[i].height + bars[i].velocity * dt)
        }
        layoutBars()
    }

    private func settle() {
        envelope = 0
        for i in bars.indices {
            bars[i].height = 0
            bars[i].velocity = 0
        }
        layoutBars()
    }

    private func layoutBars() {
        let scale = panel.backingScaleFactor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars {
            let raw = Self.minBarHeight + CGFloat(min(bar.height, 1.15)) * (Self.maxBarHeight - Self.minBarHeight)
            // Even pixel counts keep bars centred on whole pixels, so their edges stay sharp.
            let height = (raw * scale / 2).rounded() * 2 / scale
            bar.layer.frame.size.height = height
            bar.layer.frame.origin.y = (Self.size.height - height) / 2
        }
        CATransaction.commit()
    }

    private func stopAnimating() {
        displayLink?.invalidate()
        displayLink = nil
    }
}
