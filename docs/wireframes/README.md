# StoryCam wireframes — map & compass screen (issue #20)

Design for the camera screen redesign, approved by Den 2026-11-14.
Each version is one approval round; v5 is the approved design.
No implementation from the PRD until the design is approved
(framework rule: PRD first).

## Versions

- **v1** — Map circle top-left (live map, blue dot = current location,
  rotates with the compass) + Options sheet with two proposed options:
  compass mode (Heading-up / North-up) and location circle on/off.
- **v2** — Instagram-story style: video fills the whole screen, no empty
  space at the bottom; Captions chip and all settings move off the camera
  screen into a bottom text menu (Map / Front / Rear / Captions /
  Settings); tapping an item opens the Settings dialog at that section.
  Dialog sections: Map & compass, Front camera (Mirror selfie —
  proposal), Rear camera (Video quality 1080p / 4K — proposal), Captions
  (on/off + Auto / Русский / English).
- **v3** — Filter slider above the record button, iOS-style (like the
  Video / Photo / Portrait switcher): selected filter big and white,
  the rest dimmed, scrolls sideways. Filters: Original, Moody (built-in);
  Hyper, Midnight, Simple, Jakarta (Instagram-style); Vice City, San Andreas
  (game-look — names as confirmed by Den 2026-11-15, issue #61).
- **v4** — Bottom menu shows on/off at a glance: enabled = bold white,
  disabled = transparent and not bold (Map, Front, Rear, Captions;
  Settings is a button, stays bold white).
- **v5** — Lens switcher pills directly above the filter slider:
  rear 0.5 / 1, front 1 / 1.5 (1.5× as Den said, to confirm from the
  API). The app reads the lens list from the camera API (Android
  Camera2) for the active camera; switching front/rear swaps the pills;
  nothing is hardcoded.

## Closed decisions (Den)

- Tapping a bottom-menu item opens the Settings dialog at that section —
  it does not toggle the feature directly (2026-11-14).
- The menu word shows the state (bold white = on, transparent and not
  bold = off); the switch lives in the dialog.
- The PRD document for this design lives in the StoryCam Notion hub.

## Edge-to-edge (Android 15+)

- The window draws edge-to-edge: it spans the full display (explicit
  enablement, PR #108, issue #105 — native
  `WindowCompat.setDecorFitsSystemWindows(window, false)` plus Dart
  `SystemUiMode.edgeToEdge` with transparent bars). Proof: the API 35
  UI dump root bounds went from `[0,40][320,599]` (pre-fix, inset) to
  `[0,0][320,640]` (post-fix, full display).
- The preview itself stays letterboxed 9:16, centred — it does NOT
  extend behind the bars. What sits behind the status and navigation
  bars is the black letterbox background (`ColoredBox`, black), so the
  bar zones render black. Controls stay inset via the existing
  `SafeArea` wrappers; no control is clipped.
- Verification status (2026-11-21): the post-merge API 35 run
  (44854003833) is green, but its screenshots cannot prove the bars
  are transparent — black letterbox behind transparent bars looks
  identical to opaque bars. Bar transparency is being proven by a
  colour-probe build on #105 before the issue closes.

## Menu contrast (issue #110)

- The bottom-menu labels sit directly over the live camera preview,
  so over a bright preview block white text was unreadable ('Front'
  on pale yellow nearly invisible; 'Captions' low contrast).
- Treatment: a subtle vertical gradient scrim behind the menu row
  (transparent at the top, black45 at the bottom) plus a dark text
  shadow behind each label glyph. No layout change, no change to the
  state-by-word styling (bold white = on, white38 not bold = off;
  Settings stays bold white), and the menu stays one line tall.
- Verification: API 35 emulator screenshot reviewed by a reviewer
  agent, post-merge on main (verification-gated).

## Files

Each version has an `.svg` (source) and a `.png` (render, 2×).
Re-render with headless Chromium from the Playwright cache, e.g.:

```
CHROME=~/.cache/ms-playwright/chromium-1217/chrome-linux64/chrome
"$CHROME" --headless=new --disable-gpu --no-sandbox --hide-scrollbars \
  --force-device-scale-factor=2 --window-size=1400,980 \
  --screenshot=docs/wireframes/map-compass-v5.png \
  "file://$PWD/docs/wireframes/map-compass-v5.svg"
```

Read the PNG back after every render — a render is only done when a
reviewer has opened and looked at it.
