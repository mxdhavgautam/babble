#!/usr/bin/env python3
"""Records one 2-minute demo take on the laptop: screen, camera and mic in one file.

    python3 planning/demo/take.py [--rehearse | --no-camera]

It runs the nightly build of Babble, a live transcript view (live.zsh in Ghostty) and a teleprompter
centred under the camera, then follows timeline.json: presses ⌥T to start and stop the meeting and plays
the "Them" lines through the speakers. You read the "YOU" lines. The take lands in
~/Movies/Babble demo/takes/<time>/ with take.mkv (screen and camera, stamped with clock time), mic.wav
(your voice, from micrec) and marks.json; merge.py turns it into the video.
--rehearse shows only the teleprompter, so you can practise the timing without recording anything.
"""
import argparse, json, os, shutil, subprocess, time
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
ROOT = Path.home() / "Movies/Babble demo"
THEM = ROOT / "assets/them"
MEETINGS = Path.home() / "Babble/Meetings"
APP = REPO / "build/Babble.app/Contents/MacOS/Babble"
LEAD = 8  # seconds of countdown on the teleprompter before t0
MICREC = ROOT / "bin/micrec"

# Laptop screen in points: 1710 wide, menu bar 37 tall. The teleprompter sits centred under the camera,
# and the transcript starts below it. Its size comes from timeline.json.
SCREEN_W, MENU = 1710, 37


def press_option_t():
    """⌥T toggles the meeting. Babble's hotkey is global, so the frontmost app doesn't matter."""
    subprocess.run(["osascript", "-e", 'tell application "System Events" to keystroke "t" using option down'], check=True)


def wait_until(epoch):
    while (left := epoch - time.time()) > 0:
        time.sleep(min(left, 0.02))


def open_teleprompter(out, t0, size):
    """A narrow Chrome app window centred right under the camera, so reading it looks like eye contact."""
    subprocess.run(["pkill", "-f", "chrome-teleprompter"])
    subprocess.run(["open", "-na", "Google Chrome", "--args", f"--user-data-dir={ROOT / 'chrome-teleprompter'}",
                    "--no-first-run", "--no-default-browser-check",
                    f"--window-position={(SCREEN_W - size['width']) // 2},{MENU}", f"--window-size={size['width']},{size['height']}",
                    f"--app=file://{out / 'teleprompter.html'}#t0={int(t0 * 1000)}"], check=True)


def build_micrec():
    """micrec records the voice-processed mic, since macOS cuts ffmpeg off the mic during a meeting."""
    source = HERE / "micrec.swift"
    if not MICREC.exists() or MICREC.stat().st_mtime < source.stat().st_mtime:
        MICREC.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-O", str(source), "-o", str(MICREC)], check=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--rehearse", action="store_true", help="teleprompter only, nothing recorded")
    p.add_argument("--no-camera", action="store_true", help="dry run: screen only, no camera or mic")
    args = p.parse_args()
    timeline = json.loads((HERE / "timeline.json").read_text())
    tp = timeline["teleprompter"]

    out = ROOT / ("rehearsal" if args.rehearse else "takes/" + datetime.now().strftime("%Y-%m-%d %H%M%S"))
    out.mkdir(parents=True, exist_ok=args.rehearse)
    shutil.copy(HERE / "teleprompter.html", out)
    (out / "timeline.js").write_text(f"window.TIMELINE = {json.dumps(timeline)};\n")

    if args.rehearse:
        open_teleprompter(out, time.time() + LEAD, tp)
        time.sleep(LEAD + timeline["length"] + 3)
        subprocess.run(["pkill", "-f", "chrome-teleprompter"])
        return

    build_micrec()
    if subprocess.run(["pgrep", "-f", "build/Babble.app/Contents/MacOS/Babble"], capture_output=True).returncode != 0:
        subprocess.Popen([str(APP)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        time.sleep(2)

    subprocess.run(["pkill", "-f", "title=Babble meeting mode"])
    time.sleep(0.5)
    subprocess.run(["open", "-na", "/Applications/Ghostty.app", "--args", "--title=Babble meeting mode", "--font-size=26",
                    "--background=000000", "--foreground=ffffff", "--window-padding-x=40", f"--window-padding-y={tp['height'] + 10},30",
                    "--macos-titlebar-style=hidden", "--confirm-close-surface=false", f"--command=/bin/zsh {HERE / 'live.zsh'}"], check=True)
    time.sleep(2)

    t0 = time.time() + LEAD
    open_teleprompter(out, t0, tp)
    # It takes a couple of seconds to start, and runs until just after the take ends.
    micrec = subprocess.Popen([str(MICREC), str(out / "mic.wav"), str(LEAD + timeline["length"] + 2)])

    wait_until(t0 - 3)
    # Every frame is stamped with the clock time it arrived, so merge.py can line the screen, the
    # camera and mic.wav up exactly.
    clock = ["-use_wallclock_as_timestamps", "1", "-f", "avfoundation", "-pixel_format", "nv12", "-framerate", "30"]
    inputs = [*clock, "-capture_cursor", "0", "-i", "2:none"]
    if not args.no_camera:
        inputs += [*clock, "-video_size", "1920x1080", "-i", "0:none"]
    maps = ["-map", "0:v"] + ([] if args.no_camera else ["-map", "1:v"])
    ffmpeg = subprocess.Popen(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *inputs, *maps, "-copyts",
                               "-c:v", "h264_videotoolbox", "-b:v", "16M", "-pix_fmt", "yuv420p",
                               str(out / "take.mkv")], stdin=subprocess.PIPE, stderr=open(out / "ffmpeg.log", "w"))
    marks = {"t0": t0}

    # Keys and Them lines, in time order.
    events = [(k["t"], "key", k["action"]) for k in timeline["keys"]]
    events += [(c["t"], "them", c["audio"]) for c in timeline["cues"] if c["who"] == "them"]
    before = set(os.listdir(MEETINGS)) if MEETINGS.exists() else set()
    players = []
    for t, kind, what in sorted(events):
        wait_until(t0 + t)
        if kind == "key":
            press_option_t()
            marks[what] = time.time() - t0
        else:
            players.append(subprocess.Popen(["afplay", str(THEM / what)]))

    # Note when notes.md appears, while the rest of the take runs.
    new = sorted(set(os.listdir(MEETINGS)) - before)
    meeting = MEETINGS / new[0] if new else None
    end = t0 + timeline["length"] + 1
    while time.time() < end:
        if meeting and "notes_ready" not in marks and (meeting / "notes.md").exists():
            marks["notes_ready"] = time.time() - t0
        time.sleep(0.2)

    ffmpeg.stdin.write(b"q"); ffmpeg.stdin.flush(); ffmpeg.wait(timeout=30)
    for pl in players: pl.wait()
    micrec.wait()
    subprocess.run(["pkill", "-f", "title=Babble meeting mode"])
    subprocess.run(["pkill", "-f", "chrome-teleprompter"])
    subprocess.run(["pkill", "-f", "build/Babble.app/Contents/MacOS/Babble"])  # frees ⌥T again
    marks["meeting"] = str(meeting) if meeting else None
    (out / "marks.json").write_text(json.dumps(marks, indent=1))
    print(out)


if __name__ == "__main__":
    main()
