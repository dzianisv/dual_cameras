import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Crash reporting (Sentry) for StoryCam.
///
/// The DSN comes from `--dart-define SENTRY_DSN=...` at build time and is
/// never committed to the repo. When it is empty (the default), crash
/// reporting is fully disabled: [init] returns immediately, Sentry is never
/// initialized, and no network calls are made — the app behaves exactly as
/// if this file did not exist.
///
/// Release tagging is left to the native SDKs: they fill the release from
/// the app's versionName/versionCode (pubspec `0.5.4+9`), so the Dart code
/// never hardcodes a version string that can drift from the pubspec.
///
/// Only the main isolate is covered. The background caption isolate
/// (`captionJobMain`) does not initialize Sentry.
class CrashReporting {
  CrashReporting._();

  static bool _initialized = false;

  /// True only after [init] successfully initialized Sentry with a DSN.
  static bool get isInitialized => _initialized;

  /// The DSN passed at build time, or '' when crash reporting is disabled.
  static String get dsn =>
      const String.fromEnvironment('SENTRY_DSN', defaultValue: '');

  /// Initializes Sentry when a DSN is present; a no-op otherwise.
  ///
  /// [dsnOverride] and [initializer] exist for tests: the override stands
  /// in for the `--dart-define`, and the initializer stands in for the
  /// real `SentryFlutter.init` so tests can prove the gating logic without
  /// touching the network. A failing initializer never breaks app startup:
  /// the error is logged and the app runs without crash reporting.
  static Future<void> init({
    String? dsnOverride,
    Future<void> Function(String dsn)? initializer,
  }) async {
    final resolved = dsnOverride ?? dsn;
    if (resolved.isEmpty) return;
    try {
      await (initializer ?? _defaultInitializer)(resolved);
      _initialized = true;
    } catch (e) {
      debugPrint('StoryCam: crash reporting failed to start: $e');
    }
  }

  static Future<void> _defaultInitializer(String dsn) async {
    await SentryFlutter.init((options) {
      options.dsn = dsn;
      // Crash reporting only: no performance traces, no PII.
      options.tracesSampleRate = 0;
      options.sendDefaultPii = false;
    });
  }

  @visibleForTesting
  static void resetForTest() {
    _initialized = false;
  }
}
