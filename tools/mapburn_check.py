#!/usr/bin/env python3
"""Issue #49 map-burn checker (emulator smoke test leg).

Polls logcat for the [MAPBURN] DONE line after a recording with the map
on and captions off, pulls the original + burned mp4s, and verifies the
burn actually put the map in the video:

  1. capture ran: a [MAPBURN] STOP line with >= 1 snapshot captured;
  2. burn ran map-only: a [MAPBURN] DONE line with mapFrames >= 1 and
     words == 0 (captions off in the smoke run — the map-only pass);
  3. both files exist on device and are non-empty;
  4. pixel check: the top-left map rect of a frame from the burned video
     differs strongly from the same rect of the original (the map circle
     — disc + tiles — covers ~315x315 px at 1080p, padding 42 px);
  5. durations match within 0.5 s (the burn did not truncate the clip).

Frames are extracted with ffmpeg (imageio-ffmpeg's static binary) and
compared with Pillow. Writes mapburn.log + mapburn-original.png +
mapburn-burned.png in the working directory for the artifact upload.

Usage: python3 tools/mapburn_check.py [--timeout-secs 480]
Exit 0 = PASS, 1 = FAIL.
"""
import argparse
import re
import subprocess
import sys
import time

STOP_RE = re.compile(
    r"\[MAPBURN\] STOP takeId=(?P<take>\d+) durationMs=(?P<dur>\d+) "
    r"attempted=(?P<att>\d+) captured=(?P<cap>\d+) "
    r"failed=(?P<fail>\d+) bytes=(?P<bytes>\d+) capHit=(?P<cap_hit>\d+) "
    r"trackSamples=(?P<track>\d+) dir=(?P<dir>\S+)"
)
DONE_RE = re.compile(
    r"\[MAPBURN\] DONE original=(?P<orig>\S+) burned=(?P<burned>\S+) "
    r"mapFrames=(?P<frames>\d+) words=(?P<words>\d+)"
)
FAILED_RE = re.compile(r"\[MAPBURN\] FAILED (?P<rest>.*)")
DURATION_RE = re.compile(r"Duration: (\d+):(\d+):([\d.]+)")

# Map rect at 1080p (design §4: 315 px diameter, 42 px padding, top-left).
MAP_RECT = (42, 42, 357, 357)
MIN_MEAN_DIFF = 5.0  # 0-255 mean abs diff in the map rect; a 315 px disc
# vs the camera preview measures in the tens on the emulator.
MAX_DURATION_DELTA = 0.5


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def logcat():
    return run(["adb", "logcat", "-d"]).stdout


def pull(device_path, local_name):
    """adb pull, falling back to a copy via /sdcard (cache dir needs root
    on some images; the sdcard copy works without it)."""
    r = run(["adb", "pull", device_path, local_name])
    if r.returncode == 0:
        return True
    base = device_path.rsplit("/", 1)[-1]
    run(["adb", "shell", "cp", device_path, f"/sdcard/{base}"])
    r = run(["adb", "pull", f"/sdcard/{base}", local_name])
    return r.returncode == 0


def ffmpeg_exe():
    import imageio_ffmpeg

    return imageio_ffmpeg.get_ffmpeg_exe()


def duration_secs(mp4):
    r = run([ffmpeg_exe(), "-i", mp4])
    m = DURATION_RE.search(r.stderr)
    if not m:
        return None
    h, mnt, s = int(m.group(1)), int(m.group(2)), float(m.group(3))
    return h * 3600 + mnt * 60 + s


def extract_frame(mp4, out_png, t_sec=2):
    r = run([
        ffmpeg_exe(), "-y", "-ss", str(t_sec), "-i", mp4,
        "-frames:v", "1", "-f", "image2", out_png,
    ])
    if r.returncode != 0:
        print(f"ffmpeg frame extract failed for {mp4}:\n{r.stderr[-2000:]}")
        return False
    return True


def mean_abs_diff(png_a, png_b):
    from PIL import Image

    a = Image.open(png_a).convert("RGB").crop(MAP_RECT)
    b = Image.open(png_b).convert("RGB").crop(MAP_RECT)
    if a.size != b.size:
        print(f"frame size mismatch in map rect: {a.size} vs {b.size}")
        return None
    pa = list(a.getdata())
    pb = list(b.getdata())
    total = 0.0
    for (r1, g1, b1), (r2, g2, b2) in zip(pa, pb):
        total += abs(r1 - r2) + abs(g1 - g2) + abs(b1 - b2)
    return total / (len(pa) * 3)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--timeout-secs", type=int, default=480)
    args = ap.parse_args()
    log_lines = []

    def note(s):
        print(s)
        log_lines.append(s)

    run(["adb", "root"])  # best effort; the /sdcard fallback covers no-root
    deadline = time.time() + args.timeout_secs
    done = None
    stop = None
    while time.time() < deadline:
        text = logcat()
        for cand in FAILED_RE.finditer(text):
            note(f"MAPBURN FAIL: burn failed on device: {cand.group('rest')}")
            return fail(log_lines)
        for cand in STOP_RE.finditer(text):
            stop = cand  # last wins
        for cand in DONE_RE.finditer(text):
            done = cand  # last wins
        if done is not None:
            break
        time.sleep(15)
    if done is None:
        note("MAPBURN FAIL: no [MAPBURN] DONE line in logcat within "
             f"{args.timeout_secs}s (burn never finished or never ran)")
        tail = [ln for ln in logcat().splitlines() if "MAPBURN" in ln]
        note("MAPBURN lines seen:\n" + ("\n".join(tail) or "(none)"))
        return fail(log_lines)
    d = done.groupdict()
    note(f"MAPBURN DONE original={d['orig']} burned={d['burned']} "
         f"mapFrames={d['frames']} words={d['words']}")
    if stop is not None:
        s = stop.groupdict()
        note(f"MAPBURN STOP takeId={s['take']} durationMs={s['dur']} "
             f"attempted={s['att']} captured={s['cap']} failed={s['fail']} "
             f"bytes={s['bytes']} capHit={s['cap_hit']} "
             f"trackSamples={s['track']}")
        if int(s["cap"]) < 1:
            note("MAPBURN FAIL: no snapshot captured")
            return fail(log_lines)
    else:
        note("MAPBURN FAIL: no [MAPBURN] STOP line (capture never ran?)")
        return fail(log_lines)
    if int(d["frames"]) < 1:
        note("MAPBURN FAIL: DONE line carries no map frames")
        return fail(log_lines)
    if int(d["words"]) != 0:
        note(f"MAPBURN FAIL: expected a map-only pass (words == 0), "
             f"got words={d['words']}")
        return fail(log_lines)
    if not pull(d["orig"], "mapburn-original.mp4"):
        note(f"MAPBURN FAIL: could not pull original {d['orig']}")
        return fail(log_lines)
    if not pull(d["burned"], "mapburn-burned.mp4"):
        note(f"MAPBURN FAIL: could not pull burned {d['burned']}")
        return fail(log_lines)
    import os

    for name in ("mapburn-original.mp4", "mapburn-burned.mp4"):
        size = os.path.getsize(name)
        note(f"{name}: {size} bytes")
        if size == 0:
            note(f"MAPBURN FAIL: {name} is empty")
            return fail(log_lines)
    dur_o = duration_secs("mapburn-original.mp4")
    dur_b = duration_secs("mapburn-burned.mp4")
    note(f"durations: original={dur_o}s burned={dur_b}s")
    if dur_o is None or dur_b is None:
        note("MAPBURN FAIL: could not read a duration")
        return fail(log_lines)
    if abs(dur_o - dur_b) > MAX_DURATION_DELTA:
        note("MAPBURN FAIL: burned duration differs from the original by "
             f"{abs(dur_o - dur_b):.2f}s (> {MAX_DURATION_DELTA}s)")
        return fail(log_lines)
    if not extract_frame("mapburn-original.mp4", "mapburn-original.png"):
        note("MAPBURN FAIL: no frame from the original")
        return fail(log_lines)
    if not extract_frame("mapburn-burned.mp4", "mapburn-burned.png"):
        note("MAPBURN FAIL: no frame from the burned video")
        return fail(log_lines)
    diff = mean_abs_diff("mapburn-original.png", "mapburn-burned.png")
    if diff is None:
        note("MAPBURN FAIL: frame comparison failed")
        return fail(log_lines)
    note(f"map-rect mean abs diff (burned vs original): {diff:.2f} "
         f"(threshold {MIN_MEAN_DIFF})")
    if diff <= MIN_MEAN_DIFF:
        note("MAPBURN FAIL: top-left map rect of the burned video looks "
             "the same as the original — no map in the video")
        return fail(log_lines)
    note("MAPBURN PASS")
    return finish(log_lines, 0)


def fail(log_lines):
    return finish(log_lines, 1)


def finish(log_lines, code):
    with open("mapburn.log", "w") as f:
        f.write("\n".join(log_lines) + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main())
