#!/usr/bin/env python3
"""Tap a visible UI element by its text on the emulator.

The UI dump goes to /data/local/tmp/ui.xml, NOT /sdcard/ui.xml:
the emulator's sdcard is not mounted when the workflow runs
(run 43501670656: `adb pull /sdcard/ui.xml` failed with
"Transport endpoint is not connected"). /data/local/tmp is always
writable by the shell user.

Usage: python3 tools/emulator_tap.py '<substring>'

Finds a node in `uiautomator dump` output whose text or
content-description contains <substring> and taps its center.
Preference: an exact text/content-desc match first, then a clickable
node — the first substring match is not necessarily the button
(run 43534775105: 'Allow' tapped the dialog title, not the button).
Exits 1 when the text is not found, so the workflow fails
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
    # MATCH RULE (run 43534775105, 2026-11-14): the first node whose text
    # merely CONTAINS the needle is not necessarily the button. Tapping
    # 'Allow' hit the permission dialog's TITLE ("Allow StoryCam to send
    # you notifications?") at (160,280) instead of the Allow button, so
    # the dialog stayed up and the next tap ('Captions') failed. Prefer
    # an exact text/content-desc match, then a clickable node; only then
    # fall back to the first substring match in document order.
    matches = []
    for node in root.iter("node"):
        text = node.get("text") or ""
        desc = node.get("content-desc") or ""
        if needle in (text + desc):
            exact = text == needle or desc == needle
            clickable = node.get("clickable") == "true"
            matches.append((node, exact, clickable))
    if not matches:
        print(f'NOT FOUND: "{needle}"')
        return 1
    for node, exact, clickable in matches:
        print(
            f'candidate: text={node.get("text")!r} '
            f'desc={node.get("content-desc")!r} '
            f'clickable={node.get("clickable")} bounds={node.get("bounds")}'
        )
    matches.sort(key=lambda m: (not m[1], not m[2]))
    node = matches[0][0]
    bounds = node.get("bounds").replace("][", ",").strip("[]").split(",")
    x1, y1, x2, y2 = map(int, bounds)
    x, y = (x1 + x2) // 2, (y1 + y2) // 2
    subprocess.run(
        ["adb", "shell", "input", "tap", str(x), str(y)], check=True
    )
    print(f'tapped "{needle}" at {x},{y}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
