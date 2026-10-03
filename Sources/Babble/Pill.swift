import AppKit
import QuartzCore

/// Small floating black capsule with a scrolling waveform. Never takes focus, ignores the mouse,
/// and only redraws (capped at 30fps) while listening.
@MainActor
final class Pill {
    private static let size = NSSize(width: 64, height: 22)
    private static let barCount = 11
    private static let barWidth: CGFloat = 2
    private static let barGap: CGFloat = 2.5
    private static let minBarHeight: CGFloat = 2
    private static let maxBarHeight: CGFloat = 12

    private let panel: NSPanel
    private let bars: [CALayer]
    private var history: [Float]
    private var level: () -> Float = { 0 }
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
        bars = (0..<Self.barCount).map { i in
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.cgColor
            bar.cornerRadius = Self.barWidth / 2
            bar.frame.origin.x = originX + CGFloat(i) * (Self.barWidth + Self.barGap)
            bar.frame.size.width = Self.barWidth
            root.addSublayer(bar)
            return bar
        }
        history = Array(repeating: 0, count: Self.barCount)
    }

    /// Shows the pill near the bottom of the screen under the mouse; each frame samples `level` (0...1).
    func show(level: @escaping () -> Float) {
        self.level = level
        history = Array(repeating: 0, count: Self.barCount)
        layoutBars()

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: (frame.midX - Self.size.width / 2).rounded(), y: frame.minY + 24))
        }
        panel.orderFrontRegardless()

        displayLink?.invalidate()
        let link = panel.contentView!.displayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Freezes the waveform flat while the transcript is finalized.
    func showProcessing() {
        stopAnimating()
        history = Array(repeating: 0, count: Self.barCount)
        layoutBars()
    }

    func hide() {
        stopAnimating()
        panel.orderOut(nil)
    }

    @objc private func tick() {
        history.removeFirst()
        history.append(level())
        layoutBars()
    }

    private func layoutBars() {
        let scale = panel.backingScaleFactor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (bar, level) in zip(bars, history) {
            // Snap to whole device pixels so bars stay sharp.
            let raw = Self.minBarHeight + CGFloat(level) * (Self.maxBarHeight - Self.minBarHeight)
            let height = (raw * scale / 2).rounded() * 2 / scale
            bar.frame.size.height = height
            bar.frame.origin.y = (Self.size.height - height) / 2
        }
        CATransaction.commit()
    }

    private func stopAnimating() {
        displayLink?.invalidate()
        displayLink = nil
    }
}
