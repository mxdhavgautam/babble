import AVFoundation

/// Mic capture for one press at a time. The engine only runs while recording,
/// so the system mic indicator is off whenever Babble is idle.
@MainActor
final class Microphone {
    private let engine = AVAudioEngine()

    /// Starts streaming copies of mic buffers to `onAudio` and loudness (0...1) to `onLevel`, both off the main thread.
    func start(onAudio: @escaping @Sendable (AudioChunk) -> Void, onLevel: @escaping @Sendable ([Float]) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
            guard let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
            onAudio(AudioChunk(buffer: copy, time: time))
            onLevel(levels(of: buffer))
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }
}

/// Splits a buffer into ~10ms windows and maps each window's RMS to 0...1 on a -50...-5 dB scale.
private func levels(of buffer: AVAudioPCMBuffer) -> [Float] {
    guard let samples = buffer.floatChannelData?[0] else { return [] }
    let frames = Int(buffer.frameLength)
    let window = max(Int(buffer.format.sampleRate / 100), 1)
    return stride(from: 0, to: frames, by: window).map { start in
        let end = min(start + window, frames)
        var sum: Float = 0
        for i in start..<end { sum += samples[i] * samples[i] }
        let db = 20 * log10(max(sqrt(sum / Float(end - start)), 1e-6))
        return min(max((db + 50) / 45, 0), 1)
    }
}
