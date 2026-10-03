# Babble

Push-to-talk dictation for macOS that never leaves your Mac.

Hold **⌥D**, speak, let go. The text is pasted into whatever field has focus.

| Shortcut | Action |
| --- | --- |
| Hold **⌥D** | Record |
| Release | Transcribe and paste |
| **Esc** while holding | Discard |

- **Offline.** Apple's on-device speech models. No network, no account, no cloud.
- **English and Hinglish** from one shortcut. Both recognizers run on every recording and the more confident one wins.
- **Knows your jargon.** About 400 AI and dev terms are spelled right: Hetzner, Tailscale, vLLM, Opus, Grok.
- **Light.** No window, no Dock icon. When idle it uses no CPU and the mic is off.

## Install

Requires macOS 27 and the Xcode 27 command line tools.

```sh
./scripts/make-signing-cert.sh   # once
./scripts/install.sh             # build, sign, install to ~/Applications, launch
```

Then:

1. Allow **Microphone** when asked.
2. Turn on **Babble** in System Settings > Privacy & Security > **Accessibility**. Babble needs this to paste.

Speech models download once on first launch. Babble starts itself at login.

> [!TIP]
> If soft speech gets missed, raise the input level in System Settings > Sound > Input. Around 55% works well for built-in mics.

The signing script creates a local self-signed certificate, so macOS remembers the permissions across rebuilds.

## How it works

1. **Capture.** Each press records from the current default input, so AirPods, USB mics and the built-in mic all just work.
2. **Transcribe.** `en_IN` and `hi_IN` `SpeechTranscriber`s run side by side. The transcript with higher confidence wins. Hindi comes out in Latin letters.
3. **Polish.** An instant rule-based pass fixes vocabulary and spoken paths, then capitalizes the first letter. It never rewords anything.
4. **Paste.** Babble swaps the text onto the clipboard, sends ⌘V, then restores your clipboard.

## Vocabulary

Speech recognizers mangle names: "groc", "tail scale", "head centre". Babble ships a list of about 400 terms in [`Resources/vocabulary.txt`](Resources/vocabulary.txt), covering models, labs, coding tools, frameworks, infra, benchmarks, people and acronyms.

Add your own in `~/Library/Application Support/Babble/vocabulary.txt`. Changes apply on the next dictation.

```
# One term per line. Known mishearings go after a colon.
Hetzner
Grok: groc, grock

# Lines after [context] are never replaced. They only mark a sentence as technical.
[context]
deploy
```

Context decides when a word gets replaced:

| Heard | Rule | Example |
| --- | --- | --- |
| Not an English word | Always replaced | "groc 4.7" → Grok 4.7 |
| Ordinary English word | Only in a technical sentence | "GPT 6, Seoul and Luna" → Sol, but "my soul felt light" stays |
| Garbled single word | Closest-sounding term, in a technical sentence | "cloudflur" → Cloudflare |

A sentence counts as technical when it contains another vocabulary term or a context word.

> [!NOTE]
> Everyday words in the list, like "React" or "Linear", are only recased in technical sentences. There they are recased even when you meant the ordinary word.

## Spoken paths

Saying "slash" joins words into a path:

| Said | Pasted |
| --- | --- |
| "c slash users slash projects" | `C/users/projects` |
| "tilde slash projects slash babble" | `~/projects/babble` |

## Development

Run a recording through the full pipeline without the mic:

```sh
say -o /tmp/t.wav --data-format=LEI16@16000 "deploy it to hetzner"
~/Applications/Babble.app/Contents/MacOS/Babble --transcribe /tmp/t.wav
```

Run the tests:

```sh
swift test
```

Watch the logs (mic start time, time from release to paste, errors):

```sh
/usr/bin/log stream --info --predicate 'subsystem == "dev.babble.app"'
```
