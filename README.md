# Babble

Push-to-talk dictation for macOS that runs entirely on your Mac. Hold a shortcut, speak, let go, and the text is pasted into whatever field has focus. No network, no cloud, no app window.

- **⌥D** (hold): dictate, release to paste
- **Esc** while holding: discard

English and Hindi recognizers (Apple's on-device `SpeechTranscriber`, `en_IN` and `hi_IN`) run side by side on each recording and the more confident transcript wins, so English and Hinglish both work from one shortcut. Hindi comes out in Latin letters. A small rule-based pass then fixes your vocabulary and spoken paths ("c slash users" → `C/users`).

The UI is a small AppKit panel with a live waveform, shown only while you hold the shortcut. When idle Babble uses no CPU and keeps the mic off.

## Requirements

macOS 27, Xcode 27 command line tools.

## Install

```sh
./scripts/make-signing-cert.sh   # once: local self-signed identity so permissions survive rebuilds
./scripts/install.sh             # build, sign, copy to ~/Applications, launch
```

On first launch, grant **Microphone** and **Accessibility** (System Settings > Privacy & Security). Accessibility is needed to paste. Babble registers itself as a login item, and speech models download once on first launch.

## Vocabulary

Names and jargon the recognizer mangles go in `~/Library/Application Support/Babble/vocabulary.txt`, one per line, optionally followed by known mishearings. Changes apply on the next dictation.

```
Hetzner
Tailscale
Badiya: bariya, badhiya
```

Runs of up to three words that spell a term ("tail scale") or sound like it ("head centre" → Hetzner) are replaced. Skip terms that are also everyday words, or they will be capitalized everywhere.

## Testing without a mic

```sh
say -o /tmp/t.wav --data-format=LEI16@16000 "hello from babble"
.build/release/Babble --transcribe /tmp/t.wav   # prints raw and polished text
```

## Logs

```sh
log stream --info --predicate 'subsystem == "dev.babble.app"'
```
