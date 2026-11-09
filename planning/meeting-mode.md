# Meeting mode plan

Branch `nightly`, never merged into main. The README covers usage and trade-offs. This file records the decisions and their status.

## Decisions (agreed 9 Nov 2026)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Hotkey | ⌥T toggles start and stop. The "†" it used to type is gone. |
| 2 | Speakers | Me is the mic and Them is system audio. No diarization. |
| 3 | Transcription timing | Live, line by line, while the meeting runs. |
| 4 | Output | `~/Babble/Meetings/<yyyy-MM-dd HHmm>/transcript.md` and `notes.md`, mode 0600. |
| 5 | Audio | Never saved. Text only. |
| 6 | Notes source | Transcript only, no typed notes from you. |
| 7 | Notes format | One fixed Granola-style template: title, one heading per topic, action items. |
| 8 | Echo | Voice processing echo cancellation on the meeting mic only. |
| 9 | Dictation during a meeting | Off. |
| 10 | System audio | Core Audio process tap, not ScreenCaptureKit. |
| 11 | Recognizers | `en_IN` and `hi_IN` plus the decoder, on both streams. |
| 12 | Long transcripts | Rolling partial notes during the meeting, merged when you stop. |
| 13 | Indicator | Small pill with Me and Them meters and a timer. |
| 14 | When notes are ready | Notification that opens notes.md when clicked. |
| 15 | Regenerating notes | `--notes <dir>` CLI. |
| 16 | Discard | ⌥Esc deletes the meeting, with no confirmation. |
| 17 | Transcript lines | `[hh:mm:ss] Speaker: text`, merging a speaker's back-to-back lines. |
| 18 | README | A new README for this branch, replacing the old one. |

## Code map

- `MeetingAudio.swift`: `VoiceMic` (the voice processing audio unit, driven directly) and `SystemAudio` (process tap plus private aggregate device).
- `MeetingTranscript.swift`: `Segmenter` cuts a stream into utterances and runs each one through `Dictation` and `Decoder`. `MeetingTranscript` keeps the lines in order and rewrites the file. `MeetingFolder` handles paths and private writes.
- `Notes.swift`: condense, merge in rounds, separate title request, halving when the context overflows.
- `MeetingSession.swift`: one meeting from start to stop, the rolling notes, and `Notifier`.
- `MeetingPill.swift`: the indicator.
- `AppController.swift`: ⌥T and ⌥Esc wiring, and the guard that keeps dictation off during a meeting.
- `main.swift`: `--meeting <seconds>` and `--notes <dir>`.

## Tested on 9 Nov 2026 (powerbook, Echo Dot over Bluetooth as output)

- `--notes` on a 10-line sample took 5 to 7 s. On a 22k-character transcript it split and merged in about 20 s. The context is 8,192 tokens.
- `--meeting 45` while `say` played a two-voice dialog through the speaker. The Them transcript came out word for word, with no Me lines. This turned out not to prove echo cancellation. See below.
- The app bundle with real hotkeys: ⌥T started a meeting, the pill showed the timer and meters, and ⌥T stopped it. Notes were written about 5 s later and the notification permission prompt appeared. ⌥Esc deleted the folder.

## Me side fixed on 9 Nov 2026 (demo recording)

- The first take with a real voice had no Me lines. The log showed `Meeting mic failed` with error -10875 on every meeting. `AVAudioEngine` with voice processing fails to initialize its output node on this Mac, with the Echo Dot and with the laptop speakers as output. The session logged the error and carried on with Them only, so every earlier meeting was Them only too.
- `VoiceMic` now drives the `AUVoiceProcessingIO` unit directly: input enabled, silence rendered to the output side, ducking at the minimum. The real-time callbacks live outside the `@MainActor` class, since the first version crashed on Swift 6's isolation check on Core Audio's thread.
- Check with `--meeting 24`: speech played on the laptop speakers while the Echo Dot was the default output came out as Me (and as Them, since the tap hears every output). Speech played on the Echo Dot came out as Them only, so echo cancellation removes the call audio from Me.
- Not checked yet: reopening when devices change mid-meeting (AirPods). The unit is stopped, uninitialized and started again on a default input or output change.

## Open items

- Madhav to test with a real call. Check that your own voice shows up as Me, and how Them sounds on headphones compared with speakers.
- If running four recognizers at once is too slow, run only `en_IN` on system audio.
- Prompt tuning for repeated topics and missed action items. Merge rounds reuse the transcript prompt for partial notes. A separate prompt for them would be cleaner.

## Review follow-ups (Sol and Fable approved after 2 rounds)

- If the output device changes its sample rate mid-meeting, the tap format may go stale, because it's read once at start. Not verified.
- After a mic restart that changes the input format, the utterance in progress may lose its tail. The next utterance starts clean.
- The "notes…" pill from a stopped meeting can overlap a new meeting's pill.
- `Segmenter.pending` keeps finished tasks until the meeting ends.
- `Dictation.finish` has a 10 s timeout. Raise it for meetings if four recognizers turn out slow.
