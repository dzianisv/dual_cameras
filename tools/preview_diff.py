#!/usr/bin/env python3
"""Region-aware preview liveness check (issue #13).

Compares two emulator screencaps over the preview region only and reports
the fraction of pixels that changed. The emulator's virtual-camera test
pattern moves inside the preview; everything outside it (status-bar clock,
buttons, filter label) must not count — a whole-file `cmp` fails on a clock
tick and passes on a frozen preview whose clock still ticks.

Usage:
    python3 tools/preview_diff.py <before.png> <after.png> --min-diff <pct>

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
Later smoke runs added two more live pre-background samples: 3.87%
(run 43566987624) and 0.69% (run 43568028069). The live 3 s window
varies a lot (0.44–8.96%) — the test pattern moves in bursts — so the
threshold is the same 0.1% for every check: 4.4x below the smallest live
sample (0.44%), while a frozen preview scores exactly 0.00%. (The
pre-check was first set at 1.0% from the single 8.96% sample; run
43568028069 failed it at 0.69% live motion, proving 1.0% miscalibrated.
Unified at 0.1%.) The pre-check's job is unchanged: if it shows no
motion, the run fails loudly instead of passing on a meaningless
comparison. Caveat: a live-but-quiet 3 s window can still false-fail
below 0.1%. That fails closed and loud, never as a silent pass — acceptable
for a regression guard. This test guards "no worse", not "fixed": it
already passes on unfixed code, and Den's phone is the proof gate for
the fix.
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


def diff_fraction(a_path, b_path):
    """Fraction of preview-region pixels differing by more than the threshold."""
    a = Image.open(a_path).convert("RGB")
    b = Image.open(b_path).convert("RGB")
    if a.size != b.size:
        raise SystemExit(f"size mismatch: {a.size} vs {b.size}")
    w, h = a.size
    sx, sy = w / REFERENCE_SIZE[0], h / REFERENCE_SIZE[1]
    box = (
        int(REGION[0] * sx),
        int(REGION[1] * sy),
        int(REGION[2] * sx),
        int(REGION[3] * sy),
    )
    pa = a.crop(box).load()
    pb = b.crop(box).load()
    bw, bh = box[2] - box[0], box[3] - box[1]
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


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("before")
    parser.add_argument("after")
    parser.add_argument("--min-diff", type=float, required=True,
                        help="minimum differing-pixel %% to count as live")
    args = parser.parse_args(argv)
    pct = diff_fraction(args.before, args.after)
    print(f"preview-region diff {args.before} vs {args.after}: "
          f"{pct:.2f}% (needs >= {args.min_diff:.2f}%)")
    return 0 if pct >= args.min_diff else 1


if __name__ == "__main__":
    sys.exit(main())
