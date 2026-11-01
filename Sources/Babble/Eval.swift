import AVFoundation
import Speech

/// `Babble --eval <manifest.tsv> [--fresh]` runs every recording in the manifest (`audio path<TAB>reference`)
/// through the real pipeline and scores it. Recognizer output is cached next to the manifest so
/// decoding changes can be re-scored in a second; `--fresh` re-transcribes everything.
/// Word error rate is case-sensitive ("Github" for GitHub is wrong) and ignores edge punctuation.
@MainActor
enum Eval {
    struct Score {
        var errors = 0
        var words = 0
        var rate: Double { words == 0 ? 0 : Double(errors) / Double(words) }
        static func += (lhs: inout Score, rhs: Score) {
            lhs.errors += rhs.errors
            lhs.words += rhs.words
        }
    }

    private struct Cached: Codable {
        var transcripts: [Transcript]
        var milliseconds: Double
    }

    static func run(manifest: String, fresh: Bool) async throws {
        let cacheURL = URL(fileURLWithPath: manifest).deletingLastPathComponent().appending(path: "cache.json")
        var cache = fresh ? [:] : (try? JSONDecoder().decode([String: Cached].self, from: Data(contentsOf: cacheURL))) ?? [:]
        let vocabulary = Vocabulary.load()
        let rows = try String(contentsOfFile: manifest, encoding: .utf8).split(whereSeparator: \.isNewline)
            .map { $0.split(separator: "\t", maxSplits: 1).map(String.init) }.filter { $0.count == 2 }
        if rows.contains(where: { cache[$0[0]] == nil }) { try await Transcribers.prepare() }

        var raw = Score(), decoded = Score(), exact = 0
        var finishing = 0.0, decoding = Duration.zero
        for row in rows {
            let path = row[0], reference = row[1]
            if cache[path] == nil { cache[path] = try await transcribe(path) }
            let cached = cache[path]!
            finishing += cached.milliseconds
            let start = ContinuousClock.now
            let result = Decoder.decode(cached.transcripts, vocabulary: vocabulary)
            decoding += ContinuousClock.now - start
            let text = result?.text ?? ""
            raw += score(result?.raw ?? "", against: reference)
            let s = score(text, against: reference)
            decoded += s
            if s.errors == 0 { exact += 1 } else {
                print("✗ \(path.split(separator: "/").suffix(2).joined(separator: "/")) [\(result?.locale ?? "-")]")
                print("  want: \(reference)\n  got:  \(text)")
                if verbose {
                    for t in cached.transcripts { print(String(format: "   %@ %.3f ", t.locale, t.confidence) + t.text) }
                }
            }
        }
        try JSONEncoder().encode(cache).write(to: cacheURL)
        print(String(format: "\nWER raw %.2f%%  decoded %.2f%%  exact %d/%d  finish %.0f ms  decode %.2f ms per utterance",
                     raw.rate * 100, decoded.rate * 100, exact, rows.count, finishing / Double(max(rows.count, 1)),
                     decoding / .milliseconds(1) / Double(max(rows.count, 1))))
    }

    /// `Babble --eval-text <file.tsv>` scores only the text clean-up, on real recognizer output:
    /// `recognizer<TAB>raw<TAB>reference[<TAB>what an older version pasted]`.
    static func runText(_ file: String) throws {
        let vocabulary = Vocabulary.load()
        var raw = Score(), polished = Score(), old = Score(), exact = 0, rows = 0
        for line in try String(contentsOfFile: file, encoding: .utf8).split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3 else { continue }
            rows += 1
            let text = Polish.apply(f[1], vocabulary: vocabulary, hindi: f[0].hasPrefix("hi"))
            raw += score(f[1], against: f[2])
            if f.count > 3 { old += score(f[3], against: f[2]) }
            let s = score(text, against: f[2])
            polished += s
            if s.errors == 0 { exact += 1 } else { print("  want: \(f[2])\n  got:  \(text)") }
        }
        print(String(format: "\nWER raw %.2f%%  old %.2f%%  polished %.2f%%  exact %d/%d",
                     raw.rate * 100, old.rate * 100, polished.rate * 100, exact, rows))
    }

    static let verbose = ProcessInfo.processInfo.environment["BABBLE_VERBOSE"] != nil

    /// Feeds the file as fast as it decodes, then times `finish`, the part a user waits for after release.
    private static func transcribe(_ path: String) async throws -> Cached {
        let dictation = Dictation()
        try dictation.append(contentsOf: URL(fileURLWithPath: path))
        let start = ContinuousClock.now
        let transcripts = try await dictation.finish()
        return Cached(transcripts: transcripts, milliseconds: (ContinuousClock.now - start) / .milliseconds(1))
    }

    /// Word-level edit distance between `hypothesis` and `reference`.
    static func score(_ hypothesis: String, against reference: String) -> Score {
        let h = words(hypothesis).map(strip), r = words(reference)
        // Sentence case after a comma or period ("sleep. Good night") isn't a recognition error.
        let loose = [true] + r.dropLast().map { ",.?!".contains($0.last!) }
        let rs = r.map(strip)
        var previous = Array(0...h.count)
        for i in rs.indices {
            var current = [i + 1] + Array(repeating: 0, count: h.count)
            for j in h.indices {
                let same = rs[i] == h[j]
                    || (loose[i] && rs[i].dropFirst() == h[j].dropFirst() && rs[i].prefix(1).lowercased() == h[j].prefix(1).lowercased())
                current[j + 1] = min(previous[j] + (same ? 0 : 1), previous[j + 1] + 1, current[j] + 1)
            }
            previous = current
        }
        return Score(errors: previous[h.count], words: r.count)
    }

    private static func words(_ text: String) -> [String] {
        text.split(separator: " ").map(String.init).filter { !strip($0).isEmpty }
    }

    /// Trims edge punctuation: "pass," → "pass", while ".env" and "~/code" stay. Small numbers compare
    /// equal as words or digits ("two lines" and "2 lines" are both fine).
    private static func strip(_ word: String) -> String {
        let core = String(word.drop { "\"'(".contains($0) }.reversed().drop { ".,!?;:\"')".contains($0) }.reversed())
        return smallNumbers[core.lowercased()] ?? core
    }

    private static let smallNumbers = ["zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
                                       "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10"]
}
