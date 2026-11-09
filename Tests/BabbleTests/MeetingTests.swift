import Testing
@testable import Babble

@MainActor
@Test func rendersMergingASpeakersBackToBackLines() {
    let lines = [
        Line(start: 4, speaker: .me, text: "Hi."),
        Line(start: 9, speaker: .me, text: "Can you hear me?"),
        Line(start: 12, speaker: .them, text: "Yes."),
        Line(start: 3700, speaker: .them, text: "Bye."),
    ]
    #expect(MeetingTranscript.render(lines) == [
        "[00:00:04] Me: Hi. Can you hear me?",
        "[00:00:12] Them: Yes.",
        "[01:01:40] Them: Bye.",  // past the merge window, so it starts a new line
    ])
}

@Test func packsWithinBudgetAndAlwaysMakesProgress() {
    let budget = 1000
    let small = Array(repeating: String(repeating: "a", count: budget / 3), count: 7)
    #expect(Notes.pack(small, minimumGroup: 1, budget: budget).allSatisfy { $0.joined().count <= budget })
    // Items bigger than the budget still pair up when merging, so each round halves the count.
    let huge = Array(repeating: String(repeating: "a", count: budget * 2), count: 5)
    #expect(Notes.pack(huge, minimumGroup: 2, budget: budget).map(\.count) == [2, 2, 1])
    #expect(Notes.pack(huge, minimumGroup: 1, budget: budget).map(\.count) == [1, 1, 1, 1, 1])
}
