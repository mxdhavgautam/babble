import AppKit
import UserNotifications

/// One meeting, from ⌥T to ⌥T: captures the mic (Me) and system audio (Them), writes a live
/// transcript, condenses it into partial notes as it grows, and writes the final notes on stop.
@MainActor
final class MeetingSession {
    enum Failure: Error { case noAudio }

    /// Lines older than this are settled: anything still being transcribed started later.
    /// Covers the longest utterance (`Segmenter.hardLimit`) plus the recognizers' finishing time.
    private static let settleDelay = 75.0

    let folder: URL
    private let origin = ContinuousClock.now
    private let transcript: MeetingTranscript
    private let voiceMic = VoiceMic()
    private let systemAudio = SystemAudio()
    private let pill = MeetingPill()
    private var segmenters: [Segmenter] = []
    /// Partial notes so far, in order, and how far into the meeting (seconds) they cover.
    private var partials: [String] = []
    private var condensedUntil = 0.0
    private var condensing: Task<Void, Never>?
    /// Set once stop begins, so no new rolling batch can claim lines the final pass needs.
    private var stopping = false

    init() throws {
        let started = Date()
        folder = try MeetingFolder.create(for: started)
        transcript = MeetingTranscript(url: folder.appending(path: "transcript.md"), started: started)
    }

    /// Starts both captures. Carries on with one if the other fails; throws only if neither starts.
    func start() throws {
        let onLine: @MainActor @Sendable (Line) -> Void = { [weak self] line in
            guard let self else { return }
            transcript.add(line)
            condenseIfReady()
        }
        let me = Segmenter(speaker: .me, origin: origin, onLine: onLine)
        let them = Segmenter(speaker: .them, origin: origin, onLine: onLine)
        do {
            try voiceMic.start { me.feed($0) }
            segmenters.append(me)
        } catch {
            log.error("Meeting mic failed: \(error)")
            voiceMic.stop()
        }
        do {
            try systemAudio.start { them.feed($0) }
            segmenters.append(them)
        } catch {
            log.error("System audio failed: \(error)")
            systemAudio.stop()
        }
        guard !segmenters.isEmpty else { throw Failure.noAudio }
        pill.show(since: origin) { [me, them] in [me.level, them.level] }
        log.info("Meeting started in \(self.folder.path, privacy: .public)")
    }

    /// Stops recording, finishes the transcript and writes notes.md, then posts a notification.
    func stop() async {
        stopping = true
        stopCapture()
        pill.showProcessing()
        for segmenter in segmenters { await segmenter.finish() }
        await condensing?.value
        let notesURL = folder.appending(path: "notes.md")
        let notes = await finalNotes()
        MeetingFolder.write(notes + "\n", to: notesURL)
        pill.hide()
        let title = notes.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) }
        await Notifier.shared.post(title: "Meeting notes ready", body: title ?? folder.lastPathComponent, opening: notesURL)
        log.info("Meeting notes written to \(notesURL.path, privacy: .public)")
    }

    /// Stops recording and deletes everything written so far.
    func discard() {
        stopCapture()
        pill.hide()
        transcript.discarded = true
        condensing?.cancel()
        for segmenter in segmenters { segmenter.cancel() }
        do { try FileManager.default.removeItem(at: folder) } catch { log.error("Discarding meeting failed: \(error)") }
        log.info("Meeting discarded")
    }

    private func stopCapture() {
        voiceMic.stop()
        systemAudio.stop()
    }

    /// Condenses the next stretch of settled transcript once there's a full request's worth,
    /// so most of the work is done by the time the meeting ends.
    private func condenseIfReady() {
        guard condensing == nil, !stopping, !transcript.discarded, Notes.unavailableReason == nil else { return }
        let settled = (ContinuousClock.now - origin) / .seconds(1) - Self.settleDelay
        let candidates = transcript.lines.filter { $0.start >= condensedUntil && $0.start < settled }
        guard candidates.reduce(0, { $0 + $1.text.count }) >= Notes.budget else { return }
        var size = 0
        let part = Array(candidates.prefix { line in
            defer { size += line.text.count + 20 }
            return size == 0 || size + line.text.count <= Notes.budget
        })
        condensedUntil = part.count < candidates.count ? candidates[part.count].start : part.last!.start + 0.001
        let text = MeetingTranscript.render(part).joined(separator: "\n")
        condensing = Task { [weak self] in
            do {
                let partial = try await Notes.condense(text)
                guard let self, !Task.isCancelled else { return }
                partials.append(partial)
            } catch {
                // The final pass can't recover this stretch, so say so in the notes rather than hide it.
                log.error("Condensing meeting notes failed: \(error)")
                self?.partials.append("### Missing notes\n- Notes for part of the meeting could not be generated: \(error)")
            }
            self?.condensing = nil
            self?.condenseIfReady()
        }
    }

    private func finalNotes() async -> String {
        if let reason = Notes.unavailableReason {
            return """
                # Notes unavailable

                Apple Intelligence isn't available (\(reason)). The transcript is in transcript.md. \
                Run `Babble --notes "\(folder.path)"` to try again later.
                """
        }
        let rest = transcript.lines.filter { $0.start >= condensedUntil }
        guard !partials.isEmpty || !rest.isEmpty else { return "# No notes\n\nNothing was transcribed." }
        do {
            for part in Notes.pack(MeetingTranscript.render(rest), minimumGroup: 1) {
                partials.append(try await Notes.condense(part.joined(separator: "\n")))
            }
            return try await Notes.merge(partials)
        } catch {
            log.error("Writing meeting notes failed: \(error)")
            return """
                # Notes failed

                \(error)

                The transcript is in transcript.md. Run `Babble --notes "\(folder.path)"` to try again.
                """
        }
    }
}

/// Posts notifications and opens the attached file when one is clicked.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = Notifier()

    /// Call at launch so clicks on notifications from earlier runs still open their file.
    func install() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func post(title: String, body: String, opening url: URL) async {
        // Notifications need an app bundle; the bare binary run from the CLI has none.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                log.error("Notifications are turned off for Babble")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = ["path": url.path]
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        } catch {
            log.error("Posting notification failed: \(error)")
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let path = response.notification.request.content.userInfo["path"] as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Babble is never frontmost, but show the banner even if it somehow is.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
