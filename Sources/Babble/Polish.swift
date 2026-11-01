import AppKit

/// Deterministic post-processing of a transcript: vocabulary spellings, spoken path separators
/// ("c slash users" → "C/users"), and a capitalized first letter. Instant, and never rewords.
@MainActor
enum Polish {
    /// `hindi` marks text from the Hindi recognizer, which capitalizes words mid-sentence at random.
    /// `heard` holds keys of terms the recognizer itself spelled out in some reading (see `Vocabulary.spelled`).
    static func apply(_ text: String, vocabulary: Vocabulary, hindi: Bool = false, heard: Set<String> = []) -> String {
        var tokens = text.split(separator: " ").map { Token(String($0)) }
        if hindi { tokens = lowercaseStrayCapitals(tokens, vocabulary: vocabulary) }
        // Paths first, so their parts stay as spoken: "~/projects/babble", not ".../Babble".
        tokens = joinPaths(tokens)
        tokens = joinSpelledLetters(tokens)
        tokens = vocabulary.respell(tokens, heard: heard)
        tokens = fixDecimals(tokens)
        tokens = numberProducts(tokens, vocabulary: vocabulary)
        tokens = spellOrdinals(tokens)
        tokens = joinFlags(tokens)
        var result = tokens.map(\.text).joined(separator: " ")
        if let first = result.first, first.isLowercase {
            result.replaceSubrange(...result.startIndex, with: first.uppercased())
        }
        return result
    }

    /// "Thik hai, So kal Milkar" → "Thik hai, so kal milkar". Keeps sentence starts, terms, acronyms
    /// and proper nouns the spell checker only knows capitalized ("Singapore", "Thursday"). Names it
    /// also accepts in lowercase ("Delhi") lose their capital; rare next to the stray capitals fixed.
    private static func lowercaseStrayCapitals(_ tokens: [Token], vocabulary: Vocabulary) -> [Token] {
        tokens.enumerated().map { i, token in
            let word = token.core
            guard i > 0, !tokens[i - 1].trailing.contains(where: { ".?!".contains($0) }),
                word.count > 1, word.first!.isUppercase, word.dropFirst().allSatisfy(\.isLowercase),
                vocabulary.index[Vocabulary.key(word)]?.spelling.first?.isUppercase != true
            else { return token }
            let lower = word.lowercased()
            if Vocabulary.isEnglishWord(word), !Vocabulary.isEnglishWord(lower) { return token }
            return Token(leading: token.leading, core: lower, trailing: token.trailing)
        }
    }

    private static let numbers = ["two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
                                  "eight": "8", "nine": "9", "ten": "10"]

    /// Versions after a name: "DualShock four" → "DualShock 4". Leaves "one" alone ("the Grok one"),
    /// and lowercase terms that are ordinary words ("the main two problems").
    private static func numberProducts(_ tokens: [Token], vocabulary: Vocabulary) -> [Token] {
        tokens.enumerated().map { i, token in
            let name = i > 0 ? tokens[i - 1].core : ""
            guard let digits = numbers[token.core.lowercased()], i > 0, tokens[i - 1].trailing.isEmpty,
                name.contains(where: { $0.isUppercase || $0.isNumber }),
                vocabulary.index[Vocabulary.key(name)]?.spelling == name
            else { return token }
            return Token(leading: token.leading, core: digits, trailing: token.trailing)
        }
    }

    /// "6.one" → "6.1": the recognizer sometimes spells out the digit after a decimal point.
    private static func fixDecimals(_ tokens: [Token]) -> [Token] {
        tokens.map { token in
            guard let dot = token.core.firstIndex(of: "."), token.core[..<dot].allSatisfy(\.isNumber), dot != token.core.startIndex,
                let digits = (numbers.merging(["one": "1", "zero": "0"]) { a, _ in a })[token.core[token.core.index(after: dot)...].lowercased()]
            else { return token }
            return Token(leading: token.leading, core: token.core[...dot] + digits, trailing: token.trailing)
        }
    }

    private static let ordinals = ["1st": "first", "2nd": "second", "3rd": "third", "4th": "fourth", "5th": "fifth",
                                   "6th": "sixth", "7th": "seventh", "8th": "eighth", "9th": "ninth"]
    private static let months: Set<String> = ["january", "february", "march", "april", "may", "june", "july",
                                              "august", "september", "october", "november", "december"]

    /// The English recognizer writes "1st" even in prose: "the 1st thing" → "the first thing".
    /// Dates keep their digits: "the 2nd of November", "October 3rd".
    private static func spellOrdinals(_ tokens: [Token]) -> [Token] {
        tokens.enumerated().map { i, token in
            guard let word = ordinals[token.core.lowercased()] else { return token }
            let next = i + 1 < tokens.count ? tokens[i + 1].core.lowercased() : ""
            let previous = i > 0 ? tokens[i - 1].core.lowercased() : ""
            guard next != "of", !months.contains(next), !months.contains(previous) else { return token }
            let core = token.core.first!.isUppercase || i == 0 ? word.capitalized : word
            return Token(leading: token.leading, core: core, trailing: token.trailing)
        }
    }

    /// Letters spelled out with hyphens become one word: "J-S-O-N" → "JSON". Needs three or more,
    /// so "the x-y plane" stays.
    private static func joinSpelledLetters(_ tokens: [Token]) -> [Token] {
        tokens.map { token in
            let parts = token.core.split(separator: "-")
            guard parts.count >= 3, parts.allSatisfy({ $0.count == 1 && $0.first!.isLetter }) else { return token }
            return Token(leading: token.leading, core: parts.joined().uppercased(), trailing: token.trailing)
        }
    }

    /// Spoken command-line flags: "caffeinate dash D" or "Caffeinate – D" → "caffeinate -d".
    private static func joinFlags(_ tokens: [Token]) -> [Token] {
        var out: [Token] = []
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            let isDash = token.core.lowercased() == "dash" || (token.core.isEmpty && ["-", "–", "—"].contains(token.text))
            // A typed dash before "a" or "I" is prose: "I bought it – a bargain".
            let isProse = token.core.isEmpty && i + 1 < tokens.count && ["a", "I"].contains(tokens[i + 1].core)
            if isDash, !isProse, token.trailing.isEmpty, i + 1 < tokens.count,
                tokens[i + 1].leading.isEmpty, tokens[i + 1].core.count == 1, tokens[i + 1].core.first!.isLetter
            {
                let leading = token.core.isEmpty ? "" : token.leading
                out.append(Token(leading: leading, core: "-" + tokens[i + 1].core.lowercased(), trailing: tokens[i + 1].trailing))
                i += 2
            } else {
                out.append(token)
                i += 1
            }
        }
        return out
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
            let tilde = tildes.contains(first)
            if separators >= 2 || (separators == 1 && (first.count == 1 || tilde)) {
                if tilde { path = tokens[i].leading + "~" + path.dropFirst(tokens[i].text.count) }
                out.append(Token(path))
                i = j + 1
            } else if let slash = first.firstIndex(of: "/"),
                tildes.contains(String(first[..<slash])) || (first.hasPrefix("today/") && first.filter { $0 == "/" }.count >= 2)
            {
                // The recognizer wrote the path itself but misheard tilde: "till/projects/babble",
                // or "today/projects/babble" (two slashes, so "today/tomorrow" stays prose).
                let core = tokens[i].core
                out.append(Token(leading: tokens[i].leading, core: "~" + core[core.firstIndex(of: "/")!...], trailing: tokens[i].trailing))
                i += 1
            } else if first.hasPrefix("the/"), ["until", "till"].contains(out.last?.core.lowercased()), out.last?.trailing.isEmpty == true {
                // Tilde heard as "until the": "save it until the/downloads" → "save it ~/downloads".
                let core = tokens[i].core
                out[out.count - 1] = Token(leading: out.last!.leading, core: "~" + core.dropFirst(3), trailing: tokens[i].trailing)
                i += 1
            } else {
                out.append(tokens[i])
                i += 1
            }
        }
        return out
    }

    /// How "~" comes out of the recognizer.
    private static let tildes: Set<String> = ["tilde", "tilda", "till", "tild"]
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
        var aliases: Set<String>
        let sound: String
        /// From the user's own list rather than the bundled one.
        var personal = false
    }

    let terms: [Term]
    let contextWords: Set<String>
    /// Every term's key and alias keys, for quick lookups. Spellings win over aliases.
    let index: [String: Term]
    /// Aliases written with capitals only match exactly that: `main: Maine` fixes "merge into Maine"
    /// without touching the Hindi "maine".
    private let exactAliases: [String: Term]
    /// Each term's letters as spelled, so "GPT6" can be recognized as a mention of GPT.
    private let spelledLetters: Set<String>

    /// `BABBLE_VOCABULARY` points evals at a fixed personal list instead of the real one.
    static let userFileURL = ProcessInfo.processInfo.environment["BABBLE_VOCABULARY"].map { URL(fileURLWithPath: $0) }
        ?? URL.applicationSupportDirectory.appending(path: "Babble/vocabulary.txt")
    static let bundledFileURL = Bundle.main.url(forResource: "vocabulary", withExtension: "txt")

    private static var cache: (stamp: [Date?], vocabulary: Vocabulary)?

    /// Bundled list plus the user's file; reparsed only when either file changes.
    static func load() -> Vocabulary {
        let urls = [bundledFileURL, userFileURL].compactMap(\.self)
        let stamp = urls.map { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        if let cache, cache.stamp == stamp { return cache.vocabulary }
        let lines = urls.flatMap { url -> [String] in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let header = url == userFileURL ? ["[personal]"] : []
            return header + text.split(whereSeparator: \.isNewline).map(String.init) + ["[terms]"]
        }
        let vocabulary = Vocabulary(lines: lines)
        _ = shortDictionaryWords.count  // load now rather than during someone's first dictation
        cache = (stamp, vocabulary)
        return vocabulary
    }

    init(lines: [String]) {
        var terms: [Term] = []
        var context: Set<String> = []
        var inContext = false, personal = false
        var exact: [String: Term] = [:]
        for line in lines {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.lowercased() == "[personal]" {
                personal = true
                inContext = false
                continue
            }
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
            let written = parts.count > 1 ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } : []
            let aliases = written.filter { !$0.contains(where: \.isUppercase) }.map(Self.key)
            terms.append(
                Term(
                    spelling: spelling, key: Self.key(spelling), aliases: Set(aliases.filter { !$0.isEmpty }),
                    sound: Self.sound(of: spelling), personal: personal))
            for alias in written where alias.contains(where: \.isUppercase) { exact[alias] = terms.last }
        }
        // The user's own entry replaces a bundled one for the same word and inherits its mishearings.
        let personalKeys = Set(terms.filter(\.personal).map(\.key))
        var inherited: [String: Set<String>] = [:]
        for term in terms where !term.personal && personalKeys.contains(term.key) { inherited[term.key, default: []].formUnion(term.aliases) }
        terms = terms.filter { $0.personal || !personalKeys.contains($0.key) }.map { term in
            var term = term
            if term.personal, let aliases = inherited[term.key] { term.aliases.formUnion(aliases) }
            return term
        }
        let personalTerms = Dictionary(terms.filter(\.personal).map { ($0.key, $0) }) { first, _ in first }
        self.terms = terms
        contextWords = context
        // Spellings win over aliases, and the user's aliases over bundled ones.
        var index: [String: Term] = [:]
        for term in terms { for alias in term.aliases where index[alias] == nil || term.personal { index[alias] = term } }
        for term in terms.reversed() { index[term.key] = term }
        self.index = index
        exactAliases = exact.mapValues { personalTerms[$0.key] ?? $0 }
        spelledLetters = Set(terms.map { $0.spelling.filter(\.isLetter) }.filter { !$0.isEmpty })
    }

    /// Keys of the terms `text` writes exactly as spelled: "Codex can use Imagen" → ["codex", "imagen"].
    func spelled(in text: String) -> Set<String> {
        let words = text.split(separator: " ").map { Token(String($0)).core }
        var keys: Set<String> = []
        for i in words.indices {
            for length in 1...min(3, words.count - i) {
                let run = words[i..<(i + length)]
                if let term = index[Self.key(run.joined())], term.spelling == run.joined(separator: " ") { keys.insert(term.key) }
            }
        }
        return keys
    }

    /// How many terms `text` mentions, spelled right or as a known mishearing.
    func termCount(in text: String) -> Int {
        let keys = text.split(separator: " ").map { Self.key(String($0)) }.filter { !$0.isEmpty }
        var count = 0, i = 0
        while i < keys.count {
            let length = (1...min(3, keys.count - i)).reversed().first { index[keys[i..<(i + $0)].joined()] != nil }
            if let length { count += 1; i += length } else { i += 1 }
        }
        return count
    }

    /// How many words in `text` are neither English nor vocabulary: "hetsna", "cloudflur", "SSSH".
    func oddWords(in text: String) -> Int {
        text.split(separator: " ").map { Token(String($0)).core }.filter { word in
            !word.isEmpty && word.allSatisfy(\.isLetter) && index[Self.key(word)] == nil && !Self.isEnglishWord(word)
        }.count
    }

    /// Whether `text` reads as technical: it mentions a term or a context word.
    func isTechnical(_ text: String) -> Bool {
        termCount(in: text) > 0 || text.split(separator: " ").contains { contextWords.contains(Token(String($0)).core.lowercased()) }
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

    /// Replaces runs of 1-3 words that spell, or sound like, a term. Longest runs win. A multi-word
    /// match ("sub agents") needs no context when the term is in `heard`, meaning the recognizer
    /// considered that exact spelling ("subagents") and only split it, or when it's one of the user's
    /// own terms ("dual sense" → DualSense).
    func respell(_ tokens: [Token], heard: Set<String> = []) -> [Token] {
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
        // A term written exactly as spelled is a signal too, including multi-word ones ("Muse Spark").
        let spelled = tokens.indices.contains { i in
            (2...3).contains { length in
                guard i + length <= tokens.count else { return false }
                let words = tokens[i..<(i + length)].map(\.core)
                return index[Self.key(words.joined())]?.spelling == words.joined(separator: " ")
            }
        }
        let hasSignal = spelled || matches.contains { $0.confidence == .certain }
            || tokens.indices.contains { !matchedIndices.contains($0) && isContextSignal(tokens[$0]) }
        // The user listed their own words on purpose, so fixing just their capitals is always safe:
        // "kestrel" → Kestrel even in "this chat is on kestrel".
        func isPersonalCase(_ match: Match) -> Bool {
            match.term.personal && match.range.count == 1 && Self.key(tokens[match.range.lowerBound].core) == match.term.key
        }
        func applies(_ match: Match) -> Bool {
            match.confidence == .certain || hasSignal || isPersonalCase(match)
                || (match.confidence == .likely && (heard.contains(match.term.key) || match.term.personal))
                || matches.contains { $0.range != match.range && $0.confidence != .contextual }
        }

        var out: [Token] = []
        var index = 0
        for match in matches where applies(match) {
            out += tokens[index..<match.range.lowerBound]
            let run = tokens[match.range]
            var leading = run.first!.leading
            let lead = Self.lead(of: match.term.spelling)
            if leading.hasSuffix(lead) { leading.removeLast(lead.count) }  // ".ENV" → ".env", not "..env"
            out.append(Token(leading: leading, core: match.term.spelling, trailing: run.last!.trailing))
            index = match.range.upperBound
        }
        return out + tokens[index...]
    }

    private func match(_ run: ArraySlice<Token>) -> Match? {
        // A comma or period inside the run means separate words, not one term.
        guard run.dropLast().allSatisfy({ $0.trailing.isEmpty }) else { return nil }
        let spoken = run.map(\.core).joined()
        let key = Self.key(spoken)
        guard !key.isEmpty, key.contains(where: \.isLetter) else { return nil }
        // Letters and digits only ("T3 code" yes, "5.5" no), unless the term has the same symbols ("agents.md").
        // Apostrophes and hyphens never count: "he'll climb" and "sub-agents" can match.
        let symbols = spoken.filter { !($0.isLetter || $0.isNumber || "'’-".contains($0)) }
        let range = run.startIndex..<run.endIndex
        func confidence(for term: Term) -> Confidence {
            guard run.allSatisfy({ Self.isEnglishWord($0.core, comparedTo: term) }) else { return .certain }
            return run.count > 1 ? .likely : .contextual
        }

        if let term = exactAliases[run.map(\.core).joined(separator: " ")] {
            return Match(range: range, term: term, confidence: confidence(for: term))
        }
        if let term = index[key], symbols.allSatisfy(term.spelling.contains) {
            // Already right, counting punctuation the spelling starts with: ".env" is written ".", "env".
            // Without that punctuation it's a different word: a bare "env" stays, "dot env" is the alias.
            let written = run.map(\.core).joined(separator: " ")
            let lead = Self.lead(of: term.spelling)
            guard term.key != key || (run.first!.leading.hasSuffix(lead) && lead + written != term.spelling)
            else { return nil }
            return Match(range: range, term: term, confidence: confidence(for: term))
        }
        // Sound-alike guesses: only for single non-words ("cloudflur"), never for correctly spelled
        // English like "request" or "merge", and only against longer terms.
        guard symbols.isEmpty, run.count == 1, key.count >= 5, key.allSatisfy(\.isLetter),
            !Self.isEnglishWord(run.first!.core)
        else { return nil }
        let sound = Self.sound(of: key)
        let term = terms.first { term in
            term.sound.count >= 4
                && (term.sound == sound || (term.sound.count >= 6 && Self.isOneEditApart(term.sound, sound)))
        }
        return term.map { Match(range: range, term: $0, confidence: .likely) }
    }

    /// A context word, a version number ("Grog 4.7" is a model, not a drink), or a term already
    /// written exactly as spelled ("GPT6" counts for GPT).
    private func isContextSignal(_ token: Token) -> Bool {
        let core = token.core
        let letters = core.filter(\.isLetter)
        let isVersion = core.contains(".") && core.allSatisfy { $0.isNumber || $0 == "." }
        return isVersion || contextWords.contains(core.lowercased()) || (!letters.isEmpty && spelledLetters.contains(letters))
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
        // The spell checker waves through camel case ("ReadMe", "VoFrame"); English doesn't have it.
        if word.dropFirst().contains(where: \.isUppercase), word.contains(where: \.isLowercase) {
            wordCache[word] = false
            return false
        }
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

    /// Punctuation a spelling starts with: "." for ".env", "" for most terms.
    static func lead(of spelling: String) -> String {
        String(spelling.prefix { !($0.isLetter || $0.isNumber) })
    }

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
