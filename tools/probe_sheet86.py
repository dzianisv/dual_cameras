#!/usr/bin/env python3
"""Probe for issue #86 (PROBE ONLY — branch probe/rebuild-measure-86, never merge).

Measures, with the Settings sheet open and the preview running:
  (a) _sheet rebuilds per second over a 30 s window, counted from the
      [SHEET86] REBUILD log lines the probe build emits in the
      AnimatedBuilder builder (logcat — NOT uiautomator, so the
      measurement cannot be blocked by the very defect it measures),
  (b) uiautomator dump latency while the sheet is open vs after it is
      closed (dump waits for UI idle; a sheet rebuilding ~2x/s should
      keep idle from settling, so dumps hit the ~10 s idle timeout).

Assumes the app is installed, the camera is open and previewing
(same point the long-rec leg taps 'Captions' from). Opens the sheet
via the 'Captions' bottom-menu button, measures, closes it with
Back, and leaves the camera screen up.

v2 changes (run 43833254525 lesson): v1 gated the measurement on
the sheet showing 'Auto-captions' in a uiautomator dump — but the
dump itself is what the defect breaks (11.7 s, empty stdout, stale
hierarchy), so v1 aborted before measuring anything. v2 does NOT
gate on any dump: the logcat rebuild count IS the sheet-open proof
(the counter only runs while the sheet builder runs). The dump
contents are reported as diagnostics only.

Always exits 0: this is a measurement, not a gate — the summary
block (PROBE86 SUMMARY) is the result. The workflow step that calls
it must not fail the leg on a probe problem.
"""
import subprocess
import sys
import time

WINDOW_SECS = 30.0
UI_XML = "/tmp/ui-probe86.xml"


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def timed_dump(label):
    """One uiautomator dump; returns seconds. Prints stdout+stderr tails."""
    t0 = time.monotonic()
    r = run(["adb", "shell", "uiautomator", "dump", "/data/local/tmp/ui.xml"])
    dt = time.monotonic() - t0
    print(f"PROBE86 DUMP {label} secs={dt:.1f} rc={r.returncode} "
          f"out={(r.stdout or '').strip()[:120]!r} "
          f"err={(r.stderr or '').strip()[:120]!r}", flush=True)
    return dt


def rebuild_lines():
    """[SHEET86] REBUILD lines currently in logcat."""
    r = run(["adb", "logcat", "-d"])
    return [ln for ln in (r.stdout or "").splitlines()
            if "[SHEET86] REBUILD" in ln]


def dump_markers():
    """Which sheet/camera markers the latest dump hierarchy contains.

    Diagnostic only: with the defect live the dump may be stale (idle
    timeout), so absence here proves nothing — the logcat count is
    the proof. Presence of 'Camera settings' would corroborate.
    """
    run(["adb", "pull", "/data/local/tmp/ui.xml", UI_XML])
    try:
        with open(UI_XML, encoding="utf-8", errors="replace") as fh:
            xml = fh.read()
    except OSError as e:
        print(f"PROBE86 MARKERS pull failed: {e}", flush=True)
        return
    for marker in ("Camera settings", "Auto-captions", "Compass mode",
                   "Start recording", "Captions"):
        print(f"PROBE86 MARKERS {marker!r} present={marker in xml}",
              flush=True)


def main() -> int:
    print("PROBE86 START: opening Settings sheet via 'Captions'", flush=True)
    r = run([sys.executable, "tools/emulator_tap.py", "Captions"])
    print(f"PROBE86 TAP Captions rc={r.returncode} "
          f"out={(r.stdout or '').strip()[-200:]!r}", flush=True)
    if r.returncode != 0:
        print("PROBE86 ABORT: 'Captions' button not found — sheet never "
              "opened", flush=True)
        return 0
    time.sleep(3)

    # Steady-state window: clear logcat AFTER the sheet opened, so the
    # open burst does not pollute the rate; settle 2 s, then measure.
    # The rebuild count is the sheet-open proof: the counter only
    # increments while the sheet builder runs.
    run(["adb", "logcat", "-c"])
    time.sleep(2)
    t_start = time.monotonic()
    dump_secs = []
    while time.monotonic() - t_start < WINDOW_SECS:
        dump_secs.append(timed_dump("sheet-open"))
    window = time.monotonic() - t_start
    lines = rebuild_lines()
    n = len(lines)
    rate = n / window if window else 0.0
    print(f"PROBE86 REBUILDS n={n} window={window:.1f}s rate={rate:.2f}/s",
          flush=True)
    if lines:
        print(f"PROBE86 REBUILDS first={lines[0].strip()[:200]!r}",
              flush=True)
        print(f"PROBE86 REBUILDS last={lines[-1].strip()[:200]!r}",
              flush=True)
    dump_markers()

    # Control: close the sheet, then time dumps on the bare camera
    # screen, and confirm no further rebuild lines appear (the sheet
    # builder is disposed once the sheet is gone).
    run(["adb", "shell", "input", "keyevent", "4"])
    time.sleep(2)
    control_secs = [timed_dump("sheet-closed") for _ in range(3)]
    n_after = len(rebuild_lines())
    print(f"PROBE86 REBUILDS after-close total={n_after} "
          f"(window n={n}; equal means zero rebuilds after close)",
          flush=True)

    def fmt(xs):
        return ",".join(f"{x:.1f}" for x in xs)

    print("PROBE86 SUMMARY "
          f"rebuilds={n} window={window:.1f}s rate={rate:.2f}/s "
          f"rebuilds_after_close={n_after - n} "
          f"dumps_sheet_open_s=[{fmt(dump_secs)}] "
          f"dumps_sheet_closed_s=[{fmt(control_secs)}]", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
