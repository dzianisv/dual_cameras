# StoryCam — Google Play Data Safety answers (DRAFT)

Drafted 2026-11-14 from the v0.5.4 source (`app.storycam`, versionCode 9).
Every answer below is grounded in code that was read, not assumed.
**Do not submit this as-is** — Den answers the form in Play Console;
this draft is what he types, and it must be re-checked against the exact
build that ships (if a Sentry DSN is added, the crash-report answers
change — see below; if a PostHog API key is added, the analytics
answers change — see below).

## Sources in code

- Permissions: `packages/dual_cameras/example/android/app/src/main/AndroidManifest.xml`
- Network use: `lib/captions/model_manager.dart` (model download only),
  `lib/crash_reporting.dart` (Sentry, DSN-gated),
  `lib/analytics.dart` (PostHog, API-key-gated)
- No ads SDK anywhere in `pubspec.yaml`. No account system anywhere in
  the app.

## The form, question by question

### Does your app collect or share any user data?
**No** — for the build as it ships today (no Sentry DSN, no PostHog key).

The app has no account, no ads, and no tracking SDK enabled.
Videos and photos stay in the device gallery. Captioning runs
entirely on-device. The only network traffic is the one-time caption
model download from Hugging Face (see below); no personal data,
account information, or video/audio content is sent anywhere.

### If a Sentry DSN is added for the Play build, the answer becomes YES
Crash reporting is wired but **fully disabled without a DSN**
(`CrashReporting.init` returns immediately, no network calls). If the
Play build is built with `--dart-define SENTRY_DSN=...`, then:

- **Data collected: crash logs.** What: stack trace, app version,
  Android version, device model. Purpose: crash analytics / fixing
  bugs. `sendDefaultPii = false`, performance traces off
  (`tracesSampleRate = 0`). Only the main isolate; the background
  caption isolate does not initialize Sentry.
- **Shared with:** Sentry (the crash-reporting processor) only.
- **Not linked to user identity.** No user IDs, no account, no
  advertising ID. Crash reports are not used for ads or personalization.
- **Data deletion:** not applicable — no user data is held; Sentry
  retention follows Sentry's own policy. State this in the form's
  data-deletion question ("no user data collected, nothing to delete")
  unless the DSN build is live, in which case Sentry is the deletion
  route.
- **The privacy policy must match:** `website/privacy.html` already
  describes both states (sideload builds: no crash reporting; DSN builds:
  what a crash sends). Keep them in sync when the DSN decision lands.

### If a PostHog API key is added for the Play build, the answer becomes YES
Analytics is wired but **fully disabled without a key**
(`Analytics.init` returns immediately, no network calls). If the
Play build is built with `--dart-define POSTHOG_API_KEY=...`, then:

- **Data collected: app activity / app interactions.** What: anonymous
  funnel events — app opens, recordings started/finished, shares,
  captions finished, caption-model download state — plus app version
  and install source (Play vs sideload vs unknown). Purpose: analytics /
  measuring the funnel. No personal data, no file paths or file names,
  no caption text or words (only a word count + language code), no
  location, no video/audio content. Session replay is off, lifecycle
  and screen-view autocapture are off, `$exception` autocapture is off
  (Sentry owns crashes). Only the main isolate; the background caption
  isolate does not initialize analytics.
- **Shared with:** PostHog (US host `https://us.i.posthog.com`) only.
- **Not linked to user identity.** No user IDs, no account, no
  advertising ID, no device ID — the SDK's anonymous generated ID.
  Events are not used for ads or personalization.
- **Data deletion:** PostHog retention follows PostHog's own policy;
  no user data is held in the app. State this in the form's
  data-deletion question unless the keyed build is live, in which case
  PostHog is the deletion route.
- **The privacy policy must match:** `website/privacy.html` already
  describes both states (sideload builds: no analytics; keyed builds:
  what an event sends). Keep them in sync when the key decision lands.

### Data types (all "not collected" unless the DSN or keyed build ships)
- Location: no. Contacts: no. Photos and videos: recorded and saved
  to the gallery only — **not collected, not shared, not uploaded**.
- Audio: recorded to the video file only — not uploaded. Voice
  transcription happens on-device.
- Personal info (name, email, address, IDs): no. Financial info: no.
- Health, messages, files and docs: no. Calendar: no.
- App activity / app interactions: no analytics in the no-key build;
  in a keyed build, the anonymous funnel events in the PostHog section
  above. Device IDs: no (Sentry sends device model, not an ID, and
  only in a DSN build; PostHog uses its anonymous generated ID, and
  only in a keyed build).

### Is data encrypted in transit?
**Yes.** The only network traffic is HTTPS downloads from
Hugging Face (`https://huggingface.co/...`) and, in a keyed build,
HTTPS event delivery to PostHog (`https://us.i.posthog.com`). There is
no other network use. (A download still exposes the device IP address
to Hugging Face's servers, as with any file download — the privacy
policy says so.)

### Permissions and why the app needs them (for the store listing)
- Camera — record video. Microphone — record audio with the video.
- Notifications — show model-download and caption progress with a
  Stop button (denying them only moves progress into the app).
- Photos / media (gallery) — save recorded videos. Legacy storage
  permissions apply only on Android 9 and below.
- Internet — download the caption models once, on first use.
- Vibrate — haptic feedback on capture (from the notifications
  plugin's defaults).

### Children
The app collects no data from anyone, including children. No ads,
no in-app purchases, no account, no chat, no user-generated content
shared with anyone.

## Content rating questionnaire (DRAFT — Den answers in Console)

- Violence: none. Sexual content: none. Profanity / crude humor: none.
- Controlled substances, gambling: none. In-app purchases: none.
- User-generated content shared with other users: **none** — videos
  stay on the device; sharing happens only through the Android share
  sheet, initiated by the user, to apps outside StoryCam.
- User interaction / chat: none. Location sharing: none.
- Ads: none.
- Expected rating: **Everyone**. (The questionnaire decides; if it
  returns Everyone 10+ for any reason, take its answer, not this draft's.)

## What must be re-checked at submission time

1. The shipped build's DSN state (off = "no data collected"; on =
   crash-log answers above) and its PostHog key state (off = "no data
   collected"; on = analytics answers above).
2. The privacy-policy URL resolves (it is live at
   https://dzianisv.github.io/dual_cameras/privacy.html) and its
   version line matches the shipped version.
3. The listing, the privacy policy, and this draft all say the same
   thing about data. Any disagreement is a submission defect, not a
   wording preference.
