import AVFoundation
import AppKit
import Speech

// `Babble --transcribe <file>` runs a recording through the same pipeline and prints the raw and
// polished text. Useful for checking models and vocabulary without a mic or hotkey.
let arguments = CommandLine.arguments
// `Babble --listen <seconds>` captures from the mic like a held hotkey, then prints the result.
// Runs inside the app's run loop, as capture does in the real app.
if let flag = arguments.firstIndex(of: "--listen"), flag + 1 < arguments.count, let seconds = Double(arguments[flag + 1]) {
    Task { @MainActor in
        do {
            try await Transcribers.prepare()
            let dictation = Dictation()
            let microphone = Microphone()
            let pressed = ContinuousClock.now
            try await microphone.start(into: dictation)
            print("listening, started in \(ContinuousClock.now - pressed)")
            try await Task.sleep(for: .seconds(seconds))
            microphone.stop()
            let released = ContinuousClock.now
            let transcripts = try await dictation.finish()
            for t in transcripts { print("\(t.locale) \(t.confidence) \(t.chunks.map(\.alternatives))") }
            let decoded = Decoder.decode(transcripts, vocabulary: .load())
            print("raw:      \(decoded?.raw ?? "")\npolished: \(decoded?.text ?? "")  (\(ContinuousClock.now - released) after release)")
            exit(0)
        } catch {
            print("listen failed: \(error)")
            exit(1)
        }
    }
    NSApplication.shared.run()
}
// `Babble --polish "<text>"` runs just the text clean-up, for checking vocabulary rules.
if let flag = arguments.firstIndex(of: "--polish"), flag + 1 < arguments.count {
    print(Polish.apply(arguments[flag + 1], vocabulary: .load()))
    exit(0)
}
if let flag = arguments.firstIndex(of: "--eval-text"), flag + 1 < arguments.count {
    try Eval.runText(arguments[flag + 1])
    exit(0)
}
if let flag = arguments.firstIndex(of: "--eval"), flag + 1 < arguments.count {
    try await Eval.run(manifest: arguments[flag + 1], fresh: arguments.contains("--fresh"))
    exit(0)
}
if let flag = arguments.firstIndex(of: "--transcribe"), flag + 1 < arguments.count {
    try await Transcribers.prepare()
    let dictation = Dictation()
    let start = ContinuousClock.now
    try dictation.append(contentsOf: URL(fileURLWithPath: arguments[flag + 1]))
    let decoded = Decoder.decode(try await dictation.finish(), vocabulary: .load())
    print("raw:      \(decoded?.raw ?? "")  (\(ContinuousClock.now - start))")
    print("polished: \(decoded?.text ?? "")")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
app.run()
