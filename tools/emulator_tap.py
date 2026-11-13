#!/usr/bin/env python3
"""Tap a visible UI element by its text on the emulator.

The UI dump goes to /data/local/tmp/ui.xml, NOT /sdcard/ui.xml:
the emulator's sdcard is not mounted when the workflow runs
(run 43501670656: `adb pull /sdcard/ui.xml` failed with
"Transport endpoint is not connected"). /data/local/tmp is always
writable by the shell user.

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
import xml.etree.ElementTree as ET


def main() -> int:
    needle = sys.argv[1]
    subprocess.run(
        ["adb", "shell", "uiautomator", "dump", "/data/local/tmp/ui.xml"],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["adb", "pull", "/data/local/tmp/ui.xml", "/tmp/ui.xml"],
        check=True,
        capture_output=True,
    )
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
