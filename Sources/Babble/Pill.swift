import AppKit
import QuartzCore

/// Floating black capsule with a scrolling waveform. Never takes focus, ignores the mouse,
/// and only redraws (capped at 30fps) while listening.
@MainActor
final class Pill {
    private static let size = NSSize(width: 132, height: 34)
    private static let barCount = 26
    private static let barWidth: CGFloat = 2
    private static let barGap: CGFloat = 2
    private static let maxBarHeight: CGFloat = 18

    private let panel: NSPanel
    private let bars: [CALayer]
    private var history: [Float]
    private var pending: [Float] = []
    private var displayLink: CADisplayLink?

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false

        let view = NSView(frame: NSRect(origin: .zero, size: Self.size))
        view.wantsLayer = true
        let root = view.layer!
        root.backgroundColor = NSColor.black.cgColor
        root.cornerRadius = Self.size.height / 2
        root.borderWidth = 1
        root.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        panel.contentView = view

        let totalWidth = CGFloat(Self.barCount) * (Self.barWidth + Self.barGap) - Self.barGap
        let originX = (Self.size.width - totalWidth) / 2
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

    /// Shows the pill at the bottom centre of the screen under the mouse and starts the waveform.
    func show() {
        history = Array(repeating: 0, count: Self.barCount)
        pending = []
        layoutBars()

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + 28))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let link = panel.contentView!.displayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Freezes the waveform flat while the final transcript is computed.
    func showProcessing() {
        stopAnimating()
        history = Array(repeating: 0, count: Self.barCount)
        layoutBars()
    }

    func hide() {
        stopAnimating()
        panel.orderOut(nil)
    }

    /// Queues mic levels (0...1); the next frame scrolls in their peak.
    func push(_ levels: [Float]) {
        guard displayLink != nil else { return }
        pending.append(contentsOf: levels)
    }

    @objc private func tick() {
        guard let peak = pending.max() else { return }
        pending.removeAll(keepingCapacity: true)
        history.removeFirst()
        history.append(peak)
        layoutBars()
    }

    private func layoutBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (bar, level) in zip(bars, history) {
            let height = max(Self.barWidth, CGFloat(level) * Self.maxBarHeight)
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
