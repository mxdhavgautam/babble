# Babble

Push-to-talk dictation for macOS that runs entirely on your Mac. Hold a shortcut, speak, let go, and the text is pasted into whatever field has focus. No network, no cloud, no app window.

- **⌥D** (hold): dictate, release to paste
- **Esc** while holding: discard

English and Hindi recognizers (Apple's on-device `SpeechTranscriber`, `en_IN` and `hi_IN`) run side by side on each recording and the more confident transcript wins, so English and Hinglish both work from one shortcut. Hindi comes out in Latin letters. An instant rule-based pass then fixes vocabulary and spoken paths ("c slash users" → `C/users`).

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

The recognizer often mangles names and jargon ("groc", "tail scale", "head centre"). Babble fixes them from a vocabulary of about 400 terms that AI engineers say out loud: models, labs, coding tools, frameworks, infra, people and acronyms. It ships in [`Resources/vocabulary.txt`](Resources/vocabulary.txt) and is installed with the app.

Personal additions go in `~/Library/Application Support/Babble/vocabulary.txt`. Changes apply on the next dictation.

```
# One term per line, known mishearings after a colon.
Hetzner
Grok: groc, grock
# Lines after [context] are never replaced, only mark a sentence as technical.
[context]
deploy
```

Replacements depend on context:

- Words that aren't English ("groc" → Grok, "hetsner" → Hetzner) are always replaced.
- Ordinary words are only replaced when the sentence looks technical, meaning it contains another vocabulary term or a context word. "Where GPT 6, Seoul and Luna fit" becomes Sol; "my soul felt light" stays.
- Sound-alike guesses ("cloudflur" → Cloudflare) are only made for single non-English words, and need the same context.

## Testing without a mic

```sh
say -o /tmp/t.wav --data-format=LEI16@16000 "hello from babble"
~/Applications/Babble.app/Contents/MacOS/Babble --transcribe /tmp/t.wav   # raw and polished text
```

## Logs

```sh
log stream --info --predicate 'subsystem == "dev.babble.app"'
```
