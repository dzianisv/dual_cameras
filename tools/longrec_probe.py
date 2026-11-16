#!/usr/bin/env python3
"""Issue #81 long-recording probe (scratch, investigation only).

Reads the artifacts the long-recording workflow already collected in the
working directory and prints a compact verdict summary:

  1. every *.mp4 in the cwd: size + ffmpeg duration (the recorded take,
     pulled by tools/mapburn_check.py, or a fallback pull);
  2. [MAPBURN] STOP/DONE lines from logcat-full.txt (snapshot count,
     bytes, cap hit — the 2 fps map tick's own accounting);
  3. freeze/crash signals from logcat-full.txt: ANR / 'not responding' /
     FATAL / OutOfMemory / MediaCodec / Muxer / thermal — counts + last
     3 matching lines each;
  4. best-effort: newest dcr_*.mp4 still on the device cache (only
     useful when the stop/burn never ran, so mapburn_check.py had no
     DONE line to pull from).

Exit 0 always — this is a reporter, not a gate. The workflow decides
pass/fail from the checkpoints it printed during the take.
"""
import glob
import os
import re
import subprocess
import sys

LOG = "logcat-full.txt"

PATTERNS = [
    ("ANR", re.compile(r"ANR|not responding", re.I)),
    ("FATAL/CRASH", re.compile(r"FATAL|AndroidRuntime|crash", re.I)),
    ("OOM", re.compile(r"OutOfMemory|lowmemorykiller|onTrimMemory", re.I)),
    ("CODEC/MUXER", re.compile(r"MediaCodec|MediaMuxer|Muxer|encoder", re.I)),
    ("THERMAL", re.compile(r"thermal|throttl", re.I)),
    ("CAMERA", re.compile(r"CameraX|Camera2|ConcurrentCamera", re.I)),
]


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def ffmpeg_exe():
    import imageio_ffmpeg

    return imageio_ffmpeg.get_ffmpeg_exe()


def duration_secs(mp4):
    r = run([ffmpeg_exe(), "-i", mp4])
    m = re.search(r"Duration: (\d+):(\d+):([\d.]+)", r.stderr)
    if not m:
        return None
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))


def main():
    print("=== #81 LONGREC PROBE ===")
    mp4s = sorted(glob.glob("*.mp4"))
    if not mp4s:
        print("no mp4 files in the working directory (nothing pulled)")
    for mp4 in mp4s:
        size = os.path.getsize(mp4)
        dur = duration_secs(mp4)
        dur_s = f"{dur:.1f}s" if dur is not None else "UNKNOWN (ffprobe parse failed — file may be truncated/corrupt)"
        print(f"FILE {mp4}: {size} B, duration {dur_s}")

    logcat = ""
    if os.path.exists(LOG):
        with open(LOG, encoding="utf-8", errors="replace") as fh:
            logcat = fh.read()
    else:
        print(f"{LOG} not found — no logcat analysis possible")

    if logcat:
        lines = logcat.splitlines()
        print(f"logcat lines: {len(lines)}")
        mapburn = [ln for ln in lines if "[MAPBURN]" in ln]
        print(f"[MAPBURN] lines: {len(mapburn)}")
        for ln in mapburn:
            print(f"  MAPBURN: {ln.strip()[-300:]}")
        for name, rx in PATTERNS:
            hits = [ln for ln in lines if rx.search(ln)]
            print(f"{name}: {len(hits)} hits")
            for ln in hits[-3:]:
                print(f"  {name}: {ln.strip()[-300:]}")
        # Last storycam/flutter lines before end of log — the freeze tail.
        tail = [ln for ln in lines if re.search(r"storycam|flutter", ln, re.I)][-10:]
        print("last 10 storycam/flutter log lines:")
        for ln in tail:
            print(f"  TAIL: {ln.strip()[-300:]}")

    # Best-effort device fallback: newest dcr file still in the app cache.
    r = run(["adb", "shell", "ls -t /data/data/app.storycam/cache/dcr_*.mp4"])
    newest = (r.stdout or "").strip().splitlines()
    newest = [x.strip() for x in newest if x.strip().endswith(".mp4")]
    if newest:
        print(f"device cache newest dcr file: {newest[0]}")
        base = newest[0].rsplit("/", 1)[-1]
        r2 = run(["adb", "pull", newest[0], f"device-{base}"])
        if r2.returncode == 0:
            size = os.path.getsize(f"device-{base}")
            dur = duration_secs(f"device-{base}")
            print(f"pulled device file: device-{base}: {size} B, duration "
                  f"{dur:.1f}s" if dur is not None else f"device-{base}: {size} B, duration UNKNOWN")
        else:
            print("device pull failed (cache not readable from adb on this image)")
    else:
        print("no dcr_*.mp4 found in the device app cache (or cache not listable)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
