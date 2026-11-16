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
  python3 tools/emulator_tap.py --drag-slider '<label-prefix>' <to-frac>
  python3 tools/emulator_tap.py --lens-pills
  python3 tools/emulator_tap.py --ensure-switch-on '<label>'

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
--drag-slider drags the map-zoom slider, whose row sits just below
its 'Map zoom X.X' label: the SeekBar node's centre when one sits
just below the label, else the label centre + 5% of the screen height
(measured on run 43817680362's 20-section-map shot — the old 8%
overshot the track). Labels are matched on text OR content-desc:
Flutter exposes them as content-desc (run 43817680362: the 'Map
zoom' label and the "1" lens pill both have text='' with the label
in content-desc). Every swipe/drag mode re-dumps and verifies
where it can: --drag-slider reads the value before and after and
exits 1 when it did not change, so a missed slider fails loudly
instead of screenshotting the same zoom. Coordinates come from
`adb shell wm size` (the CI emulator is 320x640) plus the anchor
node's bounds — never hardcoded pixels. (--swipe-up-on, the sheet
scroller, was removed in the Track A rework: never called, the sheet
scrolls with raw `adb shell input swipe`.)

TRACK A (2026-11-16, issue #79): --lens-pills taps every lens pill
on the camera screen (labels are the zoom ratios the camera API
reports, e.g. "0.5"/"1"/"1.5" — discovered from the live tree, never
hardcoded) and verifies after each tap that the app is alive, no
error text appeared, and the pill is still present; --ensure-switch-on
reads a Settings SwitchListTile's Switch state and taps it only when
off, then re-reads and fails loudly if it did not turn on. Pills
absent (the API reported no lenses) is reported honestly, not failed:
on this emulator the camera may offer a single lens.
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


def drag_slider(prefix, to_frac):
    """Drag the slider below a label (issue #79, Stage 4 note N4).

    The label node is found by text OR content-desc starting with the
    prefix (Flutter exposes these labels as content-desc, not text —
    run 43817680362: the 'Map zoom' label was invisible to a
    text-only match). The slider row y is the SeekBar node's centre
    when one sits just below the label, else the label centre + 5% of
    the screen height (measured on run 43817680362's 20-section-map
    shot: label ~470, track ~500 in 320x640 — the old 8% overshot the
    track). Reads the value before and after and exits 1 when it did
    not change, so a missed slider fails loudly."""
    root = dump_ui()

    def label_text(n):
        return n.get("text") or n.get("content-desc") or ""

    node = None
    for cand in root.iter("node"):
        if label_text(cand).startswith(prefix):
            node = cand
            break
    if node is None:
        print(f'NOT FOUND: no node starting with "{prefix}"')
        return 1

    def value_of(n):
        m = re.search(r"([0-9]+(?:\.[0-9]+)?)\s*$", label_text(n))
        return m.group(1) if m else None

    before = value_of(node)
    if before is None:
        print(f'no numeric value in node text: {label_text(node)!r}')
        return 1
    w, h = screen_size()
    _, y1, _, y2 = node_bounds(node)
    label_y = (y1 + y2) // 2
    y = label_y + int(0.05 * h)  # fallback: track just below the label
    for cand in root.iter("node"):
        if "SeekBar" not in (cand.get("class") or ""):
            continue
        _, sy1, _, sy2 = node_bounds(cand)
        cy = (sy1 + sy2) // 2
        if label_y < cy <= label_y + int(0.20 * h):
            y = cy
            break
    print(f"slider {prefix}: value {before}, dragging at y={y}")
    swipe(int(0.10 * w), y, int(float(to_frac) * w), y, 500)
    time.sleep(1)
    root = dump_ui()
    node = None
    for cand in root.iter("node"):
        if label_text(cand).startswith(prefix):
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


def app_alive():
    r = subprocess.run(["adb", "shell", "pidof", "app.storycam"],
                       capture_output=True, text=True)
    return r.returncode == 0 and bool(r.stdout.strip())


def lens_pills():
    """Tap every lens pill on the camera screen (issue #79, Stage 4
    note N1). Pill labels are the zoom ratios the camera API reports
    ("0.5"/"1"/"1.5" — LensOption.label); they are discovered from the
    live tree as exact numeric-only texts, never hardcoded. After each
    tap: the app must still be alive, no error text may appear in the
    tree, and the pill must still be present. The selected pill's state
    is colour-only (white vs dark) and is NOT exposed to uiautomator,
    so this step proves tap-ability + no-error, not the selected
    colour — the screenshot after the step is the visual record. No
    pills at all (the API reported no lenses on this emulator) is
    reported honestly and exits 0."""
    root = dump_ui()
    pills = []
    seen = set()
    for node in root.iter("node"):
        # Flutter exposes the pill label as content-desc, not text
        # (run 43817680362: the single "1" pill is visible in
        # 18-lens-pills.png but has text='' desc='1').
        text = node.get("text") or node.get("content-desc") or ""
        if re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", text) and text not in seen:
            seen.add(text)
            pills.append(text)
    if not pills:
        print("WALKTHROUGH lens-pills: ABSENT (no numeric lens pills in "
              "the tree — the camera API reported no lenses here)")
        return 0
    print(f"WALKTHROUGH lens-pills: found {pills}")
    for label in pills:
        root = dump_ui()
        node = find_node(root, label)
        if node is None:
            print(f'WALKTHROUGH lens-pills: FAIL ({label!r} vanished)')
            return 1
        x1, y1, x2, y2 = node_bounds(node)
        x, y = (x1 + x2) // 2, (y1 + y2) // 2
        subprocess.run(["adb", "shell", "input", "tap", str(x), str(y)],
                       check=True)
        time.sleep(2)
        if not app_alive():
            print(f"WALKTHROUGH lens-pills: FAIL (app died after "
                  f"tapping {label!r})")
            return 1
        root = dump_ui()
        texts = [(n.get("text") or "") for n in root.iter("node")]
        if any("Could not" in t or "failed" in t.lower() for t in texts):
            print(f"WALKTHROUGH lens-pills: FAIL (error text after "
                  f"tapping {label!r})")
            return 1
        if find_node(root, label) is None:
            print(f"WALKTHROUGH lens-pills: FAIL ({label!r} gone after "
                  f"its own tap)")
            return 1
        print(f"WALKTHROUGH lens-pills: PASS ({label!r} tapped, app "
              f"alive, no error)")
    return 0


def ensure_switch_on(label):
    """Ensure a Settings SwitchListTile is ON (issue #79 + #87: the
    30 s recording runs with map ON + captions ON). Finds the label
    node, then the android.widget.Switch on the same row, reads its
    checked state, taps the switch only when off, re-dumps and fails
    loudly if it did not turn on. Already-on is a PASS, not a tap."""
    root = dump_ui()
    label_node = find_node(root, label)
    if label_node is None:
        print(f'NOT FOUND: switch label "{label}"')
        return 1
    lx1, ly1, lx2, ly2 = node_bounds(label_node)
    ly = (ly1 + ly2) // 2
    switch = None
    best_gap = None
    for node in root.iter("node"):
        if node.get("class") != "android.widget.Switch":
            continue
        _, sy1, _, sy2 = node_bounds(node)
        gap = abs((sy1 + sy2) // 2 - ly)
        if best_gap is None or gap < best_gap:
            switch, best_gap = node, gap
    if switch is None or best_gap > (ly2 - ly1) // 2 + 20:
        print(f'NOT FOUND: no Switch on the "{label}" row')
        return 1
    if switch.get("checked") == "true":
        print(f'switch "{label}": already ON')
        return 0
    x1, y1, x2, y2 = node_bounds(switch)
    subprocess.run(["adb", "shell", "input", "tap",
                    str((x1 + x2) // 2), str((y1 + y2) // 2)], check=True)
    time.sleep(1)
    root = dump_ui()
    label_node = find_node(root, label)
    if label_node is None:
        print(f'NOT FOUND after tap: switch label "{label}"')
        return 1
    lx1, ly1, lx2, ly2 = node_bounds(label_node)
    ly = (ly1 + ly2) // 2
    switch = None
    best_gap = None
    for node in root.iter("node"):
        if node.get("class") != "android.widget.Switch":
            continue
        _, sy1, _, sy2 = node_bounds(node)
        gap = abs((sy1 + sy2) // 2 - ly)
        if best_gap is None or gap < best_gap:
            switch, best_gap = node, gap
    if (switch is None or best_gap > (ly2 - ly1) // 2 + 20
            or switch.get("checked") != "true"):
        print(f'SWITCH FAILED: "{label}" did not turn on')
        return 1
    print(f'switch "{label}": OFF -> ON')
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
    if len(argv) == 3 and argv[0] == "--drag-slider":
        return drag_slider(argv[1], argv[2])
    if len(argv) == 1 and argv[0] == "--lens-pills":
        return lens_pills()
    if len(argv) == 2 and argv[0] == "--ensure-switch-on":
        return ensure_switch_on(argv[1])
    if len(argv) == 1:
        return tap(argv[0])
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
