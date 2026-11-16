#!/usr/bin/env python3
"""Long-recording gate (issues #81 + #87) — permanent emulator leg.

Runs after a recording in the smoke test and FAILS the run unless the
take actually produced a saved, playable video. This is the check that
did not exist when 0.5.15 shipped recording no files at all (#87): the
old legs proved only the 'Video saved to gallery' status text.

Checks, in order (exit 1 on the first failure, exit 0 = PASS):

  1. [MAPBURN] STOP line (last one in logcat): the take ran at least
     --min-duration-secs and captured at least --min-captured map
     snapshots (map on). Also reports failed snapshots, snapMaxMs and
     snapOverruns from the #81 _mapTick instrumentation when present.
  2. MediaStore: the newest video row (content://media/external/video/
     media, by date_added) exists, is recent (<= 900 s old), has size > 0
     and duration >= --min-duration-secs (2 s tolerance). This is the
     gallery listing itself — NOT the status text, NOT a screenshot,
     NOT the pulled file alone.
  3. No ANR / FATAL / 'not responding' line in logcat mentions
     app.storycam (the #81 lock shape).
  4. With --pull: the newest dcr_*.mp4 is pulled from the device cache
     and ffprobe-verified (duration >= --min-duration-secs, size > 0) —
     the file is listed AND playable.

Usage:
  python3 tools/longrec_check.py --min-duration-secs 30 --min-captured 60 \\
      --label long --pull        # 40 s take: all gates
  python3 tools/longrec_check.py --min-duration-secs 5 --min-captured 5 \\
      --label 6s                 # 6 s take: MediaStore gate, no pull

Writes longrec-check-<label>.log in the working directory.
Exit 0 = PASS, 1 = FAIL.
"""
import argparse
import os
import re
import subprocess
import sys
import time

STOP_RE = re.compile(
    r"\[MAPBURN\] STOP takeId=(?P<take>\d+) "
    r"durationMs=(?P<dur>\d+) attempted=(?P<att>\d+) "
    r"captured=(?P<cap>\d+) failed=(?P<fail>\d+) "
    r"bytes=(?P<bytes>\d+) capHit=(?P<cap_hit>\d+)"
)
SNAP_MAX_RE = re.compile(r"snapMaxMs=(\d+)")
OVERRUNS_RE = re.compile(r"snapOverruns=(\d+)")
DURATION_RE = re.compile(r"Duration: (\d+):(\d+):([\d.]+)")

# MediaStore recency: the saved file must be from this run, not a stale
# row from an earlier take. 900 s covers stop + mapburn settle + checks.
MAX_ROW_AGE_SECS = 900
# MediaStore/ffprobe duration tolerance: the recorded length vs the
# gate threshold, in seconds (tap latency makes takes run long, never
# short by more than a tap).
DURATION_TOL_SECS = 2


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def ffmpeg_exe():
    import imageio_ffmpeg

    return imageio_ffmpeg.get_ffmpeg_exe()


def duration_secs(mp4):
    r = run([ffmpeg_exe(), "-i", mp4])
    m = DURATION_RE.search(r.stderr)
    if not m:
        return None
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))


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


def mediastore_newest():
    """Newest video row in MediaStore, or None. Returns a dict with
    display_name, duration_ms, size, date_added (epoch secs)."""
    # No --sort: adb shell re-splits args on the device, so a
    # "date_added DESC" value arrives as two words and the content
    # command rejects the stray DESC ("[ERROR] Unsupported argument:
    # DESC", run 43818765878). Rows are sorted in Python below.
    r = run([
        "adb", "shell", "content", "query",
        "--uri", "content://media/external/video/media",
        "--projection", "_display_name:duration:size:date_added",
    ])
    out = (r.stdout or "") + (r.stderr or "")
    rows = []
    for line in out.splitlines():
        line = line.strip()
        if not line.startswith("Row:"):
            continue
        dur = re.search(r"duration=(\d+)", line)
        size = re.search(r"size=(\d+)", line)
        added = re.search(r"date_added=(\d+)", line)
        name = re.search(r"_display_name=(.*?),", line)
        if dur is None or size is None or added is None:
            continue
        rows.append({
            "display_name": name.group(1).strip() if name else "(unknown)",
            "duration_ms": int(dur.group(1)),
            "size": int(size.group(1)),
            "date_added": int(added.group(1)),
        })
    if not rows:
        return None, out
    rows.sort(key=lambda row: row["date_added"], reverse=True)
    return rows[0], out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--min-duration-secs", type=int, default=30)
    ap.add_argument("--min-captured", type=int, default=60)
    ap.add_argument("--label", default="long")
    ap.add_argument("--pull", action="store_true",
                    help="also pull the newest dcr_*.mp4 and ffprobe it")
    args = ap.parse_args()
    log_lines = []

    def note(s):
        print(s)
        log_lines.append(s)

    def fail(msg):
        note(f"LONGREC CHECK {args.label}: FAIL — {msg}")
        return finish(log_lines, args.label, 1)

    run(["adb", "root"])  # best effort; the /sdcard fallback covers no-root
    note(f"=== LONGREC CHECK {args.label} "
         f"(min-duration {args.min_duration_secs}s, "
         f"min-captured {args.min_captured}, pull={args.pull}) ===")

    # 1. [MAPBURN] STOP line: the take ran long enough, map tick ran.
    text = run(["adb", "logcat", "-d"]).stdout
    stops = list(STOP_RE.finditer(text))
    if not stops:
        return fail("no [MAPBURN] STOP line in logcat (capture never ran?)")
    stop = stops[-1].groupdict()
    stop_line = stops[-1].group(0)
    snap_max = SNAP_MAX_RE.search(text[stops[-1].start():stops[-1].end() + 200])
    overruns = OVERRUNS_RE.search(text[stops[-1].start():stops[-1].end() + 200])
    note(f"MAPBURN STOP takeId={stop['take']} "
         f"durationMs={stop['dur']} attempted={stop['att']} "
         f"captured={stop['cap']} failed={stop['fail']} "
         f"bytes={stop['bytes']} capHit={stop['cap_hit']}"
         + (f" snapMaxMs={snap_max.group(1)}" if snap_max else "")
         + (f" snapOverruns={overruns.group(1)}" if overruns else ""))
    if int(stop["dur"]) < args.min_duration_secs * 1000:
        return fail(f"take lasted {stop['dur']} ms "
                    f"(< {args.min_duration_secs * 1000} ms — stopped early?)")
    if int(stop["cap"]) < args.min_captured:
        return fail(f"only {stop['cap']} snapshots captured "
                    f"(< {args.min_captured} — map tick stalled?)")
    note(f"STOP gate: take {int(stop['dur']) / 1000:.1f}s, "
         f"{stop['cap']} snapshots captured")

    # 2. MediaStore: the video file EXISTS in the gallery with duration.
    row, raw = mediastore_newest()
    if row is None:
        note("MediaStore query returned no video rows. Raw output:\n"
             + (raw.strip()[-2000:] or "(empty)"))
        return fail("no video in MediaStore — the take was not saved "
                    "(issue #87: status text is not proof)")
    now = int(time.time())
    age = now - row["date_added"]
    note(f"MediaStore newest: {row['display_name']} "
         f"duration={row['duration_ms'] / 1000:.1f}s size={row['size']} B "
         f"date_added={row['date_added']} (age {age}s)")
    if age > MAX_ROW_AGE_SECS or age < -60:
        return fail(f"newest MediaStore video is {age}s old "
                    f"(not this take — expected <= {MAX_ROW_AGE_SECS}s)")
    if row["size"] == 0:
        return fail("newest MediaStore video has size 0")
    if row["duration_ms"] < (args.min_duration_secs - DURATION_TOL_SECS) * 1000:
        return fail(f"MediaStore duration "
                    f"{row['duration_ms'] / 1000:.1f}s "
                    f"(< {args.min_duration_secs - DURATION_TOL_SECS}s)")
    note(f"MediaStore gate: file listed, "
         f"{row['duration_ms'] / 1000:.1f}s, {row['size']} B")

    # 3. No ANR / crash signal mentioning the app (the #81 lock shape).
    bad = [ln for ln in text.splitlines()
           if re.search(r"ANR|not responding|FATAL|AndroidRuntime", ln, re.I)
           and "storycam" in ln.lower()]
    if bad:
        note(f"ANR/FATAL lines mentioning app.storycam: {len(bad)}")
        for ln in bad[:10]:
            note(f"  ANR: {ln.strip()[-300:]}")
        return fail("ANR/crash signal in logcat (app locked?)")
    note("logcat gate: no ANR/FATAL line mentions app.storycam")

    # 4. With --pull: the file is playable (ffprobe duration + size).
    if args.pull:
        local_name = f"longrec-take-{args.label}.mp4"
        r = run(["adb", "shell",
                 "ls -t /data/data/app.storycam/cache/dcr_*.mp4"])
        newest = [x.strip() for x in (r.stdout or "").splitlines()
                  if x.strip().endswith(".mp4")]
        if not newest:
            return fail("no dcr_*.mp4 in the device app cache to pull")
        note(f"device cache newest: {newest[0]}")
        if not pull(newest[0], local_name):
            return fail(f"could not pull {newest[0]}")
        size = os.path.getsize(local_name)
        dur = duration_secs(local_name)
        if dur is not None:
            note(f"pulled {local_name}: {size} B, duration {dur:.1f}s")
        else:
            note(f"pulled {local_name}: {size} B, duration UNKNOWN")
        if size == 0:
            return fail(f"pulled file {local_name} is empty")
        if dur is None:
            return fail(f"could not read a duration from {local_name} "
                        f"(truncated/corrupt?)")
        if dur < args.min_duration_secs - DURATION_TOL_SECS:
            return fail(f"pulled video is {dur:.1f}s "
                        f"(< {args.min_duration_secs - DURATION_TOL_SECS}s)")
        note(f"pull gate: {local_name} {size} B, {dur:.1f}s, playable")

    note(f"LONGREC CHECK {args.label}: PASS")
    return finish(log_lines, args.label, 0)


def finish(log_lines, label, code):
    with open(f"longrec-check-{label}.log", "w") as f:
        f.write("\n".join(log_lines) + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main())
