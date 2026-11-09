import Foundation
import FoundationModels

/// Turns a meeting transcript into Granola-style notes with Apple's on-device model. A meeting rarely
/// fits the model's context, so the transcript is condensed in parts (during the meeting, as it
/// grows) and the parts are merged into the final notes at the end.
enum Notes {
    /// Permissive guardrails, because meetings talk about anything and this only rewrites what was said.
    static let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    /// Why notes can't be made on this Mac right now, or nil if they can.
    static var unavailableReason: String? {
        switch model.availability {
        case .available: nil
        case .unavailable(let reason): "\(reason)"
        }
    }

    /// Characters of input per request: about 40% of the context at a cautious 3 characters per token,
    /// leaving room for instructions and the reply.
    static var budget: Int { model.contextSize * 12 / 10 }

    private static let condenseInstructions = """
        You turn part of a meeting transcript into notes. Each line is `[time] Speaker: text`. "Me" is \
        the person taking the notes; "Them" is everyone else on the call. The transcript comes from \
        speech recognition, so read past small mistakes. Who said or agreed to something comes only \
        from the label at the start of its line: "I" inside a Them line is one of them, never Me.
        Write Markdown only, no preamble:
        - One `### ` heading per topic discussed, each followed by short `- ` bullets covering what was \
        said, decided or asked. Keep names, numbers and dates exactly.
        - Then `### Action items` with `- [ ] Owner: task` for every commitment or follow-up. Owner is \
        Me, Them, or a name if one was said. Leave the section out if there are none.
        Only include what is in the input. Never invent details.
        """

    private static let mergeInstructions = """
        You merge partial notes from one meeting, given in order, into the final meeting notes.
        Write Markdown only, no preamble, in exactly this shape:
        The first line is `# ` followed by a short title naming what the meeting was about.
        Then one `### ` heading per topic with concise `- ` bullets. Each topic gets exactly one heading: \
        when the same topic appears in several parts, combine them under one heading and drop repeated \
        bullets. Keep names, numbers and dates exactly, and keep the order things came up in.
        End with `### Action items`, listing every action item as `- [ ] Owner: task` with duplicates \
        merged, or `- None` if there are none.
        Only include what is in the input. Never invent details.
        """

    private static let titleInstructions = """
        Reply with only a short title, three to seven words, naming what this meeting was about.
        """

    /// Notes for one part of the transcript, in the shape `merge` expects.
    static func condense(_ transcript: String) async throws -> String {
        try await respond(condenseInstructions, transcript)
    }

    /// Merges partial notes into the final notes, merging in rounds when they don't fit at once.
    static func merge(_ partials: [String]) async throws -> String {
        var parts = partials
        while parts.count > 1, parts.joined(separator: "\n\n").count > budget {
            var merged: [String] = []
            for group in pack(parts, minimumGroup: 2) {
                merged.append(try await respond(condenseInstructions, group.joined(separator: "\n\n")))
            }
            parts = merged
        }
        let notes = try await respond(mergeInstructions, parts.joined(separator: "\n\n"))
        // The model often skips the title, so ask for it on its own; the notification shows it.
        if notes.hasPrefix("# ") { return notes }
        let title = try await respond(titleInstructions, notes).split(separator: "\n").first ?? "Meeting notes"
        return "# \(title.trimmingCharacters(in: CharacterSet(charactersIn: "#*\" ")))\n\n\(notes)"
    }

    /// The full pass over a finished transcript's lines, for `--notes`.
    static func make(fromLines lines: [String]) async throws -> String {
        var partials: [String] = []
        for part in pack(lines, minimumGroup: 1) { partials.append(try await condense(part.joined(separator: "\n"))) }
        return try await merge(partials)
    }

    /// Groups consecutive items so each group's text fits the budget. Groups never hold fewer than
    /// `minimumGroup` items (except a lone last one), so merging in rounds always makes progress.
    static func pack(_ items: [String], minimumGroup: Int, budget: Int = budget) -> [[String]] {
        var groups: [[String]] = []
        var current: [String] = []
        var size = 0
        for item in items {
            if current.count >= minimumGroup, size + item.count > budget {
                groups.append(current)
                current = []
                size = 0
            }
            current.append(item)
            size += item.count + 2
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// One request. If the input still overflows the context, it is condensed in halves first.
    private static func respond(_ instructions: String, _ input: String) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: instructions)
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: model.contextSize / 4)
        do {
            let reply = try await session.respond(to: input, options: options).content
            // The model sometimes doubles bullet markers ("- - point").
            return reply.replacing(/(?m)^(\s*)- (?:- )+/, with: { "\($0.1)- " })
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch LanguageModelError.contextSizeExceeded where input.count > 400 {
            let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
            let half = lines.count > 1 ? lines.count / 2 : 0
            let pieces = half > 0
                ? [lines[..<half].joined(separator: "\n"), lines[half...].joined(separator: "\n")]
                : [String(input.prefix(input.count / 2)), String(input.dropFirst(input.count / 2))]
            var condensed: [String] = []
            for piece in pieces { condensed.append(try await condense(piece)) }
            return try await respond(instructions, condensed.joined(separator: "\n\n"))
        }
    }
}
