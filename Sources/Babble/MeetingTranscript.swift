import AVFoundation
import Synchronization

enum Speaker: String, Sendable {
    /// The mic.
    case me = "Me"
    /// System audio: everyone else on the call.
    case them = "Them"
}

/// One finished utterance from one side of the meeting. `start` is seconds since the meeting began.
struct Line: Sendable {
    var start: Double
    var speaker: Speaker
    var text: String
}

/// Cuts one audio stream into utterances at pauses and runs each through the dictation pipeline
/// (both recognizers, then `Decoder`), so meeting lines get the same accuracy as dictation.
/// `feed` is called from the capture thread; finished lines go to `onLine` on the main actor.
final class Segmenter: Sendable {
    /// Quieter than this (dBFS) counts as silence.
    static let silenceFloor: Float = -45
    /// A pause this long after speech ends the utterance.
    static let pause = 0.8
    /// Long monologues are cut at the next quiet buffer after `softLimit`, and regardless at `hardLimit`.
    static let softLimit = 30.0
    static let hardLimit = 40.0
    /// Audio with no speech is dropped after this long, so silence never piles up in the recognizers.
    static let idleLimit = 10.0

    private struct Segment {
        let dictation = Dictation()
        let start: Double
        var spoke = false
        var lastLoud: Double
    }

    private struct State {
        var segment: Segment?
        var pending: [Task<Void, Never>] = []
        var closed = false
        var level: Float = 0
    }

    let speaker: Speaker
    private let origin: ContinuousClock.Instant
    private let onLine: @MainActor @Sendable (Line) -> Void
    private let state = Mutex(State())

    init(speaker: Speaker, origin: ContinuousClock.Instant, onLine: @escaping @MainActor @Sendable (Line) -> Void) {
        self.speaker = speaker
        self.origin = origin
        self.onLine = onLine
    }

    /// Loudness of the latest buffer in 0...1, for the meter.
    var level: Float { state.withLock { $0.level } }

    func feed(_ buffer: AVAudioPCMBuffer) {
        let now = (ContinuousClock.now - origin) / .seconds(1)
        let db = Self.loudness(buffer)
        let loud = db > Self.silenceFloor
        state.withLock { s in
            guard !s.closed else { return }
            s.level = min(max((db + 55) / 40, 0), 1)
            if s.segment == nil { s.segment = Segment(start: now, lastLoud: now) }
            s.segment!.dictation.append(buffer)
            if loud {
                s.segment!.spoke = true
                s.segment!.lastLoud = now
            }
            let segment = s.segment!
            let age = now - segment.start
            if segment.spoke {
                if now - segment.lastLoud >= Self.pause || (age >= Self.softLimit && !loud) || age >= Self.hardLimit {
                    s.segment = nil
                    s.pending.append(transcribe(segment))
                }
            } else if age >= Self.idleLimit {
                s.segment = nil
                Task { await segment.dictation.cancel() }
            }
        }
    }

    /// Stops taking audio, transcribes what's left and waits for every utterance to land.
    func finish() async {
        let pending = state.withLock { s in
            s.closed = true
            s.level = 0
            if let segment = s.segment {
                if segment.spoke { s.pending.append(transcribe(segment)) } else { Task { await segment.dictation.cancel() } }
                s.segment = nil
            }
            return s.pending
        }
        for task in pending { await task.value }
    }

    /// Stops taking audio and drops the utterance in progress. Ones already finishing still land.
    func cancel() {
        let segment = state.withLock { s in
            s.closed = true
            defer { s.segment = nil }
            return s.segment
        }
        if let segment { Task { await segment.dictation.cancel() } }
    }

    private func transcribe(_ segment: Segment) -> Task<Void, Never> {
        Task { [speaker, onLine] in
            let transcripts: [Transcript]
            do { transcripts = try await segment.dictation.finish() } catch {
                log.error("Meeting segment failed: \(error)")
                return
            }
            // The first word can come well after the cut, so time the line from the speech itself.
            let offset = transcripts.compactMap { $0.chunks.first?.start }.min() ?? 0
            await MainActor.run {
                guard let decoded = Decoder.decode(transcripts, vocabulary: .load()), !decoded.text.isEmpty else { return }
                onLine(Line(start: segment.start + offset, speaker: speaker, text: decoded.text))
            }
        }
    }

    /// RMS level of the buffer's first channel in dBFS. Buffers without float samples count as loud,
    /// so they are still cut by the length limits.
    static func loudness(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        return 10 * log10(max(sum / Float(buffer.frameLength), 1e-12))
    }
}

/// The meeting's transcript, kept in time order and rewritten to disk as each line lands, so a crash
/// loses only what was still being transcribed.
@MainActor
final class MeetingTranscript {
    /// Consecutive lines from one speaker merge into one, up to this many seconds long.
    static let mergeWindow = 120.0

    let url: URL
    private let title: String
    private(set) var lines: [Line] = []
    /// Set on discard, so utterances still finishing don't write the file back.
    var discarded = false

    init(url: URL, started: Date) {
        self.url = url
        title = "# Meeting transcript\n\nStarted \(started.formatted(date: .abbreviated, time: .shortened))\n"
        write()
    }

    func add(_ line: Line) {
        guard !discarded else { return }
        let index = lines.firstIndex { $0.start > line.start } ?? lines.endIndex
        lines.insert(line, at: index)
        write()
    }

    private func write() {
        guard !discarded else { return }
        let body = Self.render(lines).joined(separator: "\n\n")
        MeetingFolder.write(title + (body.isEmpty ? "" : "\n" + body + "\n"), to: url)
    }

    /// `[hh:mm:ss] Speaker: text`, merging a speaker's consecutive lines.
    static func render(_ lines: [Line]) -> [String] {
        var merged: [Line] = []
        for line in lines {
            if let last = merged.last, last.speaker == line.speaker, line.start - last.start < mergeWindow {
                merged[merged.count - 1].text += " " + line.text
            } else {
                merged.append(line)
            }
        }
        return merged.map { "[\(timestamp($0.start))] \($0.speaker.rawValue): \($0.text)" }
    }

    static func timestamp(_ seconds: Double) -> String {
        let s = max(Int(seconds), 0)
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

/// `~/Babble/Meetings/<yyyy-MM-dd HHmm>/`, private to the user like the dictation history.
enum MeetingFolder {
    static let root = URL.homeDirectory.appending(path: "Babble/Meetings")

    static func create(for date: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        var url = root.appending(path: formatter.string(from: date))
        // A second meeting in the same minute gets the seconds too.
        if FileManager.default.fileExists(atPath: url.path) {
            formatter.dateFormat = "yyyy-MM-dd HHmmss"
            url = root.appending(path: formatter.string(from: date))
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    /// Writes atomically, then restricts the file to the user.
    static func write(_ text: String, to url: URL) {
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            log.error("Writing \(url.lastPathComponent, privacy: .public) failed: \(error)")
        }
    }
}
