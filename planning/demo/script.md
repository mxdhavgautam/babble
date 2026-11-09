# Demo video

One 2-minute take on the laptop, recorded by `take.py`. The camera, the mic and the screen go into the same file. During the demo you're on a pretend call: the "Them" lines play on the speakers and you answer as "Me", so your voice shows up in the transcript as it happens. `merge.py` then cuts the take into the finished video.

The lines and timings live in `timeline.json`. Change them there and the teleprompter, recorder and merge all follow.

## Recording

1. Sit at the laptop with your face in the middle of the camera. Keep the room quiet, and keep the speaker volume where you'd have it on a call.
2. Run `python3 planning/demo/take.py --rehearse` once to practise. It shows only the teleprompter and records nothing.
3. Run `python3 planning/demo/take.py` for the real take. The laptop screen shows the live transcript, with a narrow teleprompter centred right under the camera, so reading it looks like eye contact. It counts down from 8 and then runs for 2 minutes.
4. Read the green **YOU** lines. Stay quiet during **THEM** and **WAIT**. A bar under each line shows how much time you have left for it.
5. Run `python3 planning/demo/merge.py "<take folder>"`, using the folder `take.py` printed. It writes `~/Movies/Babble demo/babble-demo.mp4`.

If a take runs a second or two long, `--cut A:B` on merge.py drops a pause (A to B seconds after the start, ending where a section starts) so the end still fits. The final video used `--cut 65.55:67`. A fluffed line just means another take. Each take gets its own folder under `~/Movies/Babble demo/takes/`.

## What you say

| Time | On screen | Line |
|---|---|---|
| 0:00 | You, full frame, name in the corner | Hi, I'm Madhav, and this is Babble, my Mac dictation app. I built it because I speak my prompts. That feels more natural than typing, and it gives the model more context. |
| 0:14 | Slide: why I built Babble | I used to dictate in the Codex app, but it had to stay open, and it was heavy. |
| 0:22 | Same slide | So Babble runs offline, on Apple's Neural Engine. I had it before Granola added dictation. And now it does meetings too. |
| 0:31 | Live transcript. Babble presses ⌥T | *(quiet)* |
| 0:32 | Them, on the speaker | Hi! Quick check before Friday. Is the beta ready to ship? |
| 0:37 | You | Almost. There are two crash bugs left, and I'll fix them by Thursday. |
| 0:43 | Them | Great. Legal also needs the analytics list before we submit. |
| 0:48 | You | Sure, I'll send that list to legal today. Talk Thursday! |
| 0:53 | Babble presses ⌥T to stop | *(quiet)* |
| 0:55 | The notes appear | That's it. Every line showed up as me or them while we talked. Now Apple's on-device model writes the notes and action items. |
| 1:07 | Slide: how I built it | I built this with Claude Opus 5.5 in T3 Code, my orchestrator of choice. We planned it together, then it built and tested the app. Claude Fable 5.1 and GPT 6.1 Sol reviewed it. |
| 1:22 | Slide: simple and secure | I kept it simple. It reuses Babble's speech pipeline, only needs audio permission, and saves text only I can read. I skipped meeting detection and speaker ID. |
| 1:34 | Slide: where the AI failed | The AI wasn't always right. It first said to assume headphones, but I pushed for echo cancellation, and it got that working. The reviewers caught a race that lost notes. |
| 1:48 | Slide: weakest part, next | The weakest part is the small notes model. It repeats topics and mishears names. Next, I'd enforce the format and test longer calls. Thanks for watching! |

## How it maps to the brief

- **Why it exists:** the intro and the slide on why I built Babble.
- **What it does, features added:** the live demo, then the slide on simple and secure choices.
- **AI tools, planning and handoff, how the agent helped build and debug:** the slide on how I built it.
- **What was cut:** the slide on simple and secure choices.
- **Where the AI failed and how it was corrected:** its own slide.
- **Weakest part and what's next:** the last slide.

## Files

- `timeline.json` has every line, its timing and which visual goes with it.
- `take.py` records a take. `teleprompter.html` is the teleprompter under the camera, and `live.zsh` shows the transcript and notes.
- `micrec.swift` records your voice with Apple's voice processing. macOS cuts other apps off the mic while a meeting's voice-processed mic runs, so ffmpeg records only the screen and camera, stamped with clock time, and the merge lines everything up by time.
- `merge.py` builds the video from a take.
- `slides.html` and `lower-third.html` are the source for the PNGs in `~/Movies/Babble demo/assets`. Each slide renders at 1920x1080 with headless Chrome, using `slides.html#w`, `#a`, `#c`, `#d` and `#e`.
