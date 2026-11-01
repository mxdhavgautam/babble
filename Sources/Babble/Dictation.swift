import AVFoundation
import OSLog
import Speech
import Synchronization

let log = Logger(subsystem: "dev.babble.app", category: "babble")

/// Recognizers run side by side on every utterance; `Decoder` picks and repairs the final text.
/// The Hindi model writes Latin-script Hinglish and copes well with English words mixed in.
enum Transcribers {
    static let locales = [Locale(identifier: "en_IN"), Locale(identifier: "hi_IN")]

    /// Alternatives cost nothing measurable and give `Decoder` the other readings to choose from.
    static func make() -> [SpeechTranscriber] {
        locales.map {
            SpeechTranscriber(
                locale: $0, transcriptionOptions: [], reportingOptions: [.alternativeTranscriptions],
                attributeOptions: [.transcriptionConfidence])
        }
    }

    /// Downloads missing on-device models, then loads them so the first press is fast.
    static func prepare() async throws {
        let transcribers = make()
        for locale in locales { _ = try await AssetInventory.reserve(locale: locale) }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: transcribers) {
            log.info("Downloading speech models")
            try await request.downloadAndInstall()
        }
        if let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: transcribers) {
            analyzerFormat.withLock { $0 = format }
        }
        try await SpeechAnalyzer(modules: transcribers, options: analyzerOptions).prepareToAnalyze(in: nil)
        log.info("Speech models ready")
    }

    static let analyzerOptions = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)

    /// The audio format the transcribers want, refreshed by `prepare`. 16 kHz 16-bit mono today.
    static let analyzerFormat = Mutex(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!)
}

/// One recognizer's reading of an utterance, as a chain of chunks.
struct Transcript: Codable, Sendable {
    /// A stretch of audio (in seconds) and the readings the recognizer considered for it, best first:
    /// [" hetsner.", " Hetzner.", ...]. Readings carry their own spacing.
    struct Chunk: Codable, Sendable {
        var start: Double
        var end: Double
        var alternatives: [String]
    }

    var locale: String
    var confidence: Double
    var chunks: [Chunk]

    /// The recognizer's own best guess.
    var text: String { Self.join(chunks.map { $0.alternatives[0] }) }

    /// Concatenates chunk texts, which carry their own spacing, adding a space where two meet bare.
    static func join(_ pieces: [String]) -> String {
        var out = ""
        for piece in pieces where !piece.isEmpty {
            if let last = out.last, !last.isWhitespace, !piece.first!.isWhitespace { out += " " }
            out += piece
        }
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// One utterance: feed audio with `append`, then `finish` for every recognizer's transcript
/// or `cancel` to drop it. Input appended before the analyzer is running is buffered, so capture
/// can start immediately.
final class Dictation: Sendable {
    let modules: [SpeechTranscriber]
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let received = Mutex(false)
    /// Resamples to the analyzer's format, keeping state between buffers. It and `closed` are only
    /// touched under `converting`.
    nonisolated(unsafe) private let converter: AnalyzerInputConverter
    nonisolated(unsafe) private var closed = false
    private let converting = NSLock()
    private let results: [Task<Transcript, Error>]
    private let started: Task<Void, Error>

    init() {
        modules = Transcribers.make()
        analyzer = SpeechAnalyzer(modules: modules, options: Transcribers.analyzerOptions)
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        self.input = input
        converter = AnalyzerInputConverter(analyzerFormat: Transcribers.analyzerFormat.withLock { $0 })

        results = zip(modules, Transcribers.locales).map { transcriber, locale in
            Task {
                var chunks: [Transcript.Chunk] = []
                var confidences: [Double] = []
                for try await result in transcriber.results {
                    let alternatives = result.alternatives.map { String($0.characters) }
                    chunks.append(
                        .init(
                            start: result.range.start.seconds, end: result.range.end.seconds,
                            alternatives: alternatives.isEmpty ? [String(result.text.characters)] : alternatives))
                    confidences += result.text.runs.compactMap(\.transcriptionConfidence)
                }
                let mean = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count)
                return Transcript(locale: locale.identifier, confidence: mean, chunks: chunks)
            }
        }
        started = Task { [analyzer] in try await analyzer.start(inputSequence: stream) }
    }

    /// Converts a buffer of audio, in any format, and queues it for the analyzer. Used for files;
    /// live capture goes through the provider, whose conversion measured better on a real mic.
    func append(_ buffer: AVAudioPCMBuffer) {
        // Yield under the lock too, so nothing slips in after `finish` has flushed and closed.
        converting.withLock {
            // A capture callback can still land after `finish`; it's too late to count.
            guard !closed else { return }
            do {
                let inputs = try converter.convert(buffer, at: nil)
                if !inputs.isEmpty { received.withLock { $0 = true } }
                inputs.forEach { input.yield($0) }
            } catch {
                log.error("Converting audio failed: \(error)")
            }
        }
    }

    /// Queues audio already in the analyzer's format, as the mic's capture provider delivers it.
    func append(_ audio: AnalyzerInput) {
        converting.withLock {
            guard !closed else { return }
            received.withLock { $0 = true }
            input.yield(audio)
        }
    }

    /// Ends input and returns each recognizer's transcript (none if nothing was heard).
    /// Gives up after `timeout` so a stalled analyzer can never wedge the app.
    func finish(timeout: Duration = .seconds(10)) async throws -> [Transcript] {
        converting.withLock {
            closed = true
            let rest = (try? converter.flush()) ?? []
            if !rest.isEmpty { received.withLock { $0 = true } }
            rest.forEach { input.yield($0) }
            input.finish()
        }
        // The analyzer never completes finalization for an empty stream, so skip it.
        guard received.withLock({ $0 }) else {
            await cancel()
            return []
        }
        let watchdog = Task { [self] in
            try await Task.sleep(for: timeout)
            log.error("Transcription timed out")
            await cancel()
        }
        defer { watchdog.cancel() }
        try await started.value
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        var transcripts: [Transcript] = []
        for task in results { transcripts.append(try await task.value) }
        return transcripts.filter { !$0.text.isEmpty }
    }

    /// Feeds a whole audio file, in mic-sized pieces, for `--transcribe` and evals.
    func append(contentsOf url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return }
            try file.read(into: buffer)
            append(buffer)
        }
    }

    func cancel() async {
        input.finish()
        results.forEach { $0.cancel() }
        await analyzer.cancelAndFinishNow()
    }
}
