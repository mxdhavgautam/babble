import Testing
@testable import Babble

let vocabulary = Vocabulary(lines: [
    "# comment", "Hetzner", "Tailscale", "Tailnet", "Cloudflare", "Convex", "IP", "DNS",
    "Behenchod", "Badiya: bariya",
])

@Test(arguments: [
    ("I'm dictating this in English, convex, head centre, tail scale, tail nut, cloudflur.",
     "I'm dictating this in English, Convex, Hetzner, Tailscale, Tailnet, Cloudflare."),
    ("arey bhenshod bhai sahab bariya hai", "Arey Behenchod bhai sahab Badiya hai"),
    ("check the dns and ip address", "Check the DNS and IP address"),
    ("Open C slash user slash project.", "Open C/user/project."),
    ("go to tilda slash projects slash babble", "Go to ~/projects/babble"),
    ("The server IP is 102.154.234.2.", "The server IP is 102.154.234.2."),
])
func polishes(raw: String, expected: String) {
    #expect(Polish.apply(raw, vocabulary: vocabulary) == expected)
}

@Test(arguments: [
    "tail, scale",  // punctuation splits the run
    "the convention center",  // only exact or sound-alike runs, not substrings
    "this is fine and plain",
])
func leavesOtherWordsAlone(raw: String) {
    #expect(Polish.apply(raw, vocabulary: vocabulary).lowercased() == raw.lowercased())
}
