import AVFoundation
import AppKit
import Speech

// `Babble --transcribe <file>` runs a recording through the same pipeline and prints the raw and
// polished text. Useful for checking models and vocabulary without a mic or hotkey.
let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--transcribe"), flag + 1 < arguments.count {
    try await Transcribers.prepare()
    let dictation = Dictation()
    let asset = AVURLAsset(url: URL(fileURLWithPath: arguments[flag + 1]))
    let source = try await AssetInputSequenceProvider.provider(from: asset, compatibleWith: dictation.modules)
    let start = ContinuousClock.now
    for try await input in source.analyzerInputs { dictation.append(input) }
    let raw = try await dictation.finish()
    print("raw:      \(raw)  (\(ContinuousClock.now - start))")
    print("polished: \(Polish.apply(raw, vocabulary: .load()))")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
app.run()
