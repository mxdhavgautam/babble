import AVFoundation
import OSLog
import Speech
import Synchronization

let log = Logger(subsystem: "dev.babble.app", category: "babble")

/// Recognizers run side by side on every utterance; the most confident transcript wins.
/// The Hindi model writes Latin-script Hinglish and copes well with English words mixed in.
enum Transcribers {
    static let locales = [Locale(identifier: "en_IN"), Locale(identifier: "hi_IN")]

    static func make() -> [SpeechTranscriber] {
        locales.map {
            SpeechTranscriber(
                locale: $0, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.transcriptionConfidence])
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
        try await SpeechAnalyzer(modules: transcribers, options: analyzerOptions).prepareToAnalyze(in: nil)
        log.info("Speech models ready")
    }

    static let analyzerOptions = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
}

/// One utterance: feed audio with `append`, then `finish` for the text or `cancel` to drop it.
/// Input appended before the analyzer is running is buffered, so capture can start immediately.
final class Dictation: Sendable {
    let modules: [SpeechTranscriber]
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let received = Mutex(false)
    private let results: [Task<Transcript, Error>]
    private let started: Task<Void, Error>

    private struct Transcript {
        var text = ""
        var confidence: Double = 0
    }

    init() {
        modules = Transcribers.make()
        analyzer = SpeechAnalyzer(modules: modules, options: Transcribers.analyzerOptions)
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        self.input = input

        results = modules.map { transcriber in
            Task {
                var segments: [String] = []
                var confidences: [Double] = []
                for try await result in transcriber.results {
                    segments.append(String(result.text.characters).trimmingCharacters(in: .whitespaces))
                    confidences += result.text.runs.compactMap(\.transcriptionConfidence)
                }
                let mean = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count)
                return Transcript(text: segments.filter { !$0.isEmpty }.joined(separator: " "), confidence: mean)
            }
        }
        started = Task { [analyzer] in try await analyzer.start(inputSequence: stream) }
    }

    func append(_ audio: AnalyzerInput) {
        received.withLock { $0 = true }
        input.yield(audio)
    }

    /// Ends input and returns the most confident transcript ("" if nothing was heard).
    /// Gives up after `timeout` so a stalled analyzer can never wedge the app.
    func finish(timeout: Duration = .seconds(10)) async throws -> String {
        input.finish()
        // The analyzer never completes finalization for an empty stream, so skip it.
        guard received.withLock({ $0 }) else {
            await cancel()
            return ""
        }
        let watchdog = Task { [self] in
            try await Task.sleep(for: timeout)
            log.error("Transcription timed out")
            await cancel()
        }
        defer { watchdog.cancel() }
        try await started.value
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        var best = Transcript()
        for task in results {
            let transcript = try await task.value
            log.debug("\(transcript.confidence) \(transcript.text, privacy: .private)")
            if transcript.confidence > best.confidence { best = transcript }
        }
        return best.text
    }

    func cancel() async {
        input.finish()
        results.forEach { $0.cancel() }
        await analyzer.cancelAndFinishNow()
    }
}
