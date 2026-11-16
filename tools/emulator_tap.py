#!/usr/bin/env python3
"""Tap a visible UI element by its text on the emulator.

The UI dump goes to /data/local/tmp/ui.xml, NOT /sdcard/ui.xml:
the emulator's sdcard is not mounted when the workflow runs
(run 43501670656: `adb pull /sdcard/ui.xml` failed with
"Transport endpoint is not connected"). /data/local/tmp is always
writable by the shell user.

Usage:
  python3 tools/emulator_tap.py '<substring>'
  python3 tools/emulator_tap.py --swipe-on '<text>' left|right
  python3 tools/emulator_tap.py --swipe-up-on '<text>'
  python3 tools/emulator_tap.py --drag-slider '<label-prefix>' <to-frac>

Finds a node in `uiautomator dump` output whose text or
content-description contains <substring> and taps its center.
Preference: an exact text/content-desc match first, then a clickable
node — the first substring match is not necessarily the button
(run 43534775105: 'Allow' tapped the dialog title, not the button).
Exits 1 when the text is not found, so the workflow fails
loudly instead of screenshotting the wrong screen.

ISSUE #79 EXTENSION (2026-11-16) — the full walkthrough needs two
gestures the tap helper could not do (emulator_tap.py cannot drag a
slider or scroll a sheet): --swipe-on scrolls a horizontal row (the
filter slider) at the row's own y, found from a visible label node;
--swipe-up-on scrolls the Settings sheet up (the anchor node only
proves the sheet is open — the swipe itself runs across the screen,
from 75% to 30% of its height, inside the sheet area); --drag-slider
drags the map-zoom slider, whose row sits just below its 'Map zoom
X.X' label (code order in main.dart: label text, subtitle, Slider —
about 8% of the screen height below the label centre at 320x640).
Every swipe/drag mode re-dumps and verifies where it can: --drag-slider
reads the value before and after and exits 1 when it did not change,
so a missed slider fails loudly instead of screenshotting the same
zoom. Coordinates come from `adb shell wm size` (the CI emulator is
320x640) plus the anchor node's bounds — never hardcoded pixels.
"""

import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET


def dump_ui():
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
    return ET.parse("/tmp/ui.xml").getroot()


def find_node(root, needle):
    """Best node whose text/content-desc contains needle: exact match,
    then clickable, then first substring match (run 43534775105 rule)."""
    matches = []
    for node in root.iter("node"):
        text = node.get("text") or ""
        desc = node.get("content-desc") or ""
        if needle in (text + desc):
            exact = text == needle or desc == needle
            clickable = node.get("clickable") == "true"
            matches.append((node, exact, clickable))
    if not matches:
        return None
    matches.sort(key=lambda m: (not m[1], not m[2]))
    return matches[0][0]


def node_bounds(node):
    bounds = node.get("bounds").replace("][", ",").strip("[]").split(",")
    return tuple(map(int, bounds))


def screen_size():
    r = subprocess.run(["adb", "shell", "wm", "size"],
                       capture_output=True, text=True)
    m = re.search(r"(\d+)x(\d+)", r.stdout)
    if not m:
        raise SystemExit(f"cannot read screen size from: {r.stdout!r}")
    return int(m.group(1)), int(m.group(2))


def swipe(x1, y1, x2, y2, duration_ms=300):
    subprocess.run(
        ["adb", "shell", "input", "swipe",
         str(x1), str(y1), str(x2), str(y2), str(duration_ms)],
        check=True,
    )
    print(f"swiped {x1},{y1} -> {x2},{y2} ({duration_ms}ms)")


def swipe_on(needle, direction):
    root = dump_ui()
    node = find_node(root, needle)
    if node is None:
        print(f'NOT FOUND: "{needle}"')
        return 1
    w, _ = screen_size()
    _, y1, _, y2 = node_bounds(node)
    y = (y1 + y2) // 2
    if direction == "left":
        swipe(int(0.85 * w), y, int(0.15 * w), y)
    elif direction == "right":
        swipe(int(0.15 * w), y, int(0.85 * w), y)
    else:
        raise SystemExit(f"unknown direction: {direction!r} (left|right)")
    return 0


def swipe_up_on(needle):
    root = dump_ui()
    node = find_node(root, needle)
    if node is None:
        print(f'NOT FOUND: "{needle}"')
        return 1
    w, h = screen_size()
    x1, _, x2, _ = node_bounds(node)
    x = (x1 + x2) // 2
    swipe(x, int(0.75 * h), x, int(0.30 * h))
    return 0


def drag_slider(prefix, to_frac):
    root = dump_ui()
    node = None
    for cand in root.iter("node"):
        text = cand.get("text") or ""
        if text.startswith(prefix):
            node = cand
            break
    if node is None:
        print(f'NOT FOUND: no node starting with "{prefix}"')
        return 1

    def value_of(n):
        m = re.search(r"([0-9]+(?:\.[0-9]+)?)\s*$", n.get("text") or "")
        return m.group(1) if m else None

    before = value_of(node)
    if before is None:
        print(f'no numeric value in node text: {node.get("text")!r}')
        return 1
    w, h = screen_size()
    _, y1, _, y2 = node_bounds(node)
    y = (y1 + y2) // 2 + int(0.08 * h)  # slider row below its label
    swipe(int(0.10 * w), y, int(float(to_frac) * w), y, 500)
    time.sleep(1)
    root = dump_ui()
    node = None
    for cand in root.iter("node"):
        text = cand.get("text") or ""
        if text.startswith(prefix):
            node = cand
            break
    if node is None:
        print(f'NOT FOUND after drag: no node starting with "{prefix}"')
        return 1
    after = value_of(node)
    print(f"slider {prefix}: {before} -> {after}")
    if after is None or after == before:
        print(f"DRAG FAILED: {prefix} value did not change ({before})")
        return 1
    return 0


def tap(needle):
    root = dump_ui()
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
    x1, y1, x2, y2 = node_bounds(node)
    x, y = (x1 + x2) // 2, (y1 + y2) // 2
    subprocess.run(
        ["adb", "shell", "input", "tap", str(x), str(y)], check=True
    )
    print(f'tapped "{needle}" at {x},{y}')
    return 0


def main() -> int:
    argv = sys.argv[1:]
    if len(argv) == 3 and argv[0] == "--swipe-on":
        return swipe_on(argv[1], argv[2])
    if len(argv) == 2 and argv[0] == "--swipe-up-on":
        return swipe_up_on(argv[1])
    if len(argv) == 3 and argv[0] == "--drag-slider":
        return drag_slider(argv[1], argv[2])
    if len(argv) == 1:
        return tap(argv[0])
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
