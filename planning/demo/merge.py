#!/usr/bin/env python3
"""Turns a take from take.py into the finished 2-minute demo video.

    python3 planning/demo/merge.py "~/Movies/Babble demo/takes/<time>" [--out file.mp4] [--cut 65.3:67] [--hold 0.5]

The screen, the camera and mic.wav are all stamped with clock time, so each section of timeline.json is
cut straight out of them: the camera fills the frame for the intro, the screen recording plays during
the demo, and slides come after, with the camera in a circle in the corner. The audio is your voice from
mic.wav plus the Them lines mixed in from their files, filtered to sound like a call.

--cut A:B drops a pause from the take, from A to B seconds after t0, where B is the start of a section.
Everything after it moves earlier and the last section runs on into the take by the same amount, so a
take that ran a little long still fits the same length. --hold adds that many seconds at the end, holding
the camera's last frame, for a last word said as the footage ran out. The video fades out at the end.
"""
import argparse, json, shutil, subprocess, tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ASSETS = Path.home() / "Movies/Babble demo/assets"
W, H, FPS = 1920, 1080, 30
PIP, MARGIN = 360, 40
TP = json.loads((HERE / "timeline.json").read_text())["teleprompter"]
STRIP_BOTTOM = 2 * (37 + TP["height"]) + 6  # pixels: menu bar plus teleprompter (see take.py)

# The laptop screen below the teleprompter, fitted to 1920 wide.
SCREEN = f"crop=3420:{2224 - STRIP_BOTTOM}:0:{STRIP_BOTTOM},scale={W}:-2,pad={W}:{H}:0:(oh-ih)/2:black,setsar=1"
# The meeting pill is tiny at that scale, so a 2x copy sits left of the camera bubble while it's up.
PILL = "crop=240:100:3170:2135,scale=480:200,pad=484:204:2:2:0x555555"
PILL_XY = f"W-w-{MARGIN + PIP + 30}:H-h-{MARGIN}"


def ffmpeg(*args):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args], check=True)


def probe(path, entries):
    return subprocess.run(["ffprobe", "-v", "error", *entries, "-of", "csv=p=0", str(path)],
                          check=True, capture_output=True, text=True).stdout.split()


FADE = 0.4


def apply_cut(sections, cut):
    """Each section gets `src`, where it starts in the take. See --cut."""
    a, b = cut
    gap = b - a
    out = []
    for s in sections:
        s = dict(s, src=s["start"])
        if s["start"] < a < s["end"]:
            assert s["end"] == b, "--cut has to end where a section starts"
            s["end"] = a
        elif s["start"] >= b:
            s["start"] -= gap
            if s["end"] < sections[-1]["end"]:  # the last section keeps its end and runs longer
                s["end"] -= gap
        out.append(s)
    return out


def make_narration(mic, skip, length, timeline, out):
    """Your voice from mic.wav, starting at t0, with the Them lines mixed in at their cue times."""
    assert skip >= 0, "mic.wav starts after t0"
    them = [c for c in timeline["cues"] if c["who"] == "them"]
    inputs = ["-ss", f"{skip:.3f}", "-t", f"{length:.3f}", "-i", str(mic)]
    f = ["[0:a]highpass=f=80,aresample=48000[me]"]
    for i, c in enumerate(them, 1):
        inputs += ["-i", str(ASSETS / "them" / c["audio"])]
        ms = int(c["t"] * 1000)
        f.append(f"[{i}:a]highpass=f=300,lowpass=f=3400,volume=-4dB,aresample=48000,adelay={ms}:all=1[t{i}]")
    stems = "[me]" + "".join(f"[t{i}]" for i in range(1, len(them) + 1))
    f.append(f"{stems}amix=inputs={len(them) + 1}:normalize=0:duration=first,loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000[a]")
    ffmpeg(*inputs, "-filter_complex", ";".join(f), "-map", "[a]", "-ar", "48000", "-ac", "1", str(out))


def render(i, sec, offset, take, has_cam, narration, marks, tmp, fade=False, hold=0.0):
    d = sec["end"] - sec["start"] + hold
    src = sec["src"]
    out = tmp / f"{i:02d}.mp4"
    inputs = ["-ss", f"{offset + src:.3f}", "-t", f"{d:.3f}", "-i", str(take),
              "-ss", f"{src:.3f}", "-t", f"{d:.3f}", "-i", str(narration)]
    cam, n = "[0:1]", 2  # n is the index of the next input
    if not has_cam:  # dry run without a camera
        inputs += ["-f", "lavfi", "-t", f"{d:.3f}", "-i", "color=0x333333:s=1920x1080:r=30"]
        cam, n = "[2:v]", 3
    audio = "1:a"
    f = []

    if sec["visual"] == "camera":
        f.append(f"{cam}setpts=PTS-STARTPTS,scale={W}:{H}:force_original_aspect_ratio=increase,crop={W}:{H},setsar=1,fps={FPS}[base]")
        if "overlay" in sec:
            inputs += ["-loop", "1", "-t", f"{d:.3f}", "-i", str(ASSETS / sec["overlay"])]
            f.append(f"[base][{n}:v]overlay=0:0[v]")
            n += 1
        else:
            f.append("[base]null[v]")
    else:
        if sec["visual"] == "screen":
            shown = max(0.0, marks.get("start", src) - src + 0.3)
            gone = marks.get("notes_ready", src + d) - src + 0.5
            f.append(f"[0:0]setpts=PTS-STARTPTS,fps={FPS},split[a][b];[a]{SCREEN}[scr];[b]{PILL}[pill]")
            f.append(f"[scr][pill]overlay={PILL_XY}:enable='between(t,{shown:.2f},{gone:.2f})'[base]")
        else:
            inputs += ["-loop", "1", "-t", f"{d:.3f}", "-i", str(ASSETS / sec["image"])]
            f.append(f"[{n}:v]scale={W}:{H},fps={FPS},setsar=1[base]")
            n += 1
        inputs += ["-loop", "1", "-i", str(ASSETS / "circle.png")]
        f.append(f"{cam}setpts=PTS-STARTPTS,tpad=stop_mode=clone:stop_duration={hold + 1},crop='min(iw,ih)':'min(iw,ih)',scale={PIP}:{PIP},fps={FPS},format=yuva420p[c]")
        f.append(f"[{n}:v]scale={PIP}:{PIP},format=gray[m];[c][m]alphamerge[bubble]")
        f.append(f"[base][bubble]overlay=W-w-{MARGIN}:H-h-{MARGIN}:shortest=1[v]")
    if fade:
        f[-1] = f[-1].removesuffix("[v]") + f"[pre];[pre]fade=t=out:st={d - FADE:.3f}:d={FADE}[v]"
        f.append(f"[1:a]afade=t=out:st={d - FADE:.3f}:d={FADE}[a]")
        audio = "[a]"

    ffmpeg(*inputs, "-filter_complex", ";".join(f), "-map", "[v]", "-map", audio, "-t", f"{d:.3f}",
           "-c:v", "libx264", "-preset", "veryfast", "-crf", "19", "-pix_fmt", "yuv420p", "-r", str(FPS),
           "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2", str(out))
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument("take", type=Path)
    p.add_argument("--out", type=Path, default=ASSETS.parent / "babble-demo.mp4")
    p.add_argument("--cut", help="A:B, a pause to drop, in seconds after t0")
    p.add_argument("--hold", type=float, default=0.0, help="seconds to add at the end on the camera's last frame")
    args = p.parse_args()
    folder = args.take.expanduser()
    take = folder / "take.mkv"
    marks = json.loads((folder / "marks.json").read_text())
    mic = json.loads((folder / "mic.wav.json").read_text())
    timeline = json.loads((HERE / "timeline.json").read_text())
    has_cam = probe(take, ["-show_entries", "stream=codec_type"]).count("video") >= 2

    # The file's timestamps are clock times, and ffmpeg seeks relative to the first one.
    offset = marks["t0"] - float(probe(take, ["-show_entries", "format=start_time"])[0])
    print(f"t0 is {offset:.2f} s into the video and {marks['t0'] - mic['start']:.2f} s into mic.wav")
    tmp = Path(tempfile.mkdtemp(prefix="babble-merge-"))
    narration = tmp / "narration.wav"
    cut = tuple(map(float, args.cut.split(":"))) if args.cut else (timeline["length"], timeline["length"])
    sections = apply_cut(timeline["sections"], cut)
    make_narration(folder / "mic.wav", marks["t0"] - mic["start"], timeline["length"] + cut[1] - cut[0] + args.hold, timeline, narration)

    parts = [render(i, s, offset, take, has_cam, narration, marks, tmp, fade=(s is sections[-1]),
                    hold=args.hold if s is sections[-1] else 0.0)
             for i, s in enumerate(sections)]
    listing = tmp / "list.txt"
    listing.write_text("".join(f"file '{x}'\n" for x in parts))
    ffmpeg("-f", "concat", "-safe", "0", "-i", str(listing), "-c", "copy", "-movflags", "+faststart", str(args.out))
    shutil.rmtree(tmp)
    print(f"Wrote {args.out} ({float(probe(args.out, ['-show_entries', 'format=duration'])[0]):.0f} s)")


if __name__ == "__main__":
    main()
