# Google Play readiness — StoryCam

Status: **not ready to submit — preparation done, three Den-only gates
remain**. The app today is a sideload-only test build (v0.5.4,
debug-signed, package `app.storycam`). This page lists exactly what is
done, what this PR prepared, and what is still missing, with who can
supply it.

Audited 2026-11-14 against main `39b98eb` (v0.5.4, versionCode 9).

## Verified this run

- **AAB artifact** from the v0.5.4 tag CI run (43485921761, SUCCESS):
  `storycam-play-release.aab`, 37,934,464 B, SHA-256
  `83db079c887043076ab038e88151c925bcbb10842ea79bbd60e41ab2fa23cef4`
  (verified against `SHA256SUMS.aab`, `sha256sum -c` OK). Manifest:
  package `app.storycam`, versionName `0.5.4`, `MainActivity`
  `app.storycam.MainActivity`. Libraries: arm64-v8a only (10 libs,
  incl. libapp, libflutter, libonnxruntime, libsherpa-onnx). APK from
  the same run: 47,000,875 B, SHA-256 `dca97383…` (OK), badging
  `app.storycam`, versionCode 9, versionName 0.5.4, minSdk 24,
  **targetSdk 36**, label StoryCam, v2-signed with the Android Debug
  certificate. Target SDK 36 meets Play's requirement for new apps
  (API 35+ since August 2025).
- **Privacy policy live**: https://dzianisv.github.io/dual_cameras/privacy.html
  returns 200 with the correct content. Version line bumped to 0.5.4
  in this PR (it said 0.5.3).
- **No analytics, no ads, no account**: `pubspec.yaml` has no
  analytics/ads SDK; the only network use is the one-time caption
  model download from Hugging Face over HTTPS. See
  `docs/play-data-safety.md` for the form answers this implies.

## Prepared in this PR

- Store icon: custom StoryCam icon replaces the stock Flutter logo —
  `docs/play-assets/storycam-icon-512.png` (512×512, store upload)
  and the five launcher densities in
  `android/app/src/main/res/mipmap-*/ic_launcher.png`.
- Feature graphic: `docs/play-assets/storycam-feature-graphic-1024x500.png`
  ("Film front & back at once." + on-device captions / no ads / no
  watermark). Reviewed at full size; all text inside the dark panel.
- Data Safety + content-rating drafts: `docs/play-data-safety.md`
  (grounded in the manifest, `crash_reporting.dart`, and
  `model_manager.dart` — read them before answering in Console).
- Play listing text, English + Russian: `docs/play-listing.md`
  (title, short description, full description — honest, test-build
  features only).
- ASO keyword set with rationale: `docs/aso-keywords.md`.
- Privacy policy: `website/privacy.html` (linked from the site footer
  and `sitemap.xml`).
- Crash reporting prep: `sentry_flutter` wired in the example app, DSN
  from `--dart-define SENTRY_DSN`, fully disabled without one
  (`packages/dual_cameras/example/lib/crash_reporting.dart`). Needs only
  a Sentry project + DSN (free tier) to go live.
- GitHub issue templates + triage rules: `.github/ISSUE_TEMPLATE/`,
  `CONTRIBUTING.md`.
- `flutter build appbundle` step in CI: **done** — `build-apk.yml`
  builds and verifies the AAB alongside the APK on every tag build
  (package + arm64 checks in the "Verify StoryCam app bundle" step).

## Only Den can supply

1. **Google Play developer account** — $25 one-time fee, identity
   verification, and sign-in with his Google account. No agent can do
   this: it needs his account and his payment.
2. **Production signing key** — CI signs the release build with the
   debug key (`signingConfig = signingConfigs.getByName("debug")`).
   The v0.5.4 AAB is debug-signed and verified as a build artifact,
   but it is **not** a production-signed upload: the debug key is a
   public, well-known key and must not be the Play upload key. A
   production upload keystore + Play App Signing enrollment is needed.
   The keystore and its passwords must live in Den's custody; CI gets
   them as secrets only when he says so. Switching the signing config
   is a one-line change once the keystore exists — but the keystore
   itself cannot be created by an agent.
3. **Sentry DSN (optional for first submission)** — the app works
   without it (crash reporting stays off). Supplying it turns on
   crash reports; the Data Safety answers change with it (see
   `docs/play-data-safety.md`).
4. **Content rating questionnaire + Data Safety form** — Den answers
   them in Play Console. Drafts are in `docs/play-data-safety.md`
   (no ads, no account, no data collection except optional crash
   reports once Sentry is live).
5. **The $25 fee** (part of item 1).

## Agent work still needed before submission

- **Play screenshots (2–8) — none yet.** The first-ever dispatch of
  `emulator-smoke-test.yml` (run 43491636991, 2026-11-14) FAILED
  before installing the APK: the runner executes each `script:` line
  as a separate `sh -c` call, so the `APK=...` variable did not
  survive to the install line. The emulator booted fine; the app was
  never installed — this failure is a workflow bug, not an app bug.
  The fix is staged at
  `~/workspace/storycam/publish/emulator-smoke-test-fixed.yml` and
  the multi-shot workflow at
  `~/workspace/storycam/publish/emulator-screenshots.yml` (taps via
  `tools/emulator_tap.py`, included in this PR). Both need applying
  via the GitHub web UI (workflow files cannot be pushed with the
  current token scope), then dispatch; every screenshot must be
  visually reviewed before it goes into
  `docs/play-assets/screenshots/`. Den's phone screenshots remain
  the best source (real camera feed).
- **In-app review prompt — not wired.** The app has no rating prompt
  (no `in_app_review` dependency; the "review" hits in the code are
  "preview"). The first-1,000-installs plan needs a prompt after
  activation (Play In-App Review API, never on first open). File as
  a follow-up issue; it ships as a new version before the growth
  push, not before the first internal-track submission.
- **No analytics events.** The skill's funnel events
  (`app_open`, `core_action_done`, …) are not implemented — there is
  no analytics SDK. Until they exist, growth is measured from Play
  Console numbers only. File as a follow-up; it does not block the
  first submission.
- **Promo video (30–60 s).** Optional for the first submission;
  record it from the first real-phone test.
- Switch the release signing config from the debug key to the upload
  keystore (after item 2 above).
- First submission on an internal/closed track, not production.

## What is NOT blocking

- The app itself is releasable as a test build: CI green, 90 + 5 tests,
  host inference verified, APK + AAB hash-verified. The blockers above
  are account, identity, and store assets — not code.
- Package name is settled: `app.storycam` (renamed from the plugin
  demo's `com.romanslack.dual_cameras_example` before the first
  production upload, when there were no production users). Play
  forbids changing the applicationId after the first release, so this
  id is now permanent. Never change it.
