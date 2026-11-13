# Google Play readiness — StoryCam

Status: **not ready to submit**. The app today is a sideload-only test
build (v0.5.3, debug-signed). This page lists exactly what is missing,
who can supply it, and what this PR already prepared.

## Prepared in this PR

- Play listing text, English + Russian: `docs/play-listing.md`
  (title, short description, full description — honest, test-build
  features only).
- ASO keyword set with rationale: `docs/aso-keywords.md`.
- Privacy policy draft: `website/privacy.html` (linked from the site
  footer and `sitemap.xml`).
- Crash reporting prep: `sentry_flutter` wired in the example app, DSN
  from `--dart-define SENTRY_DSN`, fully disabled without one
  (`packages/dual_cameras/example/lib/crash_reporting.dart`). Needs only
  a Sentry project + DSN (free tier) to go live.
- GitHub issue templates + triage rules: `.github/ISSUE_TEMPLATE/`,
  `CONTRIBUTING.md`.

## Only Den can supply

1. **Google Play developer account** — $25 one-time fee, identity
   verification, and sign-in with his Google account. No agent can do
   this: it needs his account and his payment.
2. **Package-name decision** — the app is still
   `com.romanslack.dual_cameras_example` (the plugin demo's id).
   **Recommendation: rename to a StoryCam identity (`app.storycam`)
   before the first production upload.** Play forbids changing the
   applicationId after the first release, and renaming now is cheap:
   there are no production users, and test builds use the debug key so
   there is no upgrade continuity to preserve. Renaming means updating
   `android/app/build.gradle.kts` (namespace + applicationId) and the
   package-name grep in `.github/workflows/build-apk.yml`.
3. **Production signing key** — CI signs the release build with the
   debug key (`signingConfig = signingConfigs.getByName("debug")`).
   A production upload keystore + Play App Signing enrollment is needed.
   The keystore and its passwords must live in Den's custody; CI gets
   them as secrets only when he says so.
4. **Store media** — phone screenshots (2–8), a 1024×512 feature
   graphic, and a 512×512 app icon. The current launcher icon is the
   stock Flutter logo — a custom StoryCam icon is needed. Screenshots
   must come from a real phone; the icon/graphic need Den's branding
   call (or one prepared draft for him to approve).
5. **Content rating questionnaire + Data Safety form** — Den answers
   them in Play Console (no ads, no account, no data collection except
   optional crash reports once Sentry is live).
6. **The $25 fee** (part of item 1).

## Agent work still needed before submission

- `flutter build appbundle` step in CI: new Play apps must publish as
  an Android App Bundle, not an APK. (After the package-name decision.)
- Switch the release signing config from the debug key to the upload
  keystore (after item 3).
- Verify `targetSdk` meets Play's current requirement for new apps
  (Flutter 3.47's default should; re-check at build time) and that the
  privacy-policy URL resolves — the site's deployment is being audited
  separately, and Play rejects a listing whose policy link 404s.
- First submission on an internal/closed track, not production.

## What is NOT blocking

- The app itself is releasable as a test build: CI green, 90 + 5 tests,
  host inference verified, APK hash-verified. The blockers above are
  account, identity, and store assets — not code.
