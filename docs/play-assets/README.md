# StoryCam — Play store assets

Prepared 2026-11-14 for the first Play submission (v0.5.4, `app.storycam`).
Every file here is a source or a reviewed copy — nothing is a mockup.

## Files

- `storycam-icon-512.png` — the 512×512 store icon. Source of the
  launcher icons in `packages/dual_cameras/example/android/app/src/main/res/mipmap-*/ic_launcher.png`
  (48/72/96/144/192 px, resized from this file). Replaces the stock
  Flutter logo. Design: a rounded-square "scene" lens with a sunset,
  overlapped by a circular selfie lens — two cameras at once.
  Generated 2026-11-14, reviewed at full size and at 48 px.
- `storycam-feature-graphic-1024x500.png` — the 1024×500 feature
  graphic. Tagline "Film front & back at once." plus "On-device
  captions · No ads · No watermark", composited with PIL (Noto Sans)
  over a generated background in the same visual language as the icon.
  Reviewed: all text sits inside the dark panel, nothing is cut off.
- `screenshots/` — Play screenshots. See below.

## Screenshots

Play needs 2–8 phone screenshots, from real tested flows, never
mockups. Status at PR time: **none yet — the emulator workflow is
broken and no screenshot exists.**

- The first-ever dispatch of `emulator-smoke-test.yml` (run
  43491636991, 2026-11-14) FAILED before installing the APK:
  `adb: filename doesn't end .apk or .apex:` with an empty filename.
  Root cause: the runner executes each `script:` line as a separate
  `sh -c` call, so the `APK=...` variable assigned on one line does
  not exist on the next. The emulator itself booted fine (832 s) —
  the app was never installed, so this failure says nothing about
  the app.
- The fix is staged, not in this PR (workflow files cannot be pushed
  with the current token scope — apply via the GitHub web UI):
  `~/workspace/storycam/publish/emulator-smoke-test-fixed.yml`
  (one-line fix: inline the APK path) and
  `~/workspace/storycam/publish/emulator-screenshots.yml` (new
  multi-shot workflow: launch, Captions sheet, Filters sheet,
  recording, after-recording — taps via `tools/emulator_tap.py`,
  which IS in this PR). After the fixed workflow is applied and
  dispatched, review every screenshot visually before copying any
  of them here — a shot with a black preview, a cut-off button, or
  the wrong language is rejected, not shipped.
- Den's phone screenshots are still the best source (real camera
  feed); emulator shots show real UI but a virtual camera feed.

## What is NOT in this folder

- The 512×512 icon and the feature graphic are also uploaded in Play
  Console by hand — Console does not read them from the repo. This
  folder is the source of truth for what was uploaded.
- Screenshots are not final until reviewed at store size. A screenshot
  with a defect (black preview, cut-off button, wrong language) is
  rejected, not shipped.
