import AVFoundation
import OSLog
import Speech

let log = Logger(subsystem: "dev.babble.app", category: "babble")

/// Languages Babble can transcribe. SpeechTranscriber has no auto-detect, so each has its own hotkey.
enum Language: CaseIterable {
    case english, hindi

    var locale: Locale {
        switch self {
        case .english: Locale(identifier: "en_IN")
        case .hindi: Locale(identifier: "hi_IN")
        }
    }

    /// English stays loaded for instant starts; Hindi is occasional, so let the system unload it.
    var retention: SpeechAnalyzer.Options.ModelRetention {
        self == .english ? .processLifetime : .lingering
    }

    func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .transcription)
    }

    func makeAnalyzer(_ transcriber: SpeechTranscriber) -> SpeechAnalyzer {
        SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: retention))
    }

    /// Downloads the on-device model if missing, then loads it so the first press is fast.
    func prepare() async throws {
        let transcriber = makeTranscriber()
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            _ = try await AssetInventory.reserve(locale: locale)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                log.info("Downloading speech model for \(locale.identifier)")
                try await request.downloadAndInstall()
            }
        }
        if self == .english {
            try await makeAnalyzer(transcriber).prepareToAnalyze(in: nil)
        }
        log.info("Speech model ready for \(locale.identifier)")
    }
}

/// An audio buffer handed across threads. Each one is a fresh copy owned by exactly one consumer.
struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let time: AVAudioTime?
}

/// One utterance: feed audio with `append`, then `finish` for the text or `cancel` to drop it.
/// Audio appended before the analyzer is ready is buffered, so capture can start immediately.
final class Dictation: Sendable {
    private let audio: AsyncStream<AudioChunk>.Continuation
    private let pipeline: Task<String, Error>
    private let analyzer: SpeechAnalyzer

    init(language: Language) {
        let transcriber = language.makeTranscriber()
        let analyzer = language.makeAnalyzer(transcriber)
        let (audioStream, audio) = AsyncStream<AudioChunk>.makeStream()
        self.audio = audio
        self.analyzer = analyzer

        pipeline = Task {
            let (inputs, inputSink) = AsyncStream<AnalyzerInput>.makeStream()
            let results = Task {
                var segments: [String] = []
                for try await result in transcriber.results {
                    segments.append(String(result.text.characters).trimmingCharacters(in: .whitespaces))
                }
                return segments.filter { !$0.isEmpty }.joined(separator: " ")
            }
            try await analyzer.start(inputSequence: inputs)

            let converter = try await AnalyzerInputConverter.converter(compatibleWith: [transcriber])
            for await chunk in audioStream {
                for input in try converter.convert(chunk.buffer, at: chunk.time) { inputSink.yield(input) }
            }
            for input in try converter.flush() { inputSink.yield(input) }
            inputSink.finish()

            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await results.value
        }
    }

    func append(_ chunk: AudioChunk) { audio.yield(chunk) }

    /// Ends input and waits for the final transcript.
    func finish() async throws -> String {
        audio.finish()
        return try await pipeline.value
    }

    func cancel() async {
        audio.finish()
        pipeline.cancel()
        await analyzer.cancelAndFinishNow()
    }
}
