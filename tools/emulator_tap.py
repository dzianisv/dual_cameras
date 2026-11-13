#!/usr/bin/env python3
"""Tap a visible UI element by its text on the emulator.

The UI dump goes to /data/local/tmp/ui.xml, NOT /sdcard/ui.xml:
the emulator's sdcard is not mounted when the workflow runs
(run 43501670656: `adb pull /sdcard/ui.xml` failed with
"Transport endpoint is not connected"). /data/local/tmp is always
writable by the shell user.

The dump is retried (run 43513063175): on the no-KVM software
emulator system_server starves during app startup and
`uiautomator dump` gets SIGKILLed (exit 137) — the first dump
died that way while the "System UI isn't responding" dialog was
up, which then made the `adb pull` fail too (no ui.xml was ever
written) and failed the whole screenshots job. The kill is
transient: a retry a few seconds later usually succeeds once
the system settles. The pull is retried for the same reason.

Usage: python3 tools/emulator_tap.py '<substring>'

Finds the first node in `uiautomator dump` output whose text or
content-description contains <substring> and taps its center. Used by
the emulator screenshot workflow, which cannot use shell variables or
functions (android-emulator-runner runs each script line as a separate
`sh -c`). Exits 1 when the text is not found, so the workflow fails
loudly instead of screenshotting the wrong screen.
"""

import subprocess
import sys
import time
import xml.etree.ElementTree as ET

DUMP_ATTEMPTS = 3
RETRY_DELAY_S = 10


def run_with_retries(args, attempts=DUMP_ATTEMPTS):
    """Run an adb command, retrying transient kills (exit 137 etc.)."""
    last_error = None
    for attempt in range(1, attempts + 1):
        try:
            return subprocess.run(args, check=True, capture_output=True)
        except subprocess.CalledProcessError as exc:
            last_error = exc
            print(
                f"attempt {attempt}/{attempts} failed: {' '.join(args)} "
                f"-> exit {exc.returncode}",
                file=sys.stderr,
            )
            if attempt < attempts:
                time.sleep(RETRY_DELAY_S)
    raise last_error


def main() -> int:
    needle = sys.argv[1]
    run_with_retries(
        ["adb", "shell", "uiautomator", "dump", "/data/local/tmp/ui.xml"]
    )
    run_with_retries(["adb", "pull", "/data/local/tmp/ui.xml", "/tmp/ui.xml"])
    root = ET.parse("/tmp/ui.xml").getroot()
    for node in root.iter("node"):
        text = (node.get("text") or "") + (node.get("content-desc") or "")
        if needle in text:
            bounds = node.get("bounds").replace("][", ",").strip("[]").split(",")
            x1, y1, x2, y2 = map(int, bounds)
            x, y = (x1 + x2) // 2, (y1 + y2) // 2
            subprocess.run(
                ["adb", "shell", "input", "tap", str(x), str(y)], check=True
            )
            print(f'tapped "{needle}" at {x},{y}')
            return 0
    print(f'NOT FOUND: "{needle}"')
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
