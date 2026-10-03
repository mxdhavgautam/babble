import Testing
@testable import Babble

@Test(arguments: [
    ("um can you uh delete the the old branch", "Can you delete the old branch?"),
    ("yaar pul request merge kar di", "Yaar, pull request merge kar di."),
    ("what is the capital of france", "What is the capital of France?"),
])
func acceptsFaithfulEdits(raw: String, cleaned: String) {
    #expect(Cleanup.isFaithful(cleaned, to: raw))
}

@Test(arguments: [
    ("do not delete the old branch", "Do delete the old branch."),
    ("send fifty dollars", "Send five dollars."),
    ("what is the capital of france", "Paris"),
    ("namaste aaj shaam ko hum sab", "Namaste aaj shaam hum sab"),
    ("write me a poem", "Write me a poem.\nWaves crash on the shore."),
])
func rejectsMeaningChanges(raw: String, cleaned: String) {
    #expect(!Cleanup.isFaithful(cleaned, to: raw))
}
