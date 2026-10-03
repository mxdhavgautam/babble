import AppKit

/// Deterministic post-processing of a transcript: vocabulary spellings, spoken path separators
/// ("c slash users" → "C/users"), and a capitalized first letter. Instant, and never rewords.
@MainActor
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

    /// Turns spoken paths into real ones: "c slash users slash projects" → "C/users/projects",
    /// "tilde slash code" → "~/code". A single "slash" only counts after a drive letter or tilde,
    /// so "please slash the price" stays prose.
    private static func joinPaths(_ tokens: [Token]) -> [Token] {
        func separator(_ token: Token) -> String? {
            guard token.leading.isEmpty, token.trailing.isEmpty else { return nil }
            switch token.core.lowercased() {
            case "slash": return "/"
            case "backslash": return "\\"
            default: return nil
            }
        }

        var out: [Token] = []
        var i = 0
        while i < tokens.count {
            var path = tokens[i].text
            var j = i
            var separators = 0
            // Extend while "<segment> slash <segment>" continues and no punctuation breaks it.
            while j + 2 < tokens.count, tokens[j].trailing.isEmpty, let sep = separator(tokens[j + 1]) {
                path += sep + tokens[j + 2].text
                separators += 1
                j += 2
            }
            let first = tokens[i].core.lowercased()
            let rooted = first.count == 1 || first == "tilde" || first == "tilda"
            if separators >= 2 || (separators == 1 && rooted) {
                if first == "tilde" || first == "tilda" { path = tokens[i].leading + "~" + path.dropFirst(tokens[i].text.count) }
                out.append(Token(path))
                i = j + 1
            } else {
                out.append(tokens[i])
                i += 1
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

/// Terms the recognizer tends to mangle: names, tools, models, slang. Babble ships a general AI and
/// developer list in the app bundle; personal additions go in
/// ~/Library/Application Support/Babble/vocabulary.txt. Format, one per line:
///
///     Term
///     Term: known mishearing, another       (e.g. `Grok: groc`)
///     [context]                             (following lines are context words, never replaced)
///
/// Replacing a real English word ("Seoul" → Sol, "convex" → Convex) only happens when the transcript
/// is clearly technical: it contains another vocabulary term or a context word. Words that aren't
/// ordinary English ("groc" → Grok) are always replaced.
@MainActor
struct Vocabulary {
    struct Term {
        let spelling: String
        let key: String  // lowercased letters and digits: "T3 Code" → "t3code", and "Ai2" never matches "AI"
        let aliases: Set<String>
        let sound: String
    }

    let terms: [Term]
    let contextWords: Set<String>

    static let userFileURL = URL.applicationSupportDirectory.appending(path: "Babble/vocabulary.txt")
    static let bundledFileURL = Bundle.main.url(forResource: "vocabulary", withExtension: "txt")

    private static var cache: (stamp: [Date?], vocabulary: Vocabulary)?

    /// Bundled list plus the user's file; reparsed only when either file changes.
    static func load() -> Vocabulary {
        let urls = [bundledFileURL, userFileURL].compactMap(\.self)
        let stamp = urls.map { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        if let cache, cache.stamp == stamp { return cache.vocabulary }
        let lines = urls.flatMap { url in
            ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline).map(String.init) + ["[terms]"]
        }
        let vocabulary = Vocabulary(lines: lines)
        _ = shortDictionaryWords.count  // load now rather than during someone's first dictation
        cache = (stamp, vocabulary)
        return vocabulary
    }

    init(lines: [String]) {
        var terms: [Term] = []
        var context: Set<String> = []
        var inContext = false
        for line in lines {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.lowercased() == "[context]" || line.lowercased() == "[terms]" {
                inContext = line.lowercased() == "[context]"
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if inContext {
                context.insert(line.lowercased())
                continue
            }
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let spelling = parts[0].trimmingCharacters(in: .whitespaces)
            guard !spelling.isEmpty else { continue }  // e.g. a stray ":" line
            let aliases = parts.count > 1 ? parts[1].split(separator: ",").map { Self.key(String($0)) } : []
            terms.append(
                Term(
                    spelling: spelling, key: Self.key(spelling), aliases: Set(aliases.filter { !$0.isEmpty }),
                    sound: Self.sound(of: spelling)))
        }
        self.terms = terms
        contextWords = context
    }

    /// How sure a match is, which decides whether it needs the sentence to look technical.
    private enum Confidence {
        case certain  // not ordinary words: "groc" → Grok. Always applied, and signals context.
        case likely  // "tail scale" → Tailscale, "cloudflur" → Cloudflare. Needs context, and signals it.
        case contextual  // one ordinary word: "convex" → Convex, "Seoul" → Sol. Needs context.
    }

    private struct Match {
        let range: Range<Int>
        let term: Term
        let confidence: Confidence
    }

    /// Replaces runs of 1-3 words that spell, or sound like, a term. Longest runs win.
    func respell(_ tokens: [Token]) -> [Token] {
        guard !terms.isEmpty else { return tokens }
        var matches: [Match] = []
        var i = 0
        while i < tokens.count {
            let found = stride(from: min(3, tokens.count - i), through: 1, by: -1).lazy.compactMap { length in
                match(tokens[i..<(i + length)])
            }.first
            if let found {
                matches.append(found)
                i = found.range.upperBound
            } else {
                i += 1
            }
        }

        let matchedIndices = Set(matches.flatMap { Array($0.range) })
        let hasSignal = matches.contains { $0.confidence == .certain }
            || tokens.indices.contains { !matchedIndices.contains($0) && isContextSignal(tokens[$0]) }
        func applies(_ match: Match) -> Bool {
            match.confidence == .certain || hasSignal
                || matches.contains { $0.range != match.range && $0.confidence != .contextual }
        }

        var out: [Token] = []
        var index = 0
        for match in matches where applies(match) {
            out += tokens[index..<match.range.lowerBound]
            let run = tokens[match.range]
            out.append(Token(leading: run.first!.leading, core: match.term.spelling, trailing: run.last!.trailing))
            index = match.range.upperBound
        }
        return out + tokens[index...]
    }

    private func match(_ run: ArraySlice<Token>) -> Match? {
        // A comma or period inside the run means separate words, not one term.
        guard run.dropLast().allSatisfy({ $0.trailing.isEmpty }) else { return nil }
        let spoken = run.map(\.core).joined()
        let key = Self.key(spoken)
        // Letters and digits only ("T3 code" yes, "5.5" no).
        guard !key.isEmpty, key.count == spoken.count, key.contains(where: \.isLetter) else { return nil }
        let range = run.startIndex..<run.endIndex
        func confidence(for term: Term) -> Confidence {
            guard run.allSatisfy({ Self.isEnglishWord($0.core, comparedTo: term) }) else { return .certain }
            return run.count > 1 ? .likely : .contextual
        }

        if let term = terms.first(where: { $0.key == key }) {
            guard run.map(\.core).joined(separator: " ") != term.spelling else { return nil }
            return Match(range: range, term: term, confidence: confidence(for: term))
        }
        if let term = terms.first(where: { $0.aliases.contains(key) }) {
            return Match(range: range, term: term, confidence: confidence(for: term))
        }
        // Sound-alike guesses: only for single non-words ("cloudflur"), never for correctly spelled
        // English like "request" or "merge", and only against longer terms.
        guard run.count == 1, key.count >= 5, key.allSatisfy(\.isLetter), !Self.isEnglishWord(run.first!.core)
        else { return nil }
        let sound = Self.sound(of: key)
        let term = terms.first { term in
            term.sound.count >= 4
                && (term.sound == sound || (term.sound.count >= 6 && Self.isOneEditApart(term.sound, sound)))
        }
        return term.map { Match(range: range, term: $0, confidence: .likely) }
    }

    /// A context word, or a term already written exactly as spelled ("GPT6" counts for GPT).
    private func isContextSignal(_ token: Token) -> Bool {
        let letters = token.core.filter(\.isLetter)
        return contextWords.contains(token.core.lowercased())
            || (!letters.isEmpty && terms.contains { $0.spelling.filter(\.isLetter) == letters })
    }

    private static var wordCache: [String: Bool] = [:]

    /// Whether `word` is ordinary English. The spell checker accepts short abbreviations ("ip", "dns"),
    /// so for acronym terms short words are checked against the system dictionary instead ("ai" and
    /// "rag" are words). Longer words ("nickel" for NCCL) go to the spell checker as usual.
    static func isEnglishWord(_ word: String, comparedTo term: Term) -> Bool {
        if term.spelling.filter(\.isUppercase).count >= 2, word.count <= 5 {
            return shortDictionaryWords.contains(word.lowercased())
        }
        return isEnglishWord(word)
    }

    static func isEnglishWord(_ word: String) -> Bool {
        if let known = wordCache[word] { return known }
        let miss = NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        let isWord = miss.location == NSNotFound
        wordCache[word] = isWord
        return isWord
    }

    private static let shortDictionaryWords: Set<String> = {
        let text = (try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8)) ?? ""
        return Set(text.split(whereSeparator: \.isNewline).lazy.filter { $0.count <= 5 }.map { $0.lowercased() })
    }()

    static func key(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
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
