# Google Play readiness — StoryCam

Status: **not ready to submit — preparation done, two Den-only gates
remain** (production signing keystore; content-rating questionnaire +
Data Safety form), plus an optional Sentry DSN and an optional PostHog
API key. The app today is a
sideload-only build (v0.5.9, debug-signed, package `app.storycam`).
This page lists exactly what is done, what this PR prepared, and what
is still missing, with who can supply it.

Audited 2026-11-15 against main `828f887b` with PR #32 applied
(v0.5.9, versionCode 14).

## Verified this run

- **AAB artifact** from the v0.5.9 tag CI run (43612415163, SUCCESS):
  `storycam-play-release.aab`, 38,713,182 B, SHA-256
  `aec60358658c3df7a1f73e388195fb9173e339a2fb400721454f8a1e6cad1ce3`
  (verified against `SHA256SUMS.aab`, `sha256sum -c` OK). Manifest:
  package `app.storycam`, versionName `0.5.9`, `MainActivity`
  `app.storycam.MainActivity`. Libraries: arm64-v8a only (10 libs,
  incl. libapp, libflutter, libonnxruntime, libsherpa-onnx). APK from
  the same run: 47,798,753 B, SHA-256
  `5aa0ad54e699ce8232413e38f4cbded8a6f86d021737e3487d968c8b053e3568`
  (OK), badging `app.storycam`, versionCode 14, versionName 0.5.9,
  minSdk 24, **targetSdk 36**, label StoryCam, v2-signed with the
  Android Debug certificate. Target SDK 36 meets Play's requirement
  for new apps (API 35+ since August 2025).
- **Release signing wiring (issue #32, this PR)**: `build.gradle.kts`
  reads the upload keystore from the four `STORYCAM_*` env vars and
  falls back to the debug key when they are absent, so tag builds
  keep working unchanged. CI proves the wiring with a separate
  `prove-release-signing` job in `build-apk.yml` that builds the AAB
  + APK with a CI-generated throwaway keystore (CN=StoryCam CI Proof,
  1-day validity, deleted at job end) and asserts the signature is
  the throwaway cert, not the debug key. The real keystore swaps in
  via the `STORYCAM_KEYSTORE_BASE64` secret with no code change. The
  published v0.5.9 release still carries the old title and the old
  test-named APK asset until it is re-released (parent act
  after this PR merges); the new title is `v0.5.9 - StoryCam` and the
  new asset is `storycam-0.5.9-arm64.apk`.
- **Privacy policy live**: https://dzianisv.github.io/dual_cameras/privacy.html
  returns 200 with the correct content. Version line bumped to 0.5.9
  in this PR (it said 0.5.4); the live page picks it up on the next
  site deploy.
- **No ads, no account; analytics key-gated**: `pubspec.yaml` has no
  ads SDK; the only network use is the one-time caption
  model download from Hugging Face over HTTPS, plus PostHog analytics
  only when the build carries `--dart-define POSTHOG_API_KEY`
  (issue #38 — without the key PostHog is never initialized and sends
  nothing). See `docs/play-data-safety.md` for the form answers this
  implies.

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
  (title, short description, full description — honest, current
  features only).
- ASO keyword set with rationale: `docs/aso-keywords.md`.
- Privacy policy: `website/privacy.html` (linked from the site footer
  and `sitemap.xml`).
- Crash reporting prep: `sentry_flutter` wired in the example app, DSN
  from `--dart-define SENTRY_DSN`, fully disabled without one
  (`packages/dual_cameras/example/lib/crash_reporting.dart`). Needs only
  a Sentry project + DSN (free tier) to go live.
- Analytics prep (issue #38, this PR): `posthog_flutter` wired in the
  example app, API key from `--dart-define POSTHOG_API_KEY`, fully
  disabled without one (`packages/dual_cameras/example/lib/analytics.dart`).
  Fires the 8 funnel events (`app_open`, `record_started`,
  `core_action_done`, `core_action_repeat`, `captions_done`,
  `share_done`, `model_ready`, `model_download_failed`), each carrying
  `app_version` + `install_source` and no personal data. Needs only a
  PostHog project + API key (US host) to go live; live-key verification
  is a Den-owned residual.
- GitHub issue templates + triage rules: `.github/ISSUE_TEMPLATE/`,
  `CONTRIBUTING.md`.
- `flutter build appbundle` step in CI: **done** — `build-apk.yml`
  builds and verifies the AAB alongside the APK on every tag build
  (package + arm64 checks in the "Verify StoryCam app bundle" step).
- Release signing wiring + publish-build naming (issue #32, this PR):
  `release` signingConfig from env/CI secrets with a debug fallback,
  CI throwaway-keystore proof job, APK asset renamed to
  `storycam-<version>-arm64.apk`, release title without the old
  "test" qualifier, and the old test-named wording removed from the
  release body, website, and docs. `prerelease: true` stays for 0.5.9
  (first Play submission is on the internal track).

## Only Den can supply

1. **Production signing key** — CI signs the release build with the
   debug key (`signingConfig = signingConfigs.getByName("debug")`
   fallback) until the upload keystore exists. The v0.5.9 AAB is
   debug-signed and verified as a build artifact, but it is **not**
   a production-signed upload: the debug key is a public, well-known
   key and must not be the Play upload key. A production upload
   keystore + Play App Signing enrollment is needed. The keystore and
   its passwords must live in Den's custody; CI gets them as secrets
   only when he says so. The wiring for that swap is done in #32
   (env/CI-secret read path with a debug fallback) — the keystore
   itself cannot be created by an agent.
2. **Sentry DSN (optional for first submission)** — the app works
   without it (crash reporting stays off). Supplying it turns on
   crash reports; the Data Safety answers change with it (see
   `docs/play-data-safety.md`).
3. **PostHog API key (optional for first submission)** — the app works
   without it (analytics stays off). Supplying it turns on the 8
   funnel events; the Data Safety answers change with it (see
   `docs/play-data-safety.md`). The key lives in Den's custody
   (Secure Vault only, never in the repo); live-key verification that
   events arrive in PostHog is also Den-owned.
4. **Content rating questionnaire + Data Safety form** — Den answers
   them in Play Console. Drafts are in `docs/play-data-safety.md`
   (no ads, no account, no data collection except optional crash
   reports once Sentry is live and optional analytics once PostHog
   is live).

Historical note: the Google Play developer account gate is **closed**
— the VIBE TECHNOLOGIES account exists and is logged in (confirmed
by Den 2026-11-14); the $25 fee is paid. It is no longer a gate.

## Agent work still needed before submission

- **Play screenshots (2–8) — none yet.** Both emulator workflows
  live in the repo and are dispatch-runnable:
  `emulator-smoke-test.yml` and `emulator-screenshots.yml`. The
  first-ever smoke-test failure (run 43491636991, 2026-11-14 — the
  runner executes each `script:` line as a separate `sh -c` call, so
  the `APK=...` variable did not survive to the install line) is
  fixed in-repo: every command in the script is self-contained on
  one line, documented in the file header. Recent runs: smoke test
  latest success 43569609879, screenshots latest success
  43574258317 (both 2026-11-14). No screenshots have been captured
  or reviewed into `docs/play-assets/screenshots/` yet — every
  screenshot must be visually reviewed before it goes there. Den's
  phone screenshots remain the best source (real camera feed).
  Workflow files are pushed via the gh CLI / PR like any other file
  (`ios-build.yml` landed via PR #28; PRs #33/#34 merged the same
  way).
- **In-app review prompt — wired in #37 (v0.5.11).** The app asks Play
  for a review at most once per app version, on the first completed
  recording of that version (`in_app_review` + `package_info_plus`,
  `ReviewPromptGate` in `lib/captions/review_prompt_gate.dart` with the
  `ReviewPrompt` facade in `lib/review_prompt.dart`; trigger is
  the successful gallery save in `_stop()`, never first open, never the
  Share tap). Sideloaded builds are a silent no-op (`isAvailable()`
  false, or the platform call throws — swallowed, nothing marked, so a
  later Play install can still prompt). Play throttles display itself,
  so the dialog only shows on a Play-installed build.
- **Analytics events — done (issue #38).** The skill's funnel events
  (`app_open`, `record_started`, `core_action_done`,
  `core_action_repeat`, `captions_done`, `share_done`, `model_ready`,
  `model_download_failed`) are implemented in
  `packages/dual_cameras/example/lib/analytics.dart`, key-gated on
  `--dart-define POSTHOG_API_KEY`. Until a key is supplied, growth is
  measured from Play Console numbers only. Known gap: background-job
  caption completion has no event yet (foreground path only) —
  follow-up issue to file.
- **Promo video (30–60 s).** Optional for the first submission;
  record it from the first real-phone test.
- Switch the release signing config from the debug key to the upload
  keystore: **wiring done in #32** — remaining step is Den supplying
  the keystore (item 1 above). Note: once the keystore secret is
  set, the tag job's `CN=Android Debug` verify assertion must become
  conditional on the signing path (see `build-apk.yml`).
- First submission on an internal/closed track, not production.

## What is NOT blocking

- The app itself is releasable as a sideload build: CI green, 113
  tests across 12 unit/widget test files — the example `flutter test`
  step reports 108 tests passed (107 passed + 1 skipped by the
  per-test count) and the plugin step 5 passed — plus 1
  `integration_test` file (not run by `flutter test`); host inference
  verified, APK + AAB hash-verified. The blockers above are account,
  identity, and store assets — not code.
- Package name is settled: `app.storycam` (renamed from the plugin
  demo's `com.romanslack.dual_cameras_example` before the first
  production upload, when there were no production users). Play
  forbids changing the applicationId after the first release, so this
  id is now permanent. Never change it.
