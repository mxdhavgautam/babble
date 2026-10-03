import AVFoundation
import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// Push-to-talk: hold ⌥D (English) or ⌥⇧D (Hindi), release to paste, Esc to discard.
@MainActor
final class AppController {
    private enum State {
        case idle
        case recording(Dictation, escapeHotKey: UInt32, releaseWatch: Task<Void, Never>)
        case finishing
    }

    private let hotKeys = HotKeys()
    private let microphone = Microphone()
    private let pill = Pill()
    private var state = State.idle

    init() {
        bind(.english, modifiers: optionKey)
        bind(.hindi, modifiers: optionKey | shiftKey)
        Task { await setUp() }
    }

    private func bind(_ language: Language, modifiers: Int) {
        hotKeys.register(keyCode: kVK_ANSI_D, modifiers: modifiers) { [unowned self] phase in
            switch phase {
            case .pressed: begin(language)
            case .released: Task { await end() }
            }
        }
    }

    private func setUp() async {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        registerLoginItem()
        for language in Language.allCases {
            do { try await language.prepare() } catch {
                log.error("Preparing \(language.locale.identifier) failed: \(error)")
            }
        }
    }

    /// Start at login, but only for the installed copy so dev builds don't register themselves.
    private func registerLoginItem() {
        let installed = Bundle.main.bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
        guard installed, SMAppService.mainApp.status != .enabled else { return }
        do { try SMAppService.mainApp.register() } catch { log.error("Login item: \(error)") }
    }

    private func begin(_ language: Language) {
        guard case .idle = state else { return }
        let dictation = Dictation(language: language)
        let pill = pill
        do {
            try microphone.start(
                onAudio: { dictation.append($0) },
                onLevel: { levels in Task { @MainActor in pill.push(levels) } })
        } catch {
            log.error("Mic failed to start: \(error)")
            Task { await dictation.cancel() }
            return
        }
        pill.show()
        let escape = hotKeys.register(keyCode: kVK_Escape, modifiers: 0) { [unowned self] phase in
            if phase == .pressed { Task { await cancel() } }
        }
        state = .recording(dictation, escapeHotKey: escape, releaseWatch: watchForRelease())
    }

    /// Backstop for a missed Carbon release event: stop once D is no longer physically held.
    private func watchForRelease() -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                if !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_ANSI_D)) {
                    await self?.end()
                    return
                }
            }
        }
    }

    /// Takes the active dictation out of `.recording`, releasing the mic and Esc binding.
    private func takeRecording() -> Dictation? {
        guard case let .recording(dictation, escape, releaseWatch) = state else { return nil }
        releaseWatch.cancel()
        hotKeys.unregister(escape)
        microphone.stop()
        return dictation
    }

    private func end() async {
        guard let dictation = takeRecording() else { return }
        state = .finishing
        pill.showProcessing()
        let text: String
        do { text = try await dictation.finish() } catch {
            log.error("Transcription failed: \(error)")
            text = ""
        }
        pill.hide()
        if !text.isEmpty { await Paster.paste(text) }
        state = .idle
    }

    private func cancel() async {
        guard let dictation = takeRecording() else { return }
        state = .finishing
        pill.hide()
        await dictation.cancel()
        state = .idle
    }
}
