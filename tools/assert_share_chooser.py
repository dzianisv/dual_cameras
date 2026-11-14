#!/usr/bin/env python3
"""Assert the Android share sheet (chooser) is open on the emulator.

Usage: python3 tools/assert_share_chooser.py

Run after tapping 'Share' in the screenshots workflow (issue #14).
Dumps the UI hierarchy (retried: the chooser's first cold start on
the slow CI emulator can take several seconds) and checks for the
chooser by any of:
  - the chooser title passed to Intent.createChooser ("Share video"),
    in a node's text or content-description;
  - the empty-state text "No apps can perform this action" (bare
    emulator image, zero apps accept video/mp4);
  - any node from the system resolver package (com.android.intentresolver).
Any one proves the chooser opened without crashing the app; a target
list is NOT required (intent resolution matches action + type only,
not EXTRA_STREAM, so this check proves the intent fired — it does NOT
prove the video was attached; only the owner's real-phone test proves
that).

NOTE: Flutter nodes expose their labels as content-description with
EMPTY text (see the emulator_tap.py 'Share' candidates), so this
script reads text AND content-desc — a text-only check sees nothing
on a pure-Flutter screen and would false-fail.

Prints every visible text / content-desc so the CI log records the
actual share-target list the chooser showed (or that it was empty).
On failure it also prints the app's status line (a failed share
surfaces as 'Could not open share sheet...' in the status text) and
the native Share log lines, so the log distinguishes a real share
defect from a slow chooser. Exits 1 when the chooser is not visible,
so the workflow fails loudly.
"""

import subprocess
import sys
import time
import xml.etree.ElementTree as ET

TITLE = "Share video"
EMPTY = "No apps can perform this action"
RESOLVER = "intentresolver"
ATTEMPTS = 3
RETRY_SLEEP_S = 3


def dump_ui() -> ET.Element:
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


def main() -> int:
    found = None
    texts: list[str] = []
    descs: list[str] = []
    for attempt in range(1, ATTEMPTS + 1):
        root = dump_ui()
        texts = []
        descs = []
        resolver_seen = False
        for node in root.iter("node"):
            text = (node.get("text") or "").strip()
            desc = (node.get("content-desc") or "").strip()
            if text:
                texts.append(text)
            if desc:
                descs.append(desc)
            if RESOLVER in (node.get("package") or ""):
                resolver_seen = True
        labels = texts + descs
        if TITLE in labels:
            found = f"chooser title {TITLE!r} present"
            break
        if EMPTY in texts:
            found = f"chooser open with no targets: {EMPTY!r} present"
            break
        if resolver_seen:
            found = "system resolver window present"
            break
        print(f"attempt {attempt}/{ATTEMPTS}: chooser not visible yet")
        if attempt < ATTEMPTS:
            time.sleep(RETRY_SLEEP_S)
    print("SHARE CHOOSER TEXTS:")
    for text in texts:
        print(f"  - {text!r}")
    print("SHARE CHOOSER CONTENT-DESCS:")
    for desc in descs:
        print(f"  - {desc!r}")
    if found:
        print(f"CHOOSER OPEN: {found}")
        return 0
    print(
        f"CHOOSER NOT FOUND: neither {TITLE!r} nor {EMPTY!r} nor a "
        f"{RESOLVER!r} window after {ATTEMPTS} dumps"
    )
    if any("Could not open share sheet" in d for d in descs):
        print("DIAGNOSIS: app status reports the share call FAILED "
              "(native ShareChannel error) — real defect, not timing.")
    else:
        print("DIAGNOSIS: no share-failure status visible; the chooser "
              "never appeared — check the Share log lines below.")
    logcat = subprocess.run(
        ["adb", "logcat", "-d", "-s", "Share"],
        capture_output=True,
        text=True,
    )
    print("LOGCAT (tag Share):")
    print(logcat.stdout or "(no Share lines)")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
