import Foundation
import Testing
@testable import Babble

/// A transcript from (start, end, alternatives) chunks.
private func transcript(_ locale: String, _ confidence: Double, _ chunks: [(Double, Double, [String])]) -> Transcript {
    Transcript(locale: locale, confidence: confidence, chunks: chunks.map { .init(start: $0.0, end: $0.1, alternatives: $0.2) })
}

@MainActor
@Test func takesVocabularyReadingFromTheOtherRecognizer() {
    let english = transcript("en_IN", 0.94, [(0, 0.84, ["Codex can use "]), (0.84, 1.44, ["Imagine, ", "imagine, "]), (1.44, 2, ["so give it the images."])])
    let hindi = transcript("hi_IN", 0.91, [(0, 0.9, ["Codex can use"]), (0.9, 1.44, [" Imagen,", " Imagine,"]), (1.44, 2, [" so give it the images."])])
    #expect(Decoder.decode([english, hindi], vocabulary: vocabulary)?.text == "Codex can use Imagen, so give it the images.")
}

@MainActor
@Test func swapsMadeUpWordForOwnRealAlternative() {
    let english = transcript("en_IN", 0.9, [(0, 0.4, ["SSSH", "SSH"]), (0.4, 1, [" into the server."])])
    #expect(Decoder.decode([english], vocabulary: vocabulary)?.text == "SSH into the server.")
}

@MainActor
@Test func agreementAloneChangesNothing() {
    let english = transcript("en_IN", 0.9, [(0, 0.6, ["Any idea when they're"]), (0.6, 1, [" merging", " mugging"])])
    let hindi = transcript("hi_IN", 0.8, [(0, 0.6, ["Any idea when they're"]), (0.6, 1, [" mugging"])])
    #expect(Decoder.decode([english, hindi], vocabulary: vocabulary)?.text == "Any idea when they're merging")
}

@MainActor
@Test func leavesHinglishAlone() {
    let hindi = transcript("hi_IN", 0.94, [(0, 1, ["Aaj Shaam ko hum sab Milkar khana khane chalenge"])])
    let english = transcript("en_IN", 0.42, [(0, 0.3, ["Aaj,"]), (0.3, 1, [" Sam Ko, Hum, Sab, Milkar, Khana, Kane"])])
    #expect(Decoder.decode([hindi, english], vocabulary: vocabulary)?.text == "Aaj shaam ko hum sab milkar khana khane chalenge")
}

@MainActor
@Test func joinsSplitTermTheRecognizerAlsoSpelled() {
    let vocabulary = Vocabulary(lines: ["subagents: sub agents"])
    let english = transcript("en_IN", 0.8, [(0, 0.5, ["Spin up two"]), (0.5, 1, [" sub agents", " subagents"]), (1, 2, [" and go."])])
    #expect(Decoder.decode([english], vocabulary: vocabulary)?.text == "Spin up two subagents and go.")
    let unsure = transcript("en_IN", 0.8, [(0, 0.5, ["Spin up two"]), (0.5, 1, [" sub agents"]), (1, 2, [" and go."])])
    #expect(Decoder.decode([unsure], vocabulary: vocabulary)?.text == "Spin up two sub agents and go.")
}
