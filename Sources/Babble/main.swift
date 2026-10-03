import AVFoundation
import AppKit
import Speech

// `Babble --transcribe <file>` runs a recording through the same pipeline and prints the raw and
// cleaned text. Useful for checking models and cleanup without a mic or hotkey.
let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--transcribe"), flag + 1 < arguments.count {
    try await Transcribers.prepare()
    let dictation = Dictation()
    let asset = AVURLAsset(url: URL(fileURLWithPath: arguments[flag + 1]))
    let source = try await AssetInputSequenceProvider.provider(from: asset, compatibleWith: dictation.modules)
    let start = ContinuousClock.now
    for try await input in source.analyzerInputs { dictation.append(input) }
    let raw = try await dictation.finish()
    let transcribed = ContinuousClock.now
    print("raw:     \(raw)  (\(transcribed - start))")
    print("cleaned: \(await Cleanup.run(raw))  (\(ContinuousClock.now - transcribed))")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
app.run()
