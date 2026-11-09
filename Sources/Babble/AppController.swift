import AVFoundation
import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// Push-to-talk: hold ⌥D to dictate, release to paste, Esc while holding to discard.
/// Meeting mode: ⌥T starts and stops a meeting, ⌥Esc throws it away. Dictation is off meanwhile.
@MainActor
final class AppController {
    private struct Recording {
        let dictation: Dictation
        let startedAt: ContinuousClock.Instant
        let capture: Task<Void, Error>
        let escapeHotKeys: [UInt32]
        let optionWatch: Task<Void, Never>
    }

    private enum State {
        case idle
        case recording(Recording)
        case finishing
    }

    /// Presses shorter than this are treated as accidental taps and discarded.
    private static let minimumHold = Duration.milliseconds(300)
    /// How long the combo may be broken (a slipped finger) before the recording ends.
    private static let releaseGrace = Duration.milliseconds(200)

    private let hotKeys = HotKeys()
    private let microphone = Microphone()
    private let pill = Pill()
    private var state = State.idle
    private var dHeld = false
    private var pendingEnd: Task<Void, Never>?
    private var meeting: (session: MeetingSession, discardHotKey: UInt32)?

    init() {
        hotKeys.register(keyCode: kVK_ANSI_D, modifiers: optionKey) { [unowned self] phase in
            dHeld = phase == .pressed
            switch phase {
            case .pressed:
                // Grabbing the combo again inside the grace period keeps the recording going.
                pendingEnd?.cancel()
                pendingEnd = nil
                begin()
            case .released: scheduleEnd()
            }
        }
        hotKeys.register(keyCode: kVK_ANSI_T, modifiers: optionKey) { [unowned self] phase in
            if phase == .pressed { toggleMeeting() }
        }
        Notifier.shared.install()
        Task { await setUp() }
    }

    private func toggleMeeting() {
        if let meeting {
            hotKeys.unregister(meeting.discardHotKey)
            self.meeting = nil
            Task { await meeting.session.stop() }
            return
        }
        guard case .idle = state else { return }
        do {
            let session = try MeetingSession()
            do { try session.start() } catch {
                session.discard()
                throw error
            }
            let discardHotKey = hotKeys.register(keyCode: kVK_Escape, modifiers: optionKey) { [unowned self] phase in
                guard phase == .pressed, let meeting else { return }
                hotKeys.unregister(meeting.discardHotKey)
                self.meeting = nil
                meeting.session.discard()
            }
            meeting = (session, discardHotKey)
        } catch {
            log.error("Meeting failed to start: \(error)")
        }
    }

    private func setUp() async {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        registerLoginItem()
        _ = Vocabulary.load()  // parse before the first press
        do { try await Transcribers.prepare() } catch { log.error("Preparing speech models failed: \(error)") }
    }

    /// Start at login, but only for the installed copy so dev builds don't register themselves.
    private func registerLoginItem() {
        let installed = Bundle.main.bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
        guard installed, SMAppService.mainApp.status != .enabled else { return }
        do { try SMAppService.mainApp.register() } catch { log.error("Login item: \(error)") }
    }

    private func begin() {
        guard case .idle = state, meeting == nil else { return }
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
                escapeHotKeys: escapeHotKeys, optionWatch: watchOption()))
    }

    /// Carbon reports D's release but not Option's, so poll for Option too.
    private func watchOption() -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                if !NSEvent.modifierFlags.contains(.option) { self?.scheduleEnd() }
            }
        }
    }

    /// Ends the recording unless the full combo is held again within the grace period.
    private func scheduleEnd() {
        guard case .recording = state, pendingEnd == nil else { return }
        pendingEnd = Task { [weak self] in
            try? await Task.sleep(for: Self.releaseGrace)
            guard let self, !Task.isCancelled else { return }
            pendingEnd = nil
            if !(dHeld && NSEvent.modifierFlags.contains(.option)) { await end() }
        }
    }

    private func end(discard: Bool = false) async {
        guard case let .recording(recording) = state else { return }
        state = .finishing
        let released = ContinuousClock.now
        // Measure the hold before awaiting mic startup/teardown, which can take a while.
        let tooShort = released - recording.startedAt < Self.minimumHold + Self.releaseGrace
        pendingEnd?.cancel()
        pendingEnd = nil
        recording.optionWatch.cancel()
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
            let app = History.frontmostApp
            var transcripts: [Transcript] = []
            do { transcripts = try await recording.dictation.finish() } catch {
                log.error("Transcription failed: \(error)")
            }
            let decoded = Decoder.decode(transcripts, vocabulary: .load())
            pill.hide()
            if let decoded, !decoded.text.isEmpty {
                await Paster.paste(decoded.text)
                History.append(
                    .init(
                        time: .now, raw: decoded.raw, text: decoded.text, recognizer: decoded.locale,
                        confidence: (decoded.confidence * 1000).rounded() / 1000,
                        // Only grace-period releases reach here, so subtract the grace to get the real hold.
                        heldSeconds: ((released - recording.startedAt - Self.releaseGrace) / .milliseconds(10)).rounded() / 100,
                        app: app))
                log.info("Pasted \(decoded.text.count, privacy: .public) chars \(ContinuousClock.now - released, privacy: .public) after release")
            } else {
                log.info("Nothing heard in \(released - recording.startedAt, privacy: .public)")
            }
        }
        state = .idle
    }
}
