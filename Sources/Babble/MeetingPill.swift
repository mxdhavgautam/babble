import AppKit
import QuartzCore

/// Small capsule in the bottom-right corner while a meeting records: a red dot, the elapsed time,
/// and one level bar each for Me (white) and Them (blue). Updates ten times a second and only
/// touches layers whose value changed, so it costs nothing while the room is quiet.
@MainActor
final class MeetingPill {
    private static let size = NSSize(width: 92, height: 24)
    private static let barHeight: CGFloat = 14

    private let panel: NSPanel
    private let label = CATextLayer()
    private let dot = CALayer()
    private let bars: [CALayer]
    private var timer: Timer?
    private var start = ContinuousClock.now
    private var levels: () -> [Float] = { [0, 0] }
    private var shown: (time: String, levels: [CGFloat]) = ("", [-1, -1])

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

        dot.backgroundColor = NSColor.systemRed.cgColor
        dot.frame = CGRect(x: 10, y: (Self.size.height - 7) / 2, width: 7, height: 7)
        dot.cornerRadius = 3.5
        root.addSublayer(dot)

        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.fontSize = 11
        label.foregroundColor = NSColor.white.cgColor
        label.alignmentMode = .left
        label.frame = CGRect(x: 22, y: (Self.size.height - 14) / 2, width: 46, height: 14)
        root.addSublayer(label)

        bars = [NSColor.white, NSColor.systemBlue].enumerated().map { i, color in
            let bar = CALayer()
            bar.backgroundColor = color.cgColor
            bar.cornerRadius = 1.5
            bar.frame = CGRect(x: 70 + CGFloat(i) * 7, y: 0, width: 3, height: 0)
            root.addSublayer(bar)
            return bar
        }
    }

    /// Shows the pill; `levels` returns Me's and Them's loudness in 0...1.
    func show(since start: ContinuousClock.Instant, levels: @escaping () -> [Float]) {
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - Self.size.width - 16, y: frame.minY + 16))
        }
        label.contentsScale = panel.backingScaleFactor
        dot.isHidden = false
        bars.forEach { $0.isHidden = false }
        shown = ("", [-1, -1])
        self.start = start
        self.levels = levels
        panel.orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    /// Static "notes" state while the notes are written after the meeting.
    func showProcessing() {
        stopTimer()
        dot.isHidden = true
        bars.forEach { $0.isHidden = true }
        setLabel("notes…")
    }

    func hide() {
        stopTimer()
        panel.orderOut(nil)
    }

    private func update() {
        let seconds = Int((ContinuousClock.now - start) / .seconds(1))
        setLabel(seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60))
        // Quantize to whole points so tiny level changes don't redraw anything.
        let heights = levels().map { (CGFloat($0) * Self.barHeight).rounded() }
        guard heights != shown.levels else { return }
        shown.levels = heights
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (bar, height) in zip(bars, heights) {
            let h = max(height, 3)
            bar.frame = CGRect(x: bar.frame.minX, y: (Self.size.height - h) / 2, width: 3, height: h)
        }
        CATransaction.commit()
    }

    private func setLabel(_ text: String) {
        guard text != shown.time else { return }
        shown.time = text
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.string = text
        CATransaction.commit()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
