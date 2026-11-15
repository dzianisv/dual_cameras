#!/usr/bin/env python3
"""Issue #49 spike checker (spike/map-capture-49 only, never merge).

Reads [MAPSPIKE] lines from a logcat dump and judges them against the
design §1 pass bar for a 60 s recording at 1080p:
  1. snapshot capture rate >= 95% of expected snapshots;
  2. recorded frames: encoderFrames >= 95% of duration x 30 fps,
     OR droppedFrames == 0 (the design's objective check);
  3. storage within budget: avg <= 100 KB/frame and total <= ~12 MB/min.
Usage: python3 tools/mapspike_check.py mapspike.log
Exit 0 = PASS, 1 = FAIL (or no SUMMARY found).
"""
import re
import sys

SUMMARY_RE = re.compile(
    r"\[MAPSPIKE\] SUMMARY takeId=(?P<take>\d+) durationMs=(?P<dur>\d+) "
    r"expected=(?P<exp>\d+) attempted=(?P<att>\d+) captured=(?P<cap>\d+) "
    r"failed=(?P<fail>\d+) rate=(?P<rate>[\d.]+)% bytes=(?P<bytes>\d+) "
    r"avgBytes=(?P<avg>\d+) maxBytes=(?P<maxb>\d+) capHit=(?P<cap_hit>\d+) "
    r"maxDroppedFrames=(?P<drop>\d+) minFps=(?P<fps>\S+) "
    r"trackSamples=(?P<track>\d+)"
)
NATIVE_RE = re.compile(
    r"MAPSPIKE stopRecording durationMs=(?P<dur>\d+) "
    r"encoderFrames=(?P<enc>\d+) expectedFrames=(?P<exp>[\d.]+) "
    r"droppedFrames=(?P<drop>\d+) draws=(?P<draws>\d+)"
)


def main() -> int:
    with open(sys.argv[1], errors="replace") as f:
        text = f.read()
    m = SUMMARY_RE.search(text)
    if not m:
        print("MAPSPIKE FAIL: no SUMMARY line in logcat dump")
        return 1
    s = m.groupdict()
    dur = int(s["dur"])
    exp = int(s["exp"])
    cap = int(s["cap"])
    nbytes = int(s["bytes"])
    avg = int(s["avg"])
    drop = int(s["drop"])
    rate = float(s["rate"])
    mins = dur / 60000.0

    n = NATIVE_RE.search(text)
    enc = exp_frames = native_drop = None
    if n:
        enc = int(n.group("enc"))
        exp_frames = float(n.group("exp"))
        native_drop = int(n.group("drop"))

    print(f"duration: {dur} ms ({mins:.2f} min)")
    print(f"snapshots: captured {cap}/{exp} = {rate:.1f}% "
          f"(attempted {s['att']}, failed {s['fail']}, "
          f"track samples {s['track']}, capHit {s['cap_hit']})")
    print(f"storage: {nbytes} bytes total, avg {avg} bytes/frame, "
          f"max {s['maxb']} bytes/frame")
    if n:
        print(f"encoder: {enc} frames vs {exp_frames:.0f} expected "
              f"({enc / exp_frames * 100:.1f}%), "
              f"droppedFrames={native_drop}, draws={n.group('draws')}")
    else:
        print("encoder: NO native MAPSPIKE stopRecording line found")
    print(f"dart maxDroppedFrames={drop} minFps={s['fps']}")

    ok = True
    if rate < 95.0:
        print(f"FAIL: capture rate {rate:.1f}% < 95%")
        ok = False
    if avg > 100 * 1024:
        print(f"FAIL: avg {avg} bytes/frame > 100 KB budget")
        ok = False
    if nbytes > 12 * 1024 * 1024 * mins * 1.2:
        print(f"FAIL: {nbytes} bytes > ~12 MB/min budget "
              f"({12 * mins:.1f} MB for {mins:.2f} min)")
        ok = False
    if n is None:
        print("FAIL: no native encoder line — frame-count check unmeasured")
        ok = False
    else:
        frames_ok = enc >= 0.95 * exp_frames or native_drop == 0
        if not frames_ok:
            print(f"FAIL: encoder {enc} < 95% of {exp_frames:.0f} AND "
                  f"droppedFrames={native_drop} > 0")
            ok = False
    print("MAPSPIKE " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
