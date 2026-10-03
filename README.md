# Babble

Push-to-talk dictation for macOS that runs entirely on your Mac. Hold a shortcut, speak, let go, and the text is pasted into whatever field has focus. No network, no cloud, no app window.

- **⌥D** (hold): English (India)
- **⌥⇧D** (hold): Hindi
- **Esc** while holding: discard

Transcription uses Apple's on-device `SpeechAnalyzer` / `SpeechTranscriber`. The UI is a small AppKit panel with a live waveform, shown only while you hold the shortcut. When idle Babble uses no CPU and keeps the mic off.

## Requirements

macOS 27, Xcode 27 command line tools.

## Install

```sh
./scripts/make-signing-cert.sh   # once: local self-signed identity so permissions survive rebuilds
./scripts/install.sh             # build, sign, copy to ~/Applications, launch
```

On first launch, grant **Microphone** and **Accessibility** (System Settings > Privacy & Security). Accessibility is needed to paste. Babble registers itself as a login item, and speech models download once on first launch.

## Testing without a mic

```sh
say -o /tmp/t.wav --data-format=LEI16@16000 "hello from babble"
.build/release/Babble --transcribe /tmp/t.wav            # add --hindi for Hindi
```

## Logs

```sh
log stream --info --predicate 'subsystem == "dev.babble.app"'
```
