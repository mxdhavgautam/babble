# Babble nightly: meeting mode

This branch adds a meeting mode to Babble, the push-to-talk dictation app. It is an experiment and won't be merged into main.

Press **⌥T** to start a meeting and **⌥T** again to stop. While it runs, Babble transcribes your mic as "Me" and everything the Mac plays as "Them". The transcript is written live. When you stop, Apple's on-device model turns the transcript into notes laid out like Granola's: a title, one heading per topic, and a list of action items. **⌥Esc** throws the meeting away.

Nothing leaves the Mac. Speech recognition and notes both run on device.

Dictation works as before: hold **⌥D**, talk, let go. It's turned off while a meeting is running.

## Run it

You need macOS 27 with Apple Intelligence turned on, and the Xcode 27 command line tools.

```sh
./scripts/make-signing-cert.sh   # once, so macOS remembers permissions across rebuilds
./scripts/install.sh
```

`install.sh` replaces `~/Applications/Babble.app` with this build. To try it without replacing your installed copy, build the bundle the same way into `build/Babble.app` and run `build/Babble.app/Contents/MacOS/Babble`. Your installed copy keeps ⌥D, and only this one answers ⌥T.

macOS asks for three permissions the first time:

- Microphone, when Babble starts.
- System Audio Recording, at the first meeting. If you deny it, the "Them" side records silence and doesn't report an error. Change it under System Settings > Privacy & Security > Screen & System Audio Recording.
- Notifications, when the first notes are ready.

## What you get

Each meeting gets its own folder, `~/Babble/Meetings/<yyyy-MM-dd HHmm>/`, which only your user can read:

- `transcript.md`, rewritten a few seconds after each utterance ends, with lines like `[00:12:03] Them: so the plan is...`. A speaker's back-to-back lines are merged, up to two minutes per line.
- `notes.md`, written after you stop. Babble then posts a notification, and clicking it opens the notes.

Babble saves text only, never audio.

A small black pill sits in the bottom-right corner during a meeting. It shows a red dot, the elapsed time, a white level bar for Me and a blue one for Them. After you stop, it shows "notes…" until the notes are written.

## How it works

1. **Mic.** The meeting mic goes through Apple's voice processing audio unit. `AVAudioEngine`'s voice processing fails to start on macOS 27, so Babble drives the unit directly. The voice processing cancels the call audio coming out of your speakers, so the other side doesn't get transcribed a second time as you. It also has ducking turned down to the minimum, so the call stays loud.
2. **System audio.** A Core Audio process tap records a mono mix of everything the Mac plays.
3. **Transcription.** Each stream is cut into utterances at pauses of 0.8 seconds. Long speeches get cut at 30 to 40 seconds. Every utterance goes through the same pipeline as a dictation: the `en_IN` and `hi_IN` recognizers run side by side, then the decoder picks the best reading and applies your vocabulary.
4. **Notes.** On this Mac the model's context holds 8,192 tokens. That covers about five minutes of talk once you leave room for the reply. So Babble condenses the transcript into partial notes during the meeting, once it has a full request's worth of settled lines. When you stop, it condenses the rest and merges the parts into the final notes. If the parts are too big to merge in one go, it merges them in rounds. Short meetings are ready about 5 seconds after you stop.

## Trade-offs

- **Me and Them come from the audio source, not from voices.** Everyone on the call is "Them", and two remote people talking in a row land on one merged line. The model sometimes credits "I'll do it" from a Them line to Me.
- **Pauses are found by loudness, with a fixed threshold of -45 dBFS.** A noisy room never looks quiet, so utterances there only end at the 30 to 40 second limit. That still works, but lines take longer to show up.
- **Dictation keeps its own mic path.** Voice processing could make dictation worse. A hand-written mic path was tried before and pushed the word error rate from 9.4% to 13.2%, so only meetings use voice processing.
- **The tap records everything the Mac plays**, including music and notification sounds. It doesn't follow a single app.
- **A Core Audio tap instead of ScreenCaptureKit.** The tap needs only the System Audio Recording permission. ScreenCaptureKit would need full screen recording and show the purple indicator the whole time.
- **The model is small.** Notes sometimes repeat a topic under two headings or miss an action item. `--notes` reruns them from the transcript, which also helps when tuning the prompts in `Sources/Babble/Notes.swift`.
- **Four recognizers can run at once** when both sides talk over each other, two per stream. That hasn't been load tested yet. If it turns out to be too much, the fallback is to run only `en_IN` on system audio.
- **There's no confirmation on ⌥Esc.** It deletes the meeting folder straight away.
- **The rolling notes wait for settled lines.** They only use lines that started at least 75 seconds ago, so nothing still being transcribed gets skipped. The last minute or so is condensed after you stop.

## Commands

```sh
swift test
# Record a meeting for 60 seconds without the hotkey, then write the transcript and notes.
.build/debug/Babble --meeting 60
# Rewrite notes.md from a meeting's transcript.md.
.build/debug/Babble --notes ~/Babble/Meetings/"2026-11-09 1906"
/usr/bin/log stream --info --predicate 'subsystem == "dev.babble.app"'
```

When you run the bare binary from a terminal, macOS asks for mic and system audio permission on behalf of the terminal app, and no notification is posted.

## Uninstall

`./scripts/uninstall.sh` removes the app, its settings, permissions, vocabulary and dictation history. It leaves `~/Babble/Meetings` alone, so delete that folder yourself if you want the meetings gone.
