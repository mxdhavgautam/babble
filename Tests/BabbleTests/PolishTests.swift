import Foundation
import Testing
@testable import Babble

@MainActor
let vocabulary = Vocabulary(lines: [
    "# comment", "Hetzner: head centre, head center", "Tailscale", "Tailnet: tail nut", "Cloudflare", "Convex", "IP", "DNS", "GPT",
    "Grok: groc, grop", "Sol: soul, seoul", "Behenchod: bhenshod", "Badiya: bariya", "Codex", "Imagen", "SSH",
    "AGENTS.md: agents md", "hill climb: he'll climb", "main: Maine",
    "[context]", "server", "model", "merge", "project",
    "[personal]", "Kestrel",
])

@MainActor
@Test(arguments: [
    ("I'm dictating this in English, convex, head centre, tail scale, tail nut, cloudflur.",
     "I'm dictating this in English, Convex, Hetzner, Tailscale, Tailnet, Cloudflare."),
    ("arey bhenshod bhai sahab bariya hai", "Arey Behenchod bhai sahab Badiya hai"),
    ("check the dns and ip address", "Check the DNS and IP address"),
    ("Open C slash user slash project.", "Open C/user/project."),
    ("go to tilda slash projects slash babble", "Go to ~/projects/babble"),
    ("open tilde slash code", "Open ~/code"),
    ("Please slash the price.", "Please slash the price."),
    ("Open tilde slash.", "Open tilde slash."),
    ("src slash main slash app", "Src/main/app"),
    ("The server IP is 102.154.234.2.", "The server IP is 102.154.234.2."),
    // Real words are replaced when the sentence is technical...
    ("where Jev, GPT6, Seoul, and Luna fit", "Where Jev, GPT6, Sol, and Luna fit"),
    ("yaar head center wala server down hai", "Yaar Hetzner wala server down hai"),
    // ...and made-up words always are.
    ("Groc 4.7 fell short", "Grok 4.7 fell short"),
    // A version number marks a model name: Grog is a drink, Grog 4.7 is Grok.
    ("grop 4.7 and soul 2.1 shipped", "Grok 4.7 and Sol 2.1 shipped"),
    ("update the agents.md file", "Update the AGENTS.md file"),
    ("He'll climb this project", "Hill climb this project"),
    ("then merge it into Maine", "Then merge it into main"),
    ("this chat is on kestrel", "This chat is on Kestrel"),
    ("ask for a 2nd opinion, the 1st thing", "Ask for a second opinion, the first thing"),
    ("due on the 2nd of November", "Due on the 2nd of November"),
    ("run caffeinate dash D now", "Run caffeinate -d now"),
    ("Caffeinate – D", "Caffeinate -d"),
    ("open till/projects/babble", "Open ~/projects/babble"),
    ("save it until the/downloads/reports", "Save it ~/downloads/reports"),
    ("the config is J-S-O-N", "The config is JSON"),
    ("after a 6.one review", "After a 6.1 review"),
])
func polishes(raw: String, expected: String) {
    #expect(Polish.apply(raw, vocabulary: vocabulary) == expected)
}

@MainActor
@Test(arguments: [
    "my soul is tired",  // a real word with no technical context stays
    "the convex lens and a head centre",
    "tail, scale",  // punctuation splits the run
    "the convention center",
    "maine bas yahan pe ye wala part rakha hai",  // Hindi "maine", not the branch
    "a dash of salt",
    "I bought it – a bargain",
    "the x-y plane",
    "the main two problems",
])
func leavesOtherWordsAlone(raw: String) {
    #expect(Polish.apply(raw, vocabulary: vocabulary).lowercased() == raw.lowercased())
}

/// The vocabulary that ships with the app, so real sentences are checked against all of it.
@MainActor
let bundled: Vocabulary = {
    let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Resources/vocabulary.txt")
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    return Vocabulary(lines: text.split(whereSeparator: \.isNewline).map(String.init))
}()

@MainActor
@Test(arguments: [
    ("yaar head center wala server kal raat fir se down ho gaya Tha to maine pul request merge kar di",
     "Yaar Hetzner wala server kal raat fir se down ho gaya Tha to maine pul request merge kar di"),
    ("namaste aaj Shaam ko hum sab Milkar khana khane chalenge tum bhi aa jaana",
     "Namaste aaj Shaam ko hum sab Milkar khana khane chalenge tum bhi aa jaana"),
    ("Theo and Ben break down a packed week of AI releases from opus 5.5 insane release to Groc 4.7 falling short of the hype.",
     "Theo and Ben break down a packed week of AI releases from Opus 5.5 insane release to Grok 4.7 falling short of the hype."),
    ("They then dig into why post-training matters where Jev, GPT 6, Seoul, and Luna fit, and more.",
     "They then dig into why post-training matters where Jev, GPT 6, Sol, and Luna fit, and more."),
    ("Thank you to general translation and paper for sponsoring.",
     "Thank you to general translation and paper for sponsoring."),
    ("I went for a walk in the park and my soul felt light.",
     "I went for a walk in the park and my soul felt light."),
    ("The nickel price went up.", "The nickel price went up."),
    ("Anything in the read me that needs to be updated after this?",
     "Anything in the README that needs to be updated after this?"),
    ("Can you read me the list?", "Can you read me the list?"),
    ("T3 code is my primary orchestrator, whether it's codex, clot code, cursor, or whatever. It should not be limited to this cloud code.",
     "T3 Code is my primary orchestrator, whether it's Codex, Claude Code, Cursor, or whatever. It should not be limited to this Claude Code."),
])
func bundledVocabulary(raw: String, expected: String) {
    #expect(bundled.terms.count > 300)
    #expect(Polish.apply(raw, vocabulary: bundled) == expected)
}

@MainActor
@Test func ignoresMalformedVocabularyLines() {
    let vocabulary = Vocabulary(lines: [":", " : groc", "Grok: groc"])
    #expect(vocabulary.terms.map(\.spelling) == ["Grok"])
}

@MainActor
@Test func keepsFilenamesThatAreAlreadyRight() {
    let vocabulary = Vocabulary(lines: [".env: dot env", "[context]", "file"])
    #expect(Polish.apply("open the .env file", vocabulary: vocabulary) == "Open the .env file")
    #expect(Polish.apply("open the .ENV file", vocabulary: vocabulary) == "Open the .env file")
    #expect(Polish.apply("read it from the env file", vocabulary: vocabulary) == "Read it from the env file")
    #expect(Polish.apply("read it from the dot env file", vocabulary: vocabulary) == "Read it from the .env file")
}

@MainActor
@Test func personalEntryKeepsItsTrustWhenBundledToo() {
    let vocabulary = Vocabulary(lines: ["Convex", "[personal]", "Convex"])
    #expect(Polish.apply("I use convex daily", vocabulary: vocabulary) == "I use Convex daily")
}

@MainActor
@Test func personalEntryWinsSoundAlikes() {
    let vocabulary = Vocabulary(lines: ["Convex", "[personal]", "Convex"])
    #expect(Polish.apply("I use convecks daily", vocabulary: vocabulary) == "I use Convex daily")
}

@MainActor
@Test func personalEntryKeepsBundledMishearingsAndWinsCollisions() {
    let vocabulary = Vocabulary(lines: ["Hetzner: head centre", "Claude: clod", "[context]", "server", "[personal]", "Hetzner", "Grok: clod"])
    #expect(Polish.apply("check the head centre server", vocabulary: vocabulary) == "Check the Hetzner server")
    #expect(Polish.apply("ask clod on the server", vocabulary: vocabulary) == "Ask Grok on the server")
}
