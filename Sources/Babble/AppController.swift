import AVFoundation
import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// Push-to-talk: hold ⌥D to dictate, release to paste, Esc while holding to discard.
@MainActor
final class AppController {
    private struct Recording {
        let dictation: Dictation
        let startedAt: ContinuousClock.Instant
        let capture: Task<Void, Error>
        let escapeHotKeys: [UInt32]
        let releaseWatch: Task<Void, Never>
    }

    private enum State {
        case idle
        case recording(Recording)
        case finishing
    }

    /// Presses shorter than this are treated as accidental taps and discarded.
    private static let minimumHold = Duration.milliseconds(300)

    private let hotKeys = HotKeys()
    private let microphone = Microphone()
    private let pill = Pill()
    private var state = State.idle

    init() {
        hotKeys.register(keyCode: kVK_ANSI_D, modifiers: optionKey) { [unowned self] phase in
            switch phase {
            case .pressed: begin()
            case .released: Task { await end() }
            }
        }
        Task { await setUp() }
    }

    private func setUp() async {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        registerLoginItem()
        do { try await Transcribers.prepare() } catch { log.error("Preparing speech models failed: \(error)") }
    }

    /// Start at login, but only for the installed copy so dev builds don't register themselves.
    private func registerLoginItem() {
        let installed = Bundle.main.bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
        guard installed, SMAppService.mainApp.status != .enabled else { return }
        do { try SMAppService.mainApp.register() } catch { log.error("Login item: \(error)") }
    }

    private func begin() {
        guard case .idle = state else { return }
        let dictation = Dictation()
        let microphone = microphone
        let capture = Task { try await microphone.start(into: dictation) }
        pill.show { microphone.level }
        // Option is still held while recording, so Esc arrives as ⌥Esc; catch both forms.
        let escapeHotKeys = [0, optionKey].map { modifiers in
            hotKeys.register(keyCode: kVK_Escape, modifiers: modifiers) { [unowned self] phase in
                if phase == .pressed { Task { await end(discard: true) } }
            }
        }
        state = .recording(
            Recording(
                dictation: dictation, startedAt: .now, capture: capture,
                escapeHotKeys: escapeHotKeys, releaseWatch: watchOptionRelease()))
    }

    /// Carbon reports D's release, but not Option's; stop as soon as Option is let go too.
    private func watchOptionRelease() -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                if !NSEvent.modifierFlags.contains(.option) {
                    await self?.end()
                    return
                }
            }
        }
    }

    private func end(discard: Bool = false) async {
        guard case let .recording(recording) = state else { return }
        state = .finishing
        // Measure the hold before awaiting mic startup/teardown, which can take a while.
        let tooShort = ContinuousClock.now - recording.startedAt < Self.minimumHold
        recording.releaseWatch.cancel()
        recording.escapeHotKeys.forEach(hotKeys.unregister)

        let captureResult = await recording.capture.result
        microphone.stop()

        if discard || tooShort {
            pill.hide()
            await recording.dictation.cancel()
        } else if case let .failure(error) = captureResult {
            log.error("Mic failed to start: \(error)")
            pill.hide()
            await recording.dictation.cancel()
        } else {
            pill.showProcessing()
            let raw = (try? await recording.dictation.finish()) ?? ""
            let text = raw.isEmpty ? raw : await Cleanup.run(raw)
            pill.hide()
            if !text.isEmpty { await Paster.paste(text) }
        }
        state = .idle
    }
}
