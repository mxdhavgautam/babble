import Foundation

/// Deterministic post-processing of a transcript: vocabulary spellings, spoken path separators
/// ("c slash users" → "C/users"), and a capitalized first letter. Instant, and never rewords.
enum Polish {
    static func apply(_ text: String, vocabulary: Vocabulary) -> String {
        var tokens = text.split(separator: " ").map { Token(String($0)) }
        tokens = vocabulary.respell(tokens)
        tokens = joinPaths(tokens)
        var result = tokens.map(\.text).joined(separator: " ")
        if let first = result.first, first.isLowercase {
            result.replaceSubrange(...result.startIndex, with: first.uppercased())
        }
        return result
    }

    /// Glues "a slash b" into "a/b"; "tilde slash" becomes "~/".
    private static func joinPaths(_ tokens: [Token]) -> [Token] {
        var out: [Token] = []
        var glueNext = false
        for token in tokens {
            let word = token.core.lowercased()
            if word == "slash" || word == "backslash", !out.isEmpty, out[out.count - 1].trailing.isEmpty {
                let last = out[out.count - 1]
                let root = ["tilde", "tilda"].contains(last.core.lowercased()) ? "~" : last.text
                out[out.count - 1] = Token(root + (word == "slash" ? "/" : "\\"))
                glueNext = true
            } else if glueNext {
                out[out.count - 1] = Token(out[out.count - 1].text + token.text)
                glueNext = false
            } else {
                out.append(token)
            }
        }
        return out
    }
}

/// A whitespace-separated word split into surrounding punctuation and its core ("(Hello," → "(", "Hello", ",").
struct Token {
    let leading: String
    let core: String
    let trailing: String

    var text: String { leading + core + trailing }

    init(_ raw: String) {
        let start = raw.firstIndex { $0.isLetter || $0.isNumber } ?? raw.endIndex
        let end = raw.lastIndex { $0.isLetter || $0.isNumber }.map(raw.index(after:)) ?? start
        leading = String(raw[..<start])
        core = start < end ? String(raw[start..<end]) : ""
        trailing = String(raw[max(start, end)...])
    }

    init(leading: String, core: String, trailing: String) {
        self.leading = leading
        self.core = core
        self.trailing = trailing
    }
}

/// User terms (names, tools, slang) that the recognizer tends to mangle. Lives outside the repo at
/// ~/Library/Application Support/Babble/vocabulary.txt, one term per line, optionally followed by
/// known mishearings: `Badiya: bariya, badhiya`. Lines starting with # are comments.
struct Vocabulary {
    struct Term {
        let spelling: String
        let letters: Set<String>  // spelling and aliases, lowercased letters only
        let sound: String  // rough phonetic skeleton of the spelling
    }

    let terms: [Term]

    static let fileURL = URL.applicationSupportDirectory.appending(path: "Babble/vocabulary.txt")

    static func load() -> Vocabulary {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return Vocabulary(lines: []) }
        return Vocabulary(lines: text.split(whereSeparator: \.isNewline).map(String.init))
    }

    init(lines: [String]) {
        terms = lines.compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: ":", maxSplits: 1)
            let spelling = parts[0].trimmingCharacters(in: .whitespaces)
            let aliases = parts.count > 1 ? parts[1].split(separator: ",").map(String.init) : []
            return Term(
                spelling: spelling,
                letters: Set(([spelling] + aliases).map(Self.letters)),
                sound: Self.sound(of: spelling))
        }
    }

    /// Replaces runs of 1-3 words that spell, or sound like, a term. Longest runs win.
    func respell(_ tokens: [Token]) -> [Token] {
        guard !terms.isEmpty else { return tokens }
        var out: [Token] = []
        var i = 0
        scan: while i < tokens.count {
            for length in stride(from: min(3, tokens.count - i), through: 1, by: -1) {
                let run = tokens[i..<(i + length)]
                // A comma or period inside the run means separate words, not one term.
                guard run.dropLast().allSatisfy({ $0.trailing.isEmpty }),
                    let term = match(run.map(\.core).joined())
                else { continue }
                out.append(Token(leading: run.first!.leading, core: term.spelling, trailing: run.last!.trailing))
                i += length
                continue scan
            }
            out.append(tokens[i])
            i += 1
        }
        return out
    }

    private func match(_ spoken: String) -> Term? {
        let letters = Self.letters(spoken)
        guard !letters.isEmpty, letters.count == spoken.count else { return nil }  // words only, no digits
        if let exact = terms.first(where: { $0.letters.contains(letters) }) { return exact }
        // Sound-alike matching only for longer terms, where accidental collisions are rare.
        guard letters.count >= 5 else { return nil }
        let sound = Self.sound(of: letters)
        return terms.first { term in
            term.sound.count >= 4
                && (term.sound == sound || (term.sound.count >= 5 && Self.isOneEditApart(term.sound, sound)))
        }
    }

    static func letters(_ text: String) -> String {
        text.lowercased().filter(\.isLetter)
    }

    /// Consonant skeleton with similar sounds merged: "Hetzner" and "head centre" → "htsnr"/"htsntr",
    /// "Behenchod" and "bhenshod" → "pnst". Keeps the first letter so short words stay distinct.
    static func sound(of text: String) -> String {
        var s = letters(text)
        for (pattern, replacement) in [("sch", "s"), ("sh", "s"), ("ch", "s"), ("ph", "f"), ("ck", "k"), ("x", "ks")] {
            s = s.replacingOccurrences(of: pattern, with: replacement)
        }
        let chars = Array(s)
        var out = ""
        for (index, char) in chars.enumerated() {
            let next = index + 1 < chars.count ? chars[index + 1] : " "
            let mapped: Character? =
                switch char {
                case "a", "e", "i", "o", "u", "y", "h", "w": index == 0 ? "a" : nil
                case "c": "eiy".contains(next) ? "s" : "k"
                case "q", "g": "k"
                case "z", "j": "s"
                case "d": "t"
                case "b": "p"
                case "v": "f"
                default: char
                }
            if let mapped, out.last != mapped { out.append(mapped) }
        }
        return out
    }

    private static func isOneEditApart(_ a: String, _ b: String) -> Bool {
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                i += 1; j += 1
                continue
            }
            edits += 1
            if edits > 1 { return false }
            if a.count > b.count { i += 1 } else if b.count > a.count { j += 1 } else { i += 1; j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
    }
}
