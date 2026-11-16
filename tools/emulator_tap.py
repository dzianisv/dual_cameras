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

ANR RULE (runs 43817680362 + 43821624111, 2026-11-16): the loaded CI
emulator throws a "Process system isn't responding" dialog at random
points mid-walkthrough (filter taps in 43821624111, settings sections
in 43817680362) — while it is up, dumps hold only the dialog's tree
and every tap misses. dump_ui() therefore taps the dialog's 'Wait'
button and re-dumps once, and retries a SIGKILLed dump (exit 137)
once, before any caller sees the tree. A dialog that will not dismiss
or a dump that keeps failing still fails loudly.
"""

import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET


def _dump_once():
    # FRESHNESS RULE (runs 43842797586 + 43846063070): `uiautomator
    # dump` exits 0 WITHOUT writing the file when it cannot get idle
    # state ("ERROR: could not get idle state" — the app never idles
    # while the map ticks and the sheet rebuilds, issue #86). The
    # pull then fetches the STALE device file and every caller reads
    # a tree from before the sheet opened: ensure-switch-on reported
    # 'Location circle' absent from 3 dumps although shots 08 + 20
    # show it visibly ON. Delete both files first, so a dump that
    # writes nothing fails loudly on the pull (CalledProcessError,
    # retried by dump_ui) instead of silently serving a stale tree.
    subprocess.run(["adb", "shell", "rm", "-f", "/data/local/tmp/ui.xml"],
                   capture_output=True)
    try:
        os.remove("/tmp/ui.xml")
    except FileNotFoundError:
        pass
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


def _anr_wait_node(root):
    """The 'Wait' button of an ANR ('... isn't responding') dialog,
    or None. While the dialog is up the dump holds only the dialog's
    tree, so every tap would miss until it is dismissed."""
    if not any("isn't responding" in (n.get("text") or "")
               for n in root.iter("node")):
        return None
    return find_node(root, "Wait")


def dump_ui():
    """uiautomator dump with two resiliences for the loaded CI
    emulator (issue #79, runs 43817680362 + 43821624111): the dump
    itself is sometimes SIGKILLed (exit 137) under load — retry once;
    and an ANR dialog ('Process system isn't responding') sometimes
    covers the app mid-walkthrough — tap its 'Wait' button and
    re-dump once, so the caller sees the app's tree, not the dialog's.
    A dump that still fails, or a dialog that will not dismiss, fails
    loudly as before — never a silent pass."""
    dismissed = False
    for _ in range(2):
        try:
            root = _dump_once()
        except subprocess.CalledProcessError as e:
            print(f"uiautomator dump failed: exit {e.returncode} — "
                  f"retrying once after 3 s")
            time.sleep(3)
            continue
        wait = None if dismissed else _anr_wait_node(root)
        if wait is None:
            return root
        x1, y1, x2, y2 = node_bounds(wait)
        print("ANR dialog up ('... isn't responding') — tapping 'Wait' "
              f"at {(x1 + x2) // 2},{(y1 + y2) // 2} and re-dumping")
        subprocess.run(["adb", "shell", "input", "tap",
                        str((x1 + x2) // 2), str((y1 + y2) // 2)],
                       check=True)
        dismissed = True
        time.sleep(2)
    # Both attempts exhausted (dump kept failing): one last dump,
    # whose failure now raises loudly instead of passing silently.
    return _dump_once()


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
    """Scroll a horizontal row at a visible label's y. Up to 3
    attempts: a dump can die (exit 137) or return a tree without the
    label while the sheet rebuilds (issue #86) — run 43833599869
    failed a bare tap the same way. A swipe that lands is still a
    single swipe; only the locate step retries."""
    for attempt in range(1, 4):
        try:
            root = dump_ui()
        except subprocess.CalledProcessError as e:
            print(f'swipe-on "{needle}": attempt {attempt}/3: dump '
                  f'failed (exit {e.returncode}) — retrying')
            time.sleep(2)
            continue
        node = find_node(root, needle)
        if node is None:
            print(f'swipe-on "{needle}": attempt {attempt}/3: NOT '
                  f'FOUND — retrying')
            time.sleep(2)
            continue
        break
    else:
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
    30 s recording runs with map ON + captions ON). Reads the
    Switch state and taps it only when off, then re-reads and fails
    loudly if it did not turn on. Already-on is a PASS, not a tap.
    Up to 3 attempts: the Settings sheet rebuilds continuously
    (issue #86), so a single dump can miss the label entirely.

    MATCHER (run 43842797586): the first version looked for the
    label node and then the nearest android.widget.Switch by Y —
    it failed 3/3 on 'Location circle' although the switch was
    visibly ON in shots 08 + 20. The proven matcher is
    tools/enable_captions.py (main, 6 green smoke runs): a
    SwitchListTile exposes its title+subtitle as the Switch node's
    content-desc, so match nodes whose text/desc start with the
    label and prefer one carrying a `checked` attribute — that node
    IS the Switch, no Y-proximity guess needed. Tapping the row
    toggles it. When the switch is not found, the log now says
    WHAT the dump held (label present? switches present?) instead
    of the old conflated 'not in tree', so the next failure is
    diagnosable from the log alone.
    """
    for attempt in range(1, 4):
        try:
            root = dump_ui()
        except subprocess.CalledProcessError as e:
            # FRESHNESS RULE: a dump that cannot get idle state now
            # fails loudly (no file written) instead of serving a
            # stale tree — retry the attempt, as tap() does.
            print(f'attempt {attempt}/3: dump failed (exit '
                  f'{e.returncode}) — retrying')
            time.sleep(2)
            continue
        switch = None
        seen = []
        for node in root.iter("node"):
            text = node.get("text") or ""
            desc = node.get("content-desc") or ""
            if text.startswith(label) or desc.startswith(label):
                seen.append((node.get("class"), node.get("checked"),
                             desc or text))
                # Prefer the Switch itself: in the real tree the tile's
                # title+subtitle are the Switch node's content-desc and
                # there is no separate title node (smoke run 43836635166:
                # class=android.widget.Switch, checked=false->true).
                # Fall back to the first startswith match carrying a
                # checked attribute, as enable_captions.py does.
                if node.get("class") == "android.widget.Switch":
                    switch = node
                    break
                if switch is None and node.get("checked") is not None:
                    switch = node
        if switch is None:
            print(f'attempt {attempt}/3: switch "{label}" not found '
                  f'(label matches in tree: {seen}) — retrying')
            time.sleep(2)
            continue
        if switch.get("checked") == "true":
            print(f'switch "{label}": already ON')
            return 0
        x1, y1, x2, y2 = node_bounds(switch)
        subprocess.run(["adb", "shell", "input", "tap",
                        str((x1 + x2) // 2), str((y1 + y2) // 2)],
                       check=True)
        time.sleep(1)
        try:
            root = dump_ui()
        except subprocess.CalledProcessError as e:
            print(f'attempt {attempt}/3: re-read dump failed (exit '
                  f'{e.returncode}) — retrying')
            time.sleep(2)
            continue
        switch = None
        for node in root.iter("node"):
            text = node.get("text") or ""
            desc = node.get("content-desc") or ""
            if ((text.startswith(label) or desc.startswith(label))
                    and (node.get("class") == "android.widget.Switch"
                         or node.get("checked") is not None)):
                switch = node
                if node.get("class") == "android.widget.Switch":
                    break
        if switch is not None and switch.get("checked") == "true":
            print(f'switch "{label}": OFF -> ON')
            return 0
        print(f'attempt {attempt}/3: "{label}" did not turn on — '
              f'retrying')
        time.sleep(2)
    print(f'SWITCH FAILED: "{label}" not ON after 3 attempts')
    return 1
    return 1


def tap(needle):
    """Tap a visible UI element by its text (up to 3 attempts).

    A dump can die (exit 137) or return a tree without the label
    while the sheet rebuilds (issue #86) or the app restarts — run
    43833599869 failed a bare 'Map' tap exactly that way (two dumps
    died, the third tree held no camera screen). Only the locate
    step retries; a tap that lands is still a single tap. Genuinely
    absent labels still fail loudly after 3 attempts.
    """
    # MATCH RULE (run 43534775105, 2026-11-14): the first node whose text
    # merely CONTAINS the needle is not necessarily the button. Tapping
    # 'Allow' hit the permission dialog's TITLE ("Allow StoryCam to send
    # you notifications?") at (160,280) instead of the Allow button, so
    # the dialog stayed up and the next tap ('Captions') failed. Prefer
    # an exact text/content-desc match, then a clickable node; only then
    # fall back to the first substring match in document order.
    for attempt in range(1, 4):
        try:
            root = dump_ui()
        except subprocess.CalledProcessError as e:
            print(f'tap "{needle}": attempt {attempt}/3: dump failed '
                  f'(exit {e.returncode}) — retrying')
            time.sleep(2)
            continue
        matches = []
        for node in root.iter("node"):
            text = node.get("text") or ""
            desc = node.get("content-desc") or ""
            if needle in (text + desc):
                exact = text == needle or desc == needle
                clickable = node.get("clickable") == "true"
                matches.append((node, exact, clickable))
        if not matches:
            print(f'tap "{needle}": attempt {attempt}/3: NOT FOUND — '
                  f'retrying')
            time.sleep(2)
            continue
        break
    else:
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
