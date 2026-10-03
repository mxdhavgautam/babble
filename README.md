# Babble

Push-to-talk dictation for macOS that never leaves your Mac.

Hold **⌥D**, talk, let go. Whatever you said gets pasted wherever your cursor is. **Esc** while holding throws it away.

- **Offline.** Runs on Apple's on-device speech models. No internet & no account needed.
- **English and Hinglish** from the same shortcut.
- **Knows the lingo.** ~400 AI and dev terms spelled right out of the box: Hetzner, Tailscale, vLLM, Opus, Grok.
- **Tiny.** No window, no Dock icon. The mic is off and it uses no CPU until you press the shortcut.
- **Optional history.** Keep a private log of what you dictate, if you want one. Off by default.

## Install

Needs macOS 27 and the Xcode 27 command line tools.

```sh
./scripts/make-signing-cert.sh   # once, so macOS remembers permissions across rebuilds
./scripts/install.sh
```

Allow mic access when it asks, then turn on Babble under System Settings > Privacy & Security > Accessibility (that's how it pastes). It starts at login after that.

If it misses you when you talk softly, bump your input level in System Settings > Sound. ~55% is a good spot.

## History

Off by default. `install.sh` asks once whether to keep a history of your dictations. If you say yes, each dictation becomes one line in `~/Library/Application Support/Babble/history.jsonl`:

```json
{"app":"com.tinyspeck.slackmacgap","confidence":0.844,"heldSeconds":4.2,"raw":"deploy it to head centre","recognizer":"en_IN","text":"Deploy it to Hetzner","time":"2026-10-03T08:32:45Z"}
```

`raw` is what the recognizer heard, `text` is what got pasted, `recognizer` is the language that won, and `app` is where you were typing. Text only, never audio. The file stays on your Mac and only your user can read it. Cancelled and empty dictations aren't logged.

Turn it on or off any time; it applies to the next dictation:

```sh
defaults write dev.babble.app keepHistory -bool true    # or false
```

## Uninstall

```sh
./scripts/uninstall.sh
```

This quits Babble and deletes the app (which also removes it from login items), its settings and permissions, your personal vocabulary and your history. The local signing certificate stays in your keychain in case you reinstall; remove it with:

```sh
security delete-identity -c "Babble Local Signing" ~/Library/Keychains/login.keychain-db
```

## Vocabulary

Add your own words to `~/Library/Application Support/Babble/vocabulary.txt`:

```
Hetzner
Grok: groc, grock
```

One term per line, with any common mishearings after a colon. Changes apply on the next dictation.

Words that aren't real English ("groc") always get fixed. Real words ("Seoul" → Sol) only get swapped when the sentence is clearly technical, so "GPT 6, Seoul and Luna" becomes Sol but "my soul felt light" stays put.

Saying "slash" builds a path: "tilde slash projects slash babble" → `~/projects/babble`.

## Dev

```sh
swift test
say -o /tmp/t.wav --data-format=LEI16@16000 "deploy it to hetzner"
~/Applications/Babble.app/Contents/MacOS/Babble --transcribe /tmp/t.wav
/usr/bin/log stream --info --predicate 'subsystem == "dev.babble.app"'
```
