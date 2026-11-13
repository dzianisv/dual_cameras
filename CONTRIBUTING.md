# Contributing to StoryCam

StoryCam is the Android app in `packages/dual_cameras/example/` (repo:
`dzianisv/dual_cameras`). It records the front and back cameras together
and adds on-device multilingual captions. The app is built and tested by
GitHub Actions — this machine has no Flutter/Android SDK, so never try to
run `flutter` or Gradle locally; push a branch and let CI build it.

## Reporting a bug

Use the **Bug report** template. A report we can act on has: what you did,
what you expected, what happened instead, the app version (release tag),
Android version, device model, and whether captions were on (plus the
caption language). A short screen recording or the relevant `adb logcat`
lines help more than a long description. Never paste tokens, account
details, or anything from another app.

## How issues are triaged

- `bug` — confirmed broken behavior, or a report with enough detail to
  reproduce. If we can't reproduce it, the issue gets `needs-repro` and
  stays open until someone provides steps or logs.
- `enhancement` — a feature request. Small, well-scoped ones may get
  `good first issue`.
- `needs-phone` — the fix or the bug can only be verified on a real
  Android phone (no emulator in CI); these wait for a device check and
  are never closed on test results alone.
- `wontfix` / `invalid` — closed with a short reason. Closed issues are
  not deleted; the reason stays visible.

The goal is zero open issues: every report is either fixed, answered, or
closed with a reason — none left sitting.

## Pull requests

- One change per PR; keep the diff reviewable.
- New behavior needs a test in `packages/dual_cameras/example/test/`
  (widget tests for UI, unit tests for caption logic). CI runs
  `flutter analyze` and `flutter test` — both must be green.
- Never commit secrets, signing keys, or a Sentry DSN. Crash reporting
  reads its DSN from `--dart-define SENTRY_DSN` at build time only.
- Never retag or rewrite a published release. A fix ships as a new
  version with a new tag.
