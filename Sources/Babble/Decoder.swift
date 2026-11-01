import Foundation

/// Turns every recognizer's transcript for an utterance into the text to paste.
///
/// The most confident recognizer's best guess is the starting point. Each recognizer also reports
/// what else it might have heard for every stretch of audio, and the other recognizer has its own
/// reading of the same stretch. A reading replaces the best guess only with evidence: it spells a
/// vocabulary term the guess lacks ("Imogen" → "Imagen"), or, among the recognizer's own guesses
/// in English, it swaps a made-up word for a real one ("SSSH" → "SSH"). The other recognizer
/// agreeing makes a swap cheaper and overriding text both agree on dearer, but agreement alone
/// never decides: that's a coin flip ("merging" vs "mugging").
@MainActor
enum Decoder {
    struct Result {
        var text: String
        /// The chosen recognizer's own best guess, before any repair.
        var raw: String
        var locale: String
        var confidence: Double
    }

    static func decode(_ transcripts: [Transcript], vocabulary: Vocabulary) -> Result? {
        guard let primary = transcripts.max(by: { $0.confidence < $1.confidence }) else { return nil }
        let others = transcripts.filter { $0.locale != primary.locale }
        let technical = transcripts.contains { vocabulary.isTechnical($0.text) }
        let repaired = Transcript.join(repair(primary, others: others, vocabulary: vocabulary, technical: technical))
        let heard = transcripts.reduce(into: Set<String>()) { keys, transcript in
            for chunk in transcript.chunks { for reading in chunk.alternatives { keys.formUnion(vocabulary.spelled(in: reading)) } }
        }
        let text = Polish.apply(repaired, vocabulary: vocabulary, hindi: primary.locale.hasPrefix("hi"), heard: heard)
        return Result(text: text, raw: primary.text, locale: primary.locale, confidence: primary.confidence)
    }

    /// A reading that could replace the best guess for chunks `from..<to` of the primary transcript.
    private struct Edge {
        let from: Int
        let to: Int
        let text: String
        let cost: Double
        /// From the primary recognizer's own alternatives rather than the other recognizer.
        var own = false
    }

    /// Chooses, chunk by chunk, between the primary transcript's best guess and the alternatives.
    private static func repair(
        _ primary: Transcript, others: [Transcript], vocabulary: Vocabulary, technical: Bool
    ) -> [String] {
        let chunks = primary.chunks
        let tops = chunks.map { $0.alternatives[0] }
        // Hinglish is full of words the spell checker doesn't know; English rarely is.
        let english = Double(vocabulary.oddWords(in: primary.text)) < 0.2 * Double(primary.text.split(separator: " ").count)
        var edges = chunks.indices.flatMap { i in
            chunks[i].alternatives.enumerated().dropFirst().map { Edge(from: i, to: i + 1, text: $1, cost: 0.5 * Double($0), own: true) }
        }
        for other in others { edges += spans(of: other, over: chunks) }

        // Readings the other recognizer confirms: its best guess for the same span says the same thing.
        let confirmed = Set(edges.filter { !$0.own && $0.cost == 1 }.map { "\($0.from) \($0.to) \(normalized($0.text))" })
        func isConfirmed(_ from: Int, _ to: Int, _ text: String) -> Bool {
            confirmed.contains("\(from) \(to) \(normalized(text))")
        }

        /// What swapping in `edge` is worth, or nil if it isn't worth it.
        func gain(_ edge: Edge) -> Double? {
            let top = Transcript.join(Array(tops[edge.from..<edge.to]))
            guard normalized(edge.text) != normalized(top) else { return nil }
            var cost = edge.cost
            if isConfirmed(edge.from, edge.to, top) { cost += 2 }
            if edge.own, isConfirmed(edge.from, edge.to, edge.text) { cost -= 0.75 }
            let topOdd = vocabulary.oddWords(in: top), odd = vocabulary.oddWords(in: edge.text)
            let terms = vocabulary.termCount(in: edge.text) - vocabulary.termCount(in: top)
            // Real words beat made-up ones only among the recognizer's own guesses, and only in English:
            // the other recognizer's reading of a name or a Hindi word is often an English mishearing.
            var value = edge.own && english ? 1.5 * Double(topOdd - odd) : 0
            if odd > topOdd { value -= 1.5 * Double(odd - topOdd) }
            if terms > 0, technical || topOdd > 0 { value += 3 * Double(terms) }
            if terms < 0 { value += 3 * Double(terms) }
            // Agreement alone is a coin flip ("merging" vs "mugging"); a swap needs real evidence.
            guard value > 0, value > cost else { return nil }
            return value - cost
        }

        // Best total gain up to each chunk boundary; keeping the best guess gains nothing.
        var best = [(gain: 0.0, edge: Edge?.none)] + Array(repeating: (gain: -Double.infinity, edge: Edge?.none), count: chunks.count)
        let byEnd = Dictionary(grouping: edges.compactMap { e in gain(e).map { (e, $0) } }, by: { $0.0.to })
        for k in stride(from: 1, through: chunks.count, by: 1) {
            best[k] = (best[k - 1].gain, nil)
            for (edge, g) in byEnd[k] ?? [] where best[edge.from].gain + g > best[k].gain {
                best[k] = (best[edge.from].gain + g, edge)
            }
        }
        var pieces: [String] = []
        var k = chunks.count
        while k > 0 {
            if let edge = best[k].edge {
                pieces.append(edge.text)
                k = edge.from
            } else {
                pieces.append(tops[k - 1])
                k -= 1
            }
        }
        return pieces.reversed()
    }

    /// The other recognizer's readings for runs of primary chunks whose boundaries line up in time.
    private static func spans(of other: Transcript, over chunks: [Transcript.Chunk]) -> [Edge] {
        let tolerance = 0.07
        var edges: [Edge] = []
        for (i, chunk) in chunks.enumerated() {
            guard let a = other.chunks.firstIndex(where: { abs($0.start - chunk.start) <= tolerance }) else { continue }
            for b in a..<min(a + 8, other.chunks.count) {
                guard let j = chunks[i...].firstIndex(where: { abs($0.end - other.chunks[b].end) <= tolerance }) else {
                    continue
                }
                if a == b {
                    edges += other.chunks[a].alternatives.enumerated().map {
                        Edge(from: i, to: j + 1, text: $1, cost: 1 + 0.5 * Double($0))
                    }
                } else {
                    let text = Transcript.join(other.chunks[a...b].map { $0.alternatives[0] })
                    edges.append(Edge(from: i, to: j + 1, text: text, cost: 1))
                }
            }
        }
        return edges
    }

    /// Lowercase words without punctuation, so "Imagine, " and " imagine" compare equal.
    static func normalized(_ text: String) -> String {
        text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }.joined(separator: " ")
    }
}
