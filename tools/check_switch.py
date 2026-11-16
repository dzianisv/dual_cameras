#!/usr/bin/env python3
"""Issue #81 scratch helper: report the checked state of a Switch node.

Usage: python3 tools/check_switch.py '<desc-prefix>'

Dumps the UI, finds the first node whose content-desc or text starts
with <desc-prefix> (e.g. 'Location circle' — a SwitchListTile exposes
its title+subtitle as the Switch node's content-desc, text is empty),
and prints: SWITCH '<needle>': checked=true|false | NOT FOUND.
Exit 0 when found, 1 when not found. Read-only: never taps.
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
        ["adb", "pull", "/data/local/tmp/ui.xml", "/tmp/ui-switch.xml"],
        check=True,
        capture_output=True,
    )
    root = ET.parse("/tmp/ui-switch.xml").getroot()
    for node in root.iter("node"):
        text = node.get("text") or ""
        desc = node.get("content-desc") or ""
        if text.startswith(needle) or desc.startswith(needle):
            print(
                f"SWITCH {needle!r}: checked={node.get('checked')} "
                f"class={node.get('class')} text={text!r} desc={desc!r}"
            )
            return 0
    print(f"SWITCH {needle!r}: NOT FOUND")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
