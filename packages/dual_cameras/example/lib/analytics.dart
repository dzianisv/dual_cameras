import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

/// Analytics (PostHog) for StoryCam.
///
/// Mirrors [crash_reporting.dart] exactly: the API key comes from
/// `--dart-define POSTHOG_API_KEY=...` at build time and is never committed
/// to the repo. When it is empty (the default), analytics is fully
/// disabled: [init] returns immediately, PostHog is never initialized, and
/// no network calls are made — the app behaves exactly as if this file did
/// not exist, and no state file is written.
///
/// Config (posthog_flutter 5.61.0, verified against the SDK source):
/// US host `https://us.i.posthog.com` (explicit); session replay off
/// (`sessionReplay = false`); application-lifecycle autocapture off
/// (`captureApplicationLifecycleEvents = false` — it defaults to `true`
/// and would otherwise emit `Application Opened` on every foreground
/// return). There is no Dart flag for screen views: the native Android/iOS
/// plugins hard-code `captureScreenViews = false`, and `$screen` events
/// only fire via `PosthogObserver`, which this app never installs — so no
/// screen-view autocapture occurs. Desktop tracking is not enabled
/// (`enableWindowsAndLinux = false`; the app is mobile-only).
/// `$exception` autocapture does not fire either: every error-tracking
/// autocapture flag in `PostHogErrorTrackingConfig` defaults to `false`
/// (Flutter errors, dispatcher errors, isolate errors, native exceptions
/// and native crashes) — Sentry owns crashes, PostHog never sees them.
///
/// Only the 8 funnel events below are ever captured, each carrying
/// `app_version` + `install_source` and no personal data (counts, codes
/// and booleans only — no file paths, no caption text, no location).
/// All captures are fire-and-forget and never throw, so analytics can
/// never delay or break a flow.
///
/// The background caption isolate (`captionJobMain`) initializes analytics
/// separately in `runCaptionJob` — Dart statics are isolate-local, so the
/// main isolate's init does not carry over — and emits `captions_done`
/// with `job: 'background'` on job completion. The background gap is now
/// closed: foreground and background completions are both covered.
class Analytics {
  Analytics._();

  static bool _initialized = false;

  /// True only after [init] successfully initialized PostHog with a key.
  static bool get isInitialized => _initialized;

  /// The API key passed at build time, or '' when analytics is disabled.
  static String get apiKey =>
      const String.fromEnvironment('POSTHOG_API_KEY', defaultValue: '');

  static const _host = 'https://us.i.posthog.com';
  static const _stateFileName = 'analytics_state.json';

  static String _appVersion = 'unknown';
  static String _installSource = 'unknown';

  /// Test-only event sink: when set, [capture] routes events here instead
  /// of the PostHog SDK, so widget tests can assert each event fires at
  /// its hook point without a key or network. Same pattern as the
  /// injected [initializer] override.
  static void Function(String event, Map<String, Object> properties)?
      _captureSink;

  /// Test-only documents-directory override for the persisted state file.
  static Future<Directory> Function()? _documentsDirectoryOverride;

  /// Initializes PostHog when a key is present; a no-op otherwise.
  ///
  /// [apiKeyOverride], [initializer], [versionOverride] and
  /// [installSourceOverride] exist for tests: the overrides stand in for
  /// the `--dart-define` and for `PackageInfo` (which has no plugin in
  /// `flutter test`), and the initializer stands in for the real
  /// `Posthog().setup` so tests can prove the gating logic without
  /// touching the network. A failing initializer never breaks app startup:
  /// the error is logged and the app runs without analytics.
  static Future<void> init({
    String? apiKeyOverride,
    Future<void> Function(String apiKey)? initializer,
    String? versionOverride,
    String? installSourceOverride,
    void Function(String event, Map<String, Object> properties)? captureSink,
    Future<Directory> Function()? documentsDirectory,
  }) async {
    final resolved = apiKeyOverride ?? apiKey;
    if (resolved.isEmpty) return;
    try {
      await (initializer ?? _defaultInitializer)(resolved);
      _captureSink = captureSink;
      _documentsDirectoryOverride = documentsDirectory;
      _appVersion = versionOverride ?? await _resolveAppVersion();
      _installSource = installSourceOverride ?? await _resolveInstallSource();
      _initialized = true;
    } catch (e) {
      debugPrint('StoryCam: analytics failed to start: $e');
    }
  }

  static Future<void> _defaultInitializer(String apiKey) async {
    final config = PostHogConfig(apiKey)
      ..host = _host
      ..captureApplicationLifecycleEvents = false
      ..sessionReplay = false
      // The only way to opt out of the SDK's experimental Windows/Linux
      // tracking; the app is mobile-only, so this is belt-and-braces for
      // "do not enable desktop tracking".
      // ignore: experimental_member_use
      ..enableWindowsAndLinux = false;
    await Posthog().setup(config);
  }

  /// `version+buildNumber` from the app package (e.g. `0.5.10+15`).
  /// Falls back to `unknown` — never a crash — when PackageInfo fails.
  static Future<String> _resolveAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } catch (_) {
      return 'unknown';
    }
  }

  /// `play` for a Play install (`com.android.vending`), `other` for any
  /// other non-empty installer store, `unknown` when there is none (which
  /// is also the iOS answer — `installerStore` is null there, and
  /// TestFlight vs App Store is indistinguishable via this API).
  static Future<String> _resolveInstallSource() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final store = info.installerStore;
      if (store == null || store.isEmpty) return 'unknown';
      return store == 'com.android.vending' ? 'play' : 'other';
    } catch (_) {
      return 'unknown';
    }
  }

  /// Low-level capture. No-op before [init]; never throws. Every event
  /// carries `app_version` + `install_source`.
  static void capture(String event, {Map<String, Object>? properties}) {
    if (!_initialized) return;
    final merged = <String, Object>{
      'app_version': _appVersion,
      'install_source': _installSource,
      ...?properties,
    };
    try {
      final sink = _captureSink;
      if (sink != null) {
        sink(event, merged);
        return;
      }
      unawaited(Posthog()
          .capture(eventName: event, properties: merged)
          .catchError((Object _) {}));
    } catch (_) {
      // Analytics never breaks a flow.
    }
  }

  /// Best-effort flush of the queued PostHog events. No-op before [init];
  /// never throws. The background caption job awaits this before its
  /// `complete` channel call, so the event is sent before the headless
  /// engine may tear down. Without a flush the event persists in the SDK
  /// queue and retries on the next launch, so a flush failure only affects
  /// delivery timing, never the job. In tests the capture sink replaces
  /// the SDK, so there is nothing queued to flush — and no plugin to
  /// flush through — and this returns immediately.
  static Future<void> flush() async {
    if (!_initialized) return;
    if (_captureSink != null) return;
    try {
      await Posthog().flush();
    } catch (_) {
      // Best effort only — the SDK retries on the next launch.
    }
  }

  /// `app_open` — once per cold start, from `main()` after [init].
  /// `first_open` is true only on the first-ever initialized launch.
  static Future<void> appOpen() async {
    if (!_initialized) return;
    final state = await _loadState();
    final firstOpen = !state.firstOpenSeen;
    if (firstOpen) {
      await _saveState(state.copyWith(firstOpenSeen: true));
    }
    capture('app_open', properties: {'first_open': firstOpen});
  }

  /// `record_started` — after `startRecording` succeeds.
  static void recordStarted({
    required bool captionsOn,
    required String captionLanguage,
  }) {
    capture('record_started', properties: {
      'captions_on': captionsOn,
      'caption_language': _languageCode(captionLanguage),
    });
  }

  /// `core_action_done` — after a recording is saved to the gallery.
  /// Also fires `core_action_repeat` (with `recording_number`) when the
  /// persisted recordings counter reaches 2 or more: increment-then-
  /// evaluate, so the 2nd recording is the first repeat.
  static Future<void> coreActionDone({
    required bool captionsOn,
    required String captionLanguage,
  }) async {
    if (!_initialized) return;
    final state = await _loadState();
    final count = state.recordingsCompleted + 1;
    await _saveState(state.copyWith(recordingsCompleted: count));
    final properties = <String, Object>{
      'captions_on': captionsOn,
      'caption_language': _languageCode(captionLanguage),
    };
    capture('core_action_done', properties: properties);
    if (count >= 2) {
      capture('core_action_repeat',
          properties: {...properties, 'recording_number': count});
    }
  }

  /// `captions_done` — foreground `_captionVideo` success tail, and the
  /// background caption job (`runCaptionJob`) on completion. `job` is
  /// `'foreground'` by default; the background runner passes
  /// `'background'`. The background gap is now closed: the caption isolate
  /// initializes analytics in `runCaptionJob` and emits this event on
  /// success (no event on the noSpeech path, matching the foreground).
  static void captionsDone({
    required int wordCount,
    required String language,
    required String captionLanguage,
    String job = 'foreground',
  }) {
    capture('captions_done', properties: {
      'word_count': wordCount,
      'language': language,
      'caption_language': _languageCode(captionLanguage),
      'job': job,
    });
  }

  /// `share_done` — after every successful share-sheet open.
  static void shareDone({required bool captionsOn}) {
    capture('share_done', properties: {'captions_on': captionsOn});
  }

  /// `model_ready` — `_loadModel` success. `cached` comes from the
  /// progress stream: a cached model reports 0 then 1 with nothing
  /// between, so no intermediate progress value means it was cached.
  static void modelReady({required bool cached}) {
    capture('model_ready', properties: {'cached': cached});
  }

  /// `model_download_failed` — `_loadModel` failure. `reason` is a short
  /// code mapped at the hook (`stopped` / `storage` / `download`), never
  /// a raw exception message.
  static void modelDownloadFailed({required String reason}) {
    capture('model_download_failed', properties: {'reason': reason});
  }

  /// The caption-language setting as an event property: `''` (Auto) is
  /// reported as `auto`, matching the design's `auto/ru/en` values.
  static String _languageCode(String code) => code.isEmpty ? 'auto' : code;

  static Future<File> _stateFile() async {
    final dir = await (_documentsDirectoryOverride ??
        getApplicationDocumentsDirectory)();
    return File('${dir.path}/$_stateFileName');
  }

  /// The persisted state, or defaults when nothing is stored, the file
  /// is unreadable, or the content is not valid JSON. File IO is
  /// synchronous inside (same precedent as `CaptionLanguageStore`:
  /// real async dart:io never completes inside testWidgets' fake-async
  /// zone). Failures are swallowed: a missed read only means the next
  /// launch reports `first_open` again and the repeat counter restarts.
  static Future<_AnalyticsState> _loadState() async {
    try {
      final file = await _stateFile();
      if (!file.existsSync()) return const _AnalyticsState();
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map<String, dynamic>) {
        return _AnalyticsState.fromJson(decoded);
      }
      return const _AnalyticsState();
    } catch (_) {
      return const _AnalyticsState();
    }
  }

  /// Store the state. Failures are swallowed: a missed save only means
  /// the next launch re-reports `first_open` / recounts, never a crash.
  static Future<void> _saveState(_AnalyticsState state) async {
    try {
      final file = await _stateFile();
      file.writeAsStringSync(jsonEncode(state.toJson()), flush: true);
    } catch (_) {
      // Best effort only — see [_loadState].
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _initialized = false;
    _appVersion = 'unknown';
    _installSource = 'unknown';
    _captureSink = null;
    _documentsDirectoryOverride = null;
  }
}

/// Persisted analytics state: one small JSON file (`analytics_state.json`
/// via `path_provider`, same file-based precedent as
/// `CaptionLanguageStore` — no `shared_preferences` anywhere in the repo).
class _AnalyticsState {
  const _AnalyticsState({
    this.recordingsCompleted = 0,
    this.firstOpenSeen = false,
  });

  final int recordingsCompleted;
  final bool firstOpenSeen;

  factory _AnalyticsState.fromJson(Map<String, dynamic> json) =>
      _AnalyticsState(
        recordingsCompleted:
            (json['recordings_completed'] as num?)?.toInt() ?? 0,
        firstOpenSeen: json['first_open_seen'] as bool? ?? false,
      );

  Map<String, Object> toJson() => {
        'recordings_completed': recordingsCompleted,
        'first_open_seen': firstOpenSeen,
      };

  _AnalyticsState copyWith({int? recordingsCompleted, bool? firstOpenSeen}) =>
      _AnalyticsState(
        recordingsCompleted: recordingsCompleted ?? this.recordingsCompleted,
        firstOpenSeen: firstOpenSeen ?? this.firstOpenSeen,
      );
}
