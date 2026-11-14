#!/usr/bin/env python3
"""Assert the Android share sheet (chooser) is open on the emulator.

Usage: python3 tools/assert_share_chooser.py

Run after tapping 'Share' in the screenshots workflow (issue #14).
Dumps the UI hierarchy and checks for the chooser: either the chooser
title passed to Intent.createChooser ("Share video") or, on a bare
emulator image with zero apps that accept video/mp4, the empty-state
text "No apps can perform this action". Either one proves the chooser
opened without crashing the app; a target list is NOT required (the
intent resolution matches action + type only, not EXTRA_STREAM, so
this check proves the intent fired — it does NOT prove the video was
attached; only the owner's real-phone test proves that).

Prints every visible text node so the CI log records the actual
share-target list the chooser showed (or that it was empty).
Exits 1 when the chooser is not visible, so the workflow fails loudly.
"""

import subprocess
import sys
import xml.etree.ElementTree as ET

TITLE = "Share video"
EMPTY = "No apps can perform this action"


def main() -> int:
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
    texts = []
    for node in root.iter("node"):
        text = (node.get("text") or "").strip()
        if text:
            texts.append(text)
    print("SHARE CHOOSER TEXTS:")
    for text in texts:
        print(f"  - {text!r}")
    if TITLE in texts:
        print(f'CHOOSER OPEN: title {TITLE!r} present')
        return 0
    if EMPTY in texts:
        print(f'CHOOSER OPEN (no targets): {EMPTY!r} present')
        return 0
    print(f'CHOOSER NOT FOUND: neither {TITLE!r} nor {EMPTY!r} in dump')
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
