import AVFoundation
import AppKit

// `Babble --transcribe <file> [--hindi]` runs a file through the same pipeline and prints the text.
// Useful for checking models and accuracy without a mic or hotkey.
let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--transcribe"), flag + 1 < arguments.count {
    let language: Language = arguments.contains("--hindi") ? .hindi : .english
    try await language.prepare()
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: arguments[flag + 1]))
    let dictation = Dictation(language: language)
    let start = ContinuousClock.now
    while file.framePosition < file.length {
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        try file.read(into: buffer)
        dictation.append(AudioChunk(buffer: buffer, time: nil))
    }
    print(try await dictation.finish())
    print("(\(ContinuousClock.now - start))")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
app.run()
