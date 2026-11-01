import AVFoundation
import Speech
import Synchronization

/// Mic capture for one press at a time. Buffers go to `Dictation`, which converts them to the
/// analyzer's format, the same path files take in evals. The session only runs while recording,
/// so the mic indicator is off when idle.
@MainActor
final class Microphone {
    enum Failure: Error { case noInputDevice }

    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var receiver: Receiver?
    private let queue = DispatchQueue(label: "dev.babble.capture", qos: .userInitiated)

    /// Starts capturing from the default input device and streams audio into `dictation`.
    func start(into dictation: Dictation) async throws {
        guard let device = AVCaptureDevice.default(for: .audio) else { throw Failure.noInputDevice }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        // Mono float at the device's own rate; Dictation resamples.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true, AVNumberOfChannelsKey: 1,
        ]
        let receiver = Receiver(dictation: dictation)
        output.setSampleBufferDelegate(receiver, queue: queue)
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        self.session = session
        self.output = output
        self.receiver = receiver
        // startRunning blocks while the device spins up; keep it off the main thread.
        nonisolated(unsafe) let running = session  // AVCaptureSession is thread-safe but not marked Sendable
        await Task.detached { running.startRunning() }.value
    }

    /// Current input loudness in 0...1, read from the capture connection's meter.
    var level: Float {
        guard let channel = output?.connections.first?.audioChannels.first else { return 0 }
        return min(max((channel.averagePowerLevel + 55) / 40, 0), 1)
    }

    /// Stops capture and waits for buffers already queued, so the last words reach the dictation
    /// before it finishes. The callbacks never touch the main thread, so waiting here can't deadlock.
    func stop() {
        session?.stopRunning()
        queue.sync {}
        output?.setSampleBufferDelegate(nil, queue: nil)
        session = nil
        output = nil
        receiver = nil
    }

    /// Hands each captured buffer to the dictation, on the capture queue.
    private final class Receiver: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, Sendable {
        let dictation: Dictation
        let started = ContinuousClock.now
        private let first = Mutex(true)

        init(dictation: Dictation) { self.dictation = dictation }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard let description = sampleBuffer.formatDescription, let format = AVAudioFormat(formatDescription: description)
            else { return }
            let frames = AVAudioFrameCount(sampleBuffer.numSamples)
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr
            else { return }
            if first.withLock({ isFirst in defer { isFirst = false }; return isFirst }) {
                log.info("First audio \(ContinuousClock.now - self.started, privacy: .public) after press")
            }
            dictation.append(buffer)
        }
    }
}
