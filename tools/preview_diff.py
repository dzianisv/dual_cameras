#!/usr/bin/env python3
"""Region-aware preview liveness check (issue #13).

Compares two emulator screencaps over the preview region only and reports
the fraction of pixels that changed. The emulator's virtual-camera test
pattern moves inside the preview; everything outside it (status-bar clock,
buttons, filter label) must not count — a whole-file `cmp` fails on a clock
tick and passes on a frozen preview whose clock still ticks.

Usage:
    python3 tools/preview_diff.py <before.png> <after.png> --min-diff <pct>
    python3 tools/preview_diff.py <before.png> <after.png> --min-diff <pct> --box front|rear
    python3 tools/preview_diff.py --regions <shot.png> --min-mean-diff <diff>
    python3 tools/preview_diff.py --video-proof <recording.mp4> --times 1,5 --min-diff 0.1 --min-mean-diff 5.0
    python3 tools/preview_diff.py --not-black <shot.png>
    python3 tools/preview_diff.py --live <a.png> <b.png> <c.png> --min-diff <pct>
    python3 tools/preview_diff.py --file-proof <recording.mp4> --min-duration <secs>
    python3 tools/preview_diff.py --gallery-proof <content-query.txt> [--expect-name <file>] [--rec-start <epoch-file>]
    python3 tools/preview_diff.py --gallery-path <content-query.txt> [--rec-start <epoch-file>]

Exits 0 when the differing-pixel fraction is at or above --min-diff
(motion seen: the preview is live), 1 otherwise (frozen or blind), and
prints the measured fraction for the log.

Calibration (repro run 43565398115 artifact, 7 shots, unfixed code —
PIL, per-channel diff threshold 8/255, region x40-280/y120-420 in
320x640 screencap coordinates):
    pre-background pair, 3 s apart:              8.96%
    post-resume idle pair, 3 s apart:             0.44%
    post-resume after-recording pair, 3 s apart:  2.19%
    cross-leg idle vs after-recording (~35-40 s): 10.65% / 12.40%
    identical file vs itself (frozen simulation):  0.00%
Later smoke runs added more live samples: pre-background 3.87%
(run 43566987624), 0.69% (run 43568028069) and 0.17%
(run 43568805799); post-resume idle 0.63% and after-recording 10.76%
(run 43568805799). The live 3 s window varies a lot (0.17–8.96%) —
the test pattern moves in bursts — so the threshold is the same 0.1%
for every check: 1.7x below the smallest live sample (0.17%), while a
frozen preview scores exactly 0.00% (a static texture + lossless PNG
has no noise). (The pre-check was first set at 1.0% from the single
8.96% sample; run 43568028069 failed it at 0.69% live motion, proving
1.0% miscalibrated. Unified at 0.1%.) The pre-check's job is unchanged:
if it shows no motion, the run fails loudly instead of passing on a
meaningless comparison. Caveat: a live-but-quiet 3 s window can still
false-fail below 0.1%. That fails closed and loud, never as a silent
pass — acceptable for a regression guard. This test guards "no worse",
not "fixed": it already passes on unfixed code, and Den's phone is the
proof gate for the fix.

UPDATE 2026-11-16 (head 65fe70f, runs 43819821940 + 43819834598): the
3 s single-pair check false-failed TWICE in one round — screenshots
launch pair 0.00%, smoke post-recording resume pair 0.00% — on live
previews. Cross-pair evidence proves still gaps, not a freeze: the
smoke resume-after-rec-1.png frame differs 13.71% from the
resume-after-1.png frame ~85 s earlier (and 14.55% from
resume-pre-1.png), while the 3 s pair inside the post-recording
window was 0.00%. The emulated test pattern moves in bursts with
still gaps >= 3 s, so a single 3 s pair is miscalibrated for this
feed. The --live mode below takes THREE shots ~4 s apart (8 s
window) and passes when EITHER consecutive interval shows motion:
a genuinely frozen preview scores 0.00% in BOTH intervals and still
fails, while a still gap only fails the run if it covers the whole
8 s window. Same 0.1% threshold per interval — this is a longer
window, not a lower bar. `--live` originated on the #79 Track A branch
(PR #80, commit 7c45317); runs 43819821940 / 43819834598 false-failed
the old single-pair check at 0.00% on live previews, and `--live` was
proved on run 43846071240 (idle triple 13.71% / 0.00% → LIVE PASS);
it reached main via the #80 merge.
Residual risk (issue #13 Stage 2): still phases reach ~38 s on
provably live previews, longer than the 8 s window — if --live still
false-fails, the next step is a cross-pair fallback (live cross-pairs
score 4.70-38.49%), not a lower threshold.

ISSUE #79 EXTENSION — front-vs-rear feed proof (2026-11-16): the
videofile attempt wired two DIFFERENT real videos (Big Buck Bunny
trailer as the rear feed, Sintel trailer as the front feed) via
`-camera-back/-camera-front videofile:`, but Stage 4 FAILED it — the
CI emulator's camera HAL reports no front+back concurrent combo for
any non-emulated feed, so the camera never opened. The Track A
rework (2026-11-16) runs the emulator on its emulated test-pattern
feed instead: screenshots show the test pattern, honestly stated,
and the real-feeds proof moves to a real device (Track B). The
--regions / --video-proof modes below are KEPT, uninvoked on this
route, for that Track B real-device proof — do not invoke a
distinctness check on the emulated feed (front and rear show the
SAME test pattern, so it cannot pass). What the emulated route
asserts instead:

* --not-black <shot.png>: the black-guard as a standalone sanity
  check — each feed region's mean brightness must be >= 8.0, i.e.
  a video feed is actually on screen (run 43806479078: a black
  preview still scored a 7.97 mean diff and would have PASSED
  --regions).
* --file-proof <recording.mp4> --min-duration <s>: the core-loop
  proof (issues #79 + #87) — the pulled recording exists, is
  non-empty, has ffprobe/ffmpeg duration >= the floor, and a frame
  extracts at t=1s (playable). Never trust the "Video saved to
  gallery" status text.
* --gallery-proof <content-query.txt> [--expect-name <base>]
  [--rec-start <epoch-file>]: the MediaStore side of the same
  proof — the gallery row for the recording exists with
  duration > 0 (optionally tied to this recording by file name
  and/or by date_added recency).
* --gallery-path <content-query.txt> [--rec-start <epoch-file>]:
  prints the _data path of that same newest matching row, so the
  workflow can pull the GALLERY copy and --file-proof it. The path
  comes from MediaStore on purpose: run 43823525690 proved the
  Session-details tile's 'Original:' row is in-memory only
  (_lastFile, main.dart:258 — "gone on app restart"): the app
  re-initialized after the share sheet (status back to 'Ready to
  tell your story', no Original row) while the gallery row
  survived. Never read a recording path from the app's memory.

Two new modes prove the feeds are live and different at the same
moment (TRACK B ONLY — see above):

* --regions <shot.png>: compares the front (selfie) circle region
  against a rear full-frame region WITHIN one screenshot, as the mean
  absolute per-channel difference of both regions downscaled to 32x32
  (same 0–255 scale and 5.0 floor as tools/mapburn_check.py). The
  boxes are fractions of the frame, so the same check works on a
  320x640 screencap and on a 1080p recorded-video frame. Geometry
  measured on the 320x640 CI screenshots (run 43744622215): front
  circle centre ~(205,465) r~55 — FRONT_BOX is inscribed in the
  circle, so it holds pure front-feed content; REAR_BOX is top-right,
  clear of the map circle (top-left) and the status bar.
* --box front|rear on the classic two-shot mode: the motion check
  restricted to one feed's region, so the run proves EACH feed moves,
  not just the preview as a whole.
* --video-proof <recording.mp4>: extracts frames at --times from the
  pulled recording (imageio-ffmpeg, same binary as mapburn_check.py),
  runs --regions on each frame, and runs the motion check on each
  feed's region across the two times. Writes video-proof-t<N>.png
  frames for the artifact upload. Exit 0 only if every check passes.

SCOPE NOTE (read before over-claiming): regions-differ + both-move
is necessary, not sufficient, proof that the two feeds are different
videos — two crops of the SAME video would also differ and move. The
sufficient proof is visual: the dual-preview screenshot visibly shows
Sintel in the front circle and Big Buck Bunny full-frame, two
unmistakable contents, and a human reads the artifact. This script
guards against the failure modes automation can see (frozen feed,
black feed, one feed missing); the lead's visual readback closes the
distinctness claim.
"""

import argparse
import sys

from PIL import Image

# Preview region in 320x640 screencap coordinates (lead's calibration).
# Contains the dual preview + selfie circle only: the status-bar clock is
# above it, the shutter/buttons/filter label below it.
REGION = (40, 120, 280, 420)
REFERENCE_SIZE = (320, 640)
DIFF_THRESHOLD = 8  # per channel, out of 255

# Issue #79: front/rear feed regions as fractions of the frame (see the
# module docstring for the geometry provenance). Fractional so one check
# serves 320x640 screencaps and 1080p recorded-video frames alike.
FRONT_BOX_FRAC = (0.52, 0.67, 0.76, 0.79)  # inscribed in the selfie circle
REAR_BOX_FRAC = (0.55, 0.28, 0.95, 0.45)  # rear full-frame area, top-right
REGION_BOXES = {"preview": None, "front": FRONT_BOX_FRAC, "rear": REAR_BOX_FRAC}
MIN_MEAN_DIFF = 5.0  # 0-255 mean abs diff; same floor as mapburn_check.py
MIN_MEAN_BRIGHTNESS = 8.0  # 0-255 mean brightness floor per region (issue
# #79, run 43806479078): on a black preview (camera failed to open) two
# near-black regions still score a small mean diff (7.97, from a UI edge
# inside one box) and would PASS --regions. A region darker than this
# is not a video feed at all — fail it loudly instead.


def frac_box(size, frac):
    w, h = size
    return (
        int(frac[0] * w),
        int(frac[1] * h),
        int(frac[2] * w),
        int(frac[3] * h),
    )


def box_pixels(img, frac):
    """Crop of img at the fractional box, or the legacy preview REGION."""
    if frac is None:
        w, h = img.size
        sx, sy = w / REFERENCE_SIZE[0], h / REFERENCE_SIZE[1]
        box = (
            int(REGION[0] * sx),
            int(REGION[1] * sy),
            int(REGION[2] * sx),
            int(REGION[3] * sy),
        )
        return img.crop(box).convert("RGB")
    return img.crop(frac_box(img.size, frac)).convert("RGB")


def diff_fraction(a_path, b_path, box="preview"):
    """Fraction of region pixels differing by more than the threshold."""
    a = Image.open(a_path).convert("RGB")
    b = Image.open(b_path).convert("RGB")
    if a.size != b.size:
        raise SystemExit(f"size mismatch: {a.size} vs {b.size}")
    pa = box_pixels(a, REGION_BOXES[box]).load()
    pb = box_pixels(b, REGION_BOXES[box]).load()
    bw, bh = box_pixels(a, REGION_BOXES[box]).size
    diff = 0
    for y in range(bh):
        for x in range(bw):
            r1, g1, b1 = pa[x, y]
            r2, g2, b2 = pb[x, y]
            if (
                abs(r1 - r2) > DIFF_THRESHOLD
                or abs(g1 - g2) > DIFF_THRESHOLD
                or abs(b1 - b2) > DIFF_THRESHOLD
            ):
                diff += 1
    return 100.0 * diff / (bw * bh)


def mean_brightness(img, frac):
    crop = box_pixels(img, frac)
    px = list(crop.getdata())
    return sum(r + g + b for r, g, b in px) / (len(px) * 3)


def regions_mean_diff(img_path):
    """Mean abs per-channel diff between the front-circle and rear-area
    regions of ONE image (both downscaled to 32x32 first). Two different
    real videos score in the tens; the same feed twice scores ~0."""
    img = Image.open(img_path).convert("RGB")
    for name, frac in (("front", FRONT_BOX_FRAC), ("rear", REAR_BOX_FRAC)):
        bright = mean_brightness(img, frac)
        if bright < MIN_MEAN_BRIGHTNESS:
            print(f"regions {name} box looks black (mean brightness "
                  f"{bright:.2f} < {MIN_MEAN_BRIGHTNESS}) — no video "
                  f"feed in {img_path}")
            return None
    a = box_pixels(img, FRONT_BOX_FRAC).resize((32, 32))
    b = box_pixels(img, REAR_BOX_FRAC).resize((32, 32))
    pa = list(a.getdata())
    pb = list(b.getdata())
    total = 0.0
    for (r1, g1, b1), (r2, g2, b2) in zip(pa, pb):
        total += abs(r1 - r2) + abs(g1 - g2) + abs(b1 - b2)
    return total / (len(pa) * 3)


def regions_check(img_path, min_mean_diff):
    diff = regions_mean_diff(img_path)
    if diff is None:
        return False
    print(f"front-vs-rear regions {img_path}: mean abs diff {diff:.2f} "
          f"(needs >= {min_mean_diff:.2f})")
    return diff >= min_mean_diff


def live_check(a_path, b_path, c_path, min_diff, box="preview"):
    """Liveness over THREE shots (see module docstring, 2026-11-16
    update): the emulated test pattern moves in bursts with still gaps
    >= 3 s, so a single 3 s pair false-fails on live previews. Passes
    when EITHER consecutive interval shows >= min_diff motion; a
    genuinely frozen preview scores 0.00% in both intervals and fails."""
    ab = diff_fraction(a_path, b_path, box=box)
    bc = diff_fraction(b_path, c_path, box=box)
    print(f"{box}-region diff {a_path} vs {b_path}: "
          f"{ab:.2f}% (needs >= {min_diff:.2f}%)")
    print(f"{box}-region diff {b_path} vs {c_path}: "
          f"{bc:.2f}% (needs >= {min_diff:.2f}%)")
    if ab >= min_diff or bc >= min_diff:
        print(f"LIVE PASS: motion seen in at least one interval "
              f"({max(ab, bc):.2f}%)")
        return 0
    print(f"LIVE FAIL: no motion in either interval over the "
          f"three-shot window ({a_path} -> {b_path} -> {c_path}) — "
          f"preview frozen")
    return 1


def not_black_check(img_path):
    """Black-guard as a standalone sanity check (Track A): each feed
    region's mean brightness must clear MIN_MEAN_BRIGHTNESS. Proves a
    video feed is on screen; says nothing about distinctness."""
    img = Image.open(img_path).convert("RGB")
    ok = True
    for name, frac in (("front", FRONT_BOX_FRAC), ("rear", REAR_BOX_FRAC)):
        bright = mean_brightness(img, frac)
        print(f"black-guard {img_path} {name} box: mean brightness "
              f"{bright:.2f} (needs >= {MIN_MEAN_BRIGHTNESS})")
        if bright < MIN_MEAN_BRIGHTNESS:
            print(f"BLACK GUARD FAIL: {name} box looks black in "
                  f"{img_path} — no video feed")
            ok = False
    return ok


def file_proof(mp4, min_duration):
    """Core-loop proof (issues #79 + #87): the recording exists, is
    non-empty, lasts >= min_duration seconds, and a frame extracts
    (playable). The status text is never consulted."""
    import os
    import re
    import subprocess

    if not os.path.exists(mp4):
        print(f"FILE PROOF FAIL: {mp4} does not exist")
        return 1
    size = os.path.getsize(mp4)
    if size == 0:
        print(f"FILE PROOF FAIL: {mp4} is empty (0 bytes)")
        return 1
    r = subprocess.run([ffmpeg_exe(), "-i", mp4],
                       capture_output=True, text=True)
    m = re.search(r"Duration: (\d+):(\d+):([\d.]+)", r.stderr)
    if not m:
        print(f"FILE PROOF FAIL: no duration in ffmpeg output for "
              f"{mp4}:\n{r.stderr[-1000:]}")
        return 1
    dur = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))
    print(f"FILE PROOF: {mp4} exists, {size} B, duration {dur:.2f}s "
          f"(needs >= {min_duration:.1f}s)")
    if dur < min_duration:
        print(f"FILE PROOF FAIL: duration {dur:.2f}s < {min_duration:.1f}s")
        return 1
    out = "file-proof-frame.png"
    if not extract_frame(mp4, out, 1):
        print(f"FILE PROOF FAIL: no frame extracts at t=1s — not playable")
        return 1
    print(f"FILE PROOF PASS: {mp4} exists, duration {dur:.2f}s, frame "
          f"extracts ({out})")
    return 0


def select_gallery_row(text, expect_name, rec_start):
    """Newest MediaStore video row with duration > 0, optionally tied
    to this recording by file name and/or by date_added recency
    (row must postdate rec_start - 10 s). Returns the row string,
    or None. The query itself is unsorted (`adb shell content query
    --sort "date_added DESC"` fails on the emulator — the device-side
    parser splits the value and rejects the bare DESC token — so
    ordering happens here)."""
    import re

    rows = re.findall(r"Row: \d+ (.*)", text)
    # Newest first by date_added.
    def added_of(row):
        m = re.search(r"date_added=(\d+)", row)
        return int(m.group(1)) if m else -1
    rows = sorted(rows, key=added_of, reverse=True)
    for row in rows:
        data = re.search(r"_data=([^,]+)", row)
        dur = re.search(r"duration=(\d+)", row)
        added = re.search(r"date_added=(\d+)", row)
        if not dur or int(dur.group(1)) <= 0:
            continue
        if expect_name and not (data and data.group(1).endswith(expect_name)):
            continue
        if rec_start is not None:
            if not added or int(added.group(1)) < rec_start - 10:
                continue
        return row
    return None


def gallery_proof(query_file, expect_name, rec_start_file):
    """MediaStore side of the core-loop proof: parse an
    `adb shell content query` dump of the video table and require a
    row with duration > 0. --expect-name ties the row to this
    recording (the _data path ends with the recorded file's name);
    --rec-start requires date_added within 10 s before the
    recording's start (device clock == host clock on the emulator)."""
    import os
    import re

    if not os.path.exists(query_file):
        print(f"GALLERY PROOF FAIL: {query_file} does not exist")
        return 1
    text = open(query_file).read()
    print(f"gallery query output:\n{text.strip()}")
    if not re.findall(r"Row: \d+ ", text):
        print("GALLERY PROOF FAIL: no rows in the MediaStore video table")
        return 1
    start = None
    if rec_start_file:
        start = int(open(rec_start_file).read().strip())
    row = select_gallery_row(text, expect_name, start)
    if row is None:
        print("GALLERY PROOF FAIL: no gallery row with duration > 0"
              + (f" for {expect_name}" if expect_name else "")
              + (f" since {start}" if start is not None else ""))
        return 1
    print(f"GALLERY PROOF PASS: {row.strip()}")
    return 0


def gallery_path(query_file, expect_name, rec_start_file):
    """Print the _data path of the newest matching gallery row (same
    selection as gallery_proof) and nothing else, so the workflow can
    capture it with $(...) and pull the gallery copy for
    --file-proof. Exit 1 when no row matches."""
    import os
    import re

    if not os.path.exists(query_file):
        print(f"GALLERY PATH FAIL: {query_file} does not exist")
        return 1
    text = open(query_file).read()
    start = None
    if rec_start_file:
        start = int(open(rec_start_file).read().strip())
    row = select_gallery_row(text, expect_name, start)
    if row is None:
        print("GALLERY PATH FAIL: no gallery row with duration > 0"
              + (f" for {expect_name}" if expect_name else "")
              + (f" since {start}" if start is not None else ""))
        return 1
    data = re.search(r"_data=([^,]+)", row)
    if not data:
        print(f"GALLERY PATH FAIL: no _data in row: {row.strip()}")
        return 1
    print(data.group(1))
    return 0
    return 1


def ffmpeg_exe():
    """Static ffmpeg from imageio-ffmpeg (installed on the runner);
    falls back to a system ffmpeg when the package is absent, so the
    helper also runs on a plain checkout."""
    try:
        import imageio_ffmpeg

        return imageio_ffmpeg.get_ffmpeg_exe()
    except ImportError:
        return "ffmpeg"


def extract_frame(mp4, out_png, t_sec):
    import subprocess

    r = subprocess.run([
        ffmpeg_exe(), "-y", "-ss", str(t_sec),
        "-i", mp4, "-frames:v", "1", "-f", "image2", out_png,
    ], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"ffmpeg frame extract failed for {mp4} at t={t_sec}:\n"
              f"{r.stderr[-2000:]}")
        return False
    return True


def video_proof(mp4, times, min_diff, min_mean_diff):
    """Frames at --times from the recording: each frame's regions must
    differ (two feeds at once) and each feed's region must move across
    the times (no frozen feed). Writes video-proof-t<N>.png frames."""
    frames = []
    for t in times:
        out = f"video-proof-t{t}.png"
        if not extract_frame(mp4, out, t):
            return 1
        frames.append(out)
        print(f"extracted frame t={t}s -> {out}")
    ok = True
    for f in frames:
        if not regions_check(f, min_mean_diff):
            print(f"VIDEO PROOF FAIL: front/rear regions look the same "
                  f"in {f}")
            ok = False
    if len(frames) == 2:
        for box in ("front", "rear"):
            pct = diff_fraction(frames[0], frames[1], box=box)
            print(f"{box}-region motion {frames[0]} vs {frames[1]}: "
                  f"{pct:.2f}% (needs >= {min_diff:.2f}%)")
            if pct < min_diff:
                print(f"VIDEO PROOF FAIL: no motion in the {box} region "
                      f"between t={times[0]}s and t={times[1]}s")
                ok = False
    return 0 if ok else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("before", nargs="?")
    parser.add_argument("after", nargs="?")
    parser.add_argument("--min-diff", type=float, default=0.1,
                        help="minimum differing-pixel %% to count as live")
    parser.add_argument("--box", choices=["preview", "front", "rear"],
                        default="preview",
                        help="which region the two-shot motion check uses")
    parser.add_argument("--regions", metavar="PNG",
                        help="one-shot front-vs-rear region check")
    parser.add_argument("--min-mean-diff", type=float, default=MIN_MEAN_DIFF,
                        help="minimum mean abs diff for --regions")
    parser.add_argument("--video-proof", metavar="MP4",
                        help="recorded-video proof: regions + motion "
                        "(Track B only — not invoked on the emulated feed)")
    parser.add_argument("--times", default="1,5",
                        help="comma-separated frame times (s) for "
                        "--video-proof")
    parser.add_argument("--live", nargs=3, metavar=("A", "B", "C"),
                        help="three-shot liveness check: passes when "
                        "either consecutive interval shows >= --min-diff "
                        "motion (bursty test pattern; see docstring)")
    parser.add_argument("--not-black", metavar="PNG",
                        help="black-guard sanity check: both feed regions "
                        "must clear the brightness floor")
    parser.add_argument("--file-proof", metavar="MP4",
                        help="core-loop proof: file exists, duration >= "
                        "--min-duration, frame extracts")
    parser.add_argument("--min-duration", type=float, default=0.0,
                        help="minimum duration (s) for --file-proof")
    parser.add_argument("--gallery-proof", metavar="TXT",
                        help="MediaStore proof: content-query dump must "
                        "hold a row with duration > 0")
    parser.add_argument("--gallery-path", metavar="TXT",
                        help="print the _data path of the newest matching "
                        "gallery row (same selection as --gallery-proof), "
                        "so the workflow can pull the gallery copy")
    parser.add_argument("--expect-name", metavar="FILE",
                        help="gallery row _data must end with this name")
    parser.add_argument("--rec-start", metavar="FILE",
                        help="file holding the recording start epoch (s); "
                        "gallery row date_added must be >= start - 10")
    args = parser.parse_args(argv)
    if args.live:
        return live_check(args.live[0], args.live[1], args.live[2],
                          args.min_diff, box=args.box)
    if args.not_black:
        return 0 if not_black_check(args.not_black) else 1
    if args.file_proof:
        return file_proof(args.file_proof, args.min_duration)
    if args.gallery_proof:
        return gallery_proof(args.gallery_proof, args.expect_name,
                             args.rec_start)
    if args.gallery_path:
        return gallery_path(args.gallery_path, args.expect_name,
                            args.rec_start)
    if args.video_proof:
        times = [int(t) for t in args.times.split(",")]
        return video_proof(args.video_proof, times, args.min_diff,
                           args.min_mean_diff)
    if args.regions:
        return 0 if regions_check(args.regions, args.min_mean_diff) else 1
    if not args.before or not args.after:
        parser.error("need <before> <after>, --live, --regions, "
                     "--video-proof, --not-black, --file-proof, "
                     "--gallery-proof, or --gallery-path")
    pct = diff_fraction(args.before, args.after, box=args.box)
    print(f"{args.box}-region diff {args.before} vs {args.after}: "
          f"{pct:.2f}% (needs >= {args.min_diff:.2f}%)")
    return 0 if pct >= args.min_diff else 1


if __name__ == "__main__":
    sys.exit(main())
