import AppKit

/// Optional log of every dictation, one JSON object per line, for building a personal speech dataset.
/// Off unless `defaults write dev.babble.app keepHistory -bool true` (install.sh asks).
/// Never stores audio. Lives next to the vocabulary; scripts/uninstall.sh removes both.
enum History {
    struct Entry: Encodable {
        let time: Date
        let raw: String
        let text: String
        let recognizer: String
        let confidence: Double
        let heldSeconds: Double
        let app: String?
    }

    static let fileURL = URL.applicationSupportDirectory.appending(path: "Babble/history.jsonl")

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "keepHistory") }

    /// Bundle id of the app that will receive the paste, e.g. "com.tinyspeck.slackmacgap".
    static var frontmostApp: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

    private static let encoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func append(_ entry: Entry) {
        guard isEnabled else { return }
        do {
            var line = try encoder.encode(entry)
            line.append(0x0A)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            // Enforced on every write, so a file created or copied in with looser permissions gets fixed.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            log.error("Writing history failed: \(error)")
        }
    }
}
