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

ISSUE #79 EXTENSION — front-vs-rear feed proof (2026-11-16): the CI
emulator now plays two DIFFERENT real videos (Big Buck Bunny trailer
as the rear feed, Sintel trailer as the front feed) via
`-camera-back/-camera-front videofile:`. Two new modes prove the feeds
are live and different at the same moment:

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


def extract_frame(mp4, out_png, t_sec):
    import imageio_ffmpeg

    import subprocess

    r = subprocess.run([
        imageio_ffmpeg.get_ffmpeg_exe(), "-y", "-ss", str(t_sec),
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
                        help="recorded-video proof: regions + motion")
    parser.add_argument("--times", default="1,5",
                        help="comma-separated frame times (s) for "
                        "--video-proof")
    args = parser.parse_args(argv)
    if args.video_proof:
        times = [int(t) for t in args.times.split(",")]
        return video_proof(args.video_proof, times, args.min_diff,
                           args.min_mean_diff)
    if args.regions:
        return 0 if regions_check(args.regions, args.min_mean_diff) else 1
    if not args.before or not args.after:
        parser.error("need <before> <after>, --regions, or --video-proof")
    pct = diff_fraction(args.before, args.after, box=args.box)
    print(f"{args.box}-region diff {args.before} vs {args.after}: "
          f"{pct:.2f}% (needs >= {args.min_diff:.2f}%)")
    return 0 if pct >= args.min_diff else 1


if __name__ == "__main__":
    sys.exit(main())
