import AVFoundation
import Speech

/// Mic capture for one press at a time, via Speech's capture provider (which also converts to the
/// analyzer's format). The session only runs while recording, so the mic indicator is off when idle.
@MainActor
final class Microphone {
    enum Failure: Error { case noInputDevice }

    private var provider: CaptureInputSequenceProvider?
    private var forwarding: Task<Void, Never>?

    /// Starts capturing from the default input device and streams audio into `dictation`.
    func start(into dictation: Dictation) async throws {
        let requested = ContinuousClock.now
        guard let device = AVCaptureDevice.default(for: .audio) else { throw Failure.noInputDevice }
        let provider = try await CaptureInputSequenceProvider.providerWithSession(
            from: device, compatibleWith: dictation.modules, priority: .userInitiated)
        self.provider = provider
        forwarding = Task {
            do {
                var first = true
                for try await input in provider.analyzerInputs {
                    if first {
                        log.info("First audio \(ContinuousClock.now - requested) after press")
                        first = false
                    }
                    dictation.append(input)
                }
            } catch {
                log.error("Capture stream failed: \(error)")
            }
        }
        nonisolated(unsafe) let session = provider.captureSession  // AVCaptureSession is thread-safe but not marked Sendable
        if !session.isRunning {
            // startRunning blocks while the device spins up; keep it off the main thread.
            await Task.detached { session.startRunning() }.value
        }
    }

    /// Current input loudness in 0...1, read from the capture connection's meter.
    var level: Float {
        guard let channel = provider?.captureAudioDataOutput.connections.first?.audioChannels.first else { return 0 }
        return min(max((channel.averagePowerLevel + 55) / 40, 0), 1)
    }

    func stop() {
        provider?.captureSession.stopRunning()
        forwarding?.cancel()
        provider = nil
        forwarding = nil
    }
}
