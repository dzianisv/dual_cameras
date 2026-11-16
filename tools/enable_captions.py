#!/usr/bin/env python3
"""Turn ON the Auto-captions switch in the open Settings sheet.

The long-recording leg (issues #81 + #87) records with map ON and
captions ON — the exact stop path that can throw before the save
(_mapStopCapture() awaited inside the try in _stop(), before
Gal.putVideo). Captions on/off (_captions, main.dart) is in-memory
only: CameraSettings / camera_settings.json has no captions key, so
no settings-file preset can enable it. The UI toggle is the only
route (scratch run 43807173448 proved it works once).

The Settings sheet rebuilds continuously (issue #86), so a single
tap can miss: up to 3 attempts — re-dump, read the switch state,
tap via tools/emulator_tap.py when off, re-check. Exit 0 only when
the switch reads checked=true; exit 1 when it cannot be turned on,
so the leg fails loudly instead of silently running captions-off.

Usage (Settings sheet already open at the Captions section):
  python3 tools/enable_captions.py
"""
import subprocess
import sys
import time
import os
import xml.etree.ElementTree as ET

NEEDLE = "Auto-captions"
UI_XML = "/tmp/ui-captions.xml"
MAX_ATTEMPTS = 3


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def switch_checked():
    """checked state of the Auto-captions switch, or None if not found.

    A SwitchListTile exposes its title+subtitle as the Switch node's
    content-desc; prefer a node that actually carries a checked
    attribute (the Switch itself) over a plain text node.
    """
    # FRESHNESS RULE (runs 43842797586 + 43846063070, issue #79):
    # `uiautomator dump` exits 0 WITHOUT writing the file when it
    # cannot get idle state — the pull then fetches a STALE device
    # file and this reads a tree from before the sheet opened.
    # Delete both files first, so a dump that writes nothing fails
    # loudly here (caught by main's retry) instead of silently
    # serving a stale tree.
    run(["adb", "shell", "rm", "-f", "/data/local/tmp/ui.xml"])
    try:
        os.remove(UI_XML)
    except FileNotFoundError:
        pass
    run(["adb", "shell", "uiautomator", "dump", "/data/local/tmp/ui.xml"],
        check=True)
    run(["adb", "pull", "/data/local/tmp/ui.xml", UI_XML], check=True)
    root = ET.parse(UI_XML).getroot()
    matches = []
    for node in root.iter("node"):
        text = node.get("text") or ""
        desc = node.get("content-desc") or ""
        if text.startswith(NEEDLE) or desc.startswith(NEEDLE):
            matches.append(node)
    if not matches:
        return None, "not found in UI dump"
    for node in matches:
        if node.get("checked") is not None:
            return node.get("checked"), (
                f"class={node.get('class')} "
                f"text={node.get('text')!r} "
                f"desc={node.get('content-desc')!r}")
    node = matches[0]
    return None, (f"matched node carries no checked state: "
                  f"class={node.get('class')} "
                  f"text={node.get('text')!r} "
                  f"desc={node.get('content-desc')!r}")


def main() -> int:
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            checked, detail = switch_checked()
        except Exception as e:  # dump/parse failed — retry, sheet may be mid-rebuild
            print(f"CAPTIONS attempt {attempt}/{MAX_ATTEMPTS}: "
                  f"UI dump failed ({e})")
            time.sleep(2)
            continue
        print(f"CAPTIONS attempt {attempt}/{MAX_ATTEMPTS}: "
              f"Auto-captions checked={checked} ({detail})")
        if checked == "true":
            print("CAPTIONS: Auto-captions is ON")
            return 0
        r = run([sys.executable, "tools/emulator_tap.py", NEEDLE])
        print(f"CAPTIONS: tap result (rc={r.returncode}): "
              f"{(r.stdout or '').strip()[-200:]}")
        time.sleep(2)
    print("CAPTIONS: FAILED — Auto-captions switch could not be turned "
          f"on after {MAX_ATTEMPTS} attempts (see issue #86)")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
