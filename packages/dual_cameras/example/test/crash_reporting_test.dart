import 'package:dual_cameras_example/crash_reporting.dart';
import 'package:dual_cameras_example/main.dart';
import 'package:dual_cameras_platform_interface/dual_cameras_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' as wt;

void main() {
  // The no-DSN tests assume `flutter test` runs without
  // --dart-define SENTRY_DSN (true in CI). If a DSN were defined, the
  // "no DSN" test would see a non-empty DSN and fail — correctly, since
  // the gating logic would then be untested.
  const testDsn = 'https://public@example.ingest.sentry.io/123';

  setUp(() {
    CrashReporting.resetForTest();
  });

  test('no DSN: init is a no-op and Sentry stays uninitialized', () async {
    var initializerCalls = 0;
    await CrashReporting.init(initializer: (_) async {
      initializerCalls++;
    });
    expect(initializerCalls, 0);
    expect(CrashReporting.isInitialized, isFalse);
  });

  test('DSN present: init runs once with that DSN', () async {
    final seen = <String>[];
    await CrashReporting.init(
      dsnOverride: testDsn,
      initializer: (dsn) async {
        seen.add(dsn);
      },
    );
    expect(seen, [testDsn]);
    expect(CrashReporting.isInitialized, isTrue);
  });

  test('failing initializer: init does not throw, Sentry stays off',
      () async {
    await CrashReporting.init(
      dsnOverride: testDsn,
      initializer: (_) async {
        throw Exception('Sentry unreachable');
      },
    );
    expect(CrashReporting.isInitialized, isFalse);
  });

  testWidgets('app boots with no DSN and Sentry stays uninitialized',
      (tester) async {
    // Same harness as widget_test.dart: a fake camera platform plus the
    // permission/gallery channel mocks DemoScreen needs to mount.
    final previousPlatform = DualCamerasPlatform.instance;
    final fake = wt.FakeCamera();
    final model = wt.FakeModelManager();
    DualCamerasPlatform.instance = fake;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('flutter.baseflow.com/permissions/methods'),
            (call) async {
      // Issue #46: _start checks status before requesting — see
      // widget_test.dart setUp for why this must answer
      // checkPermissionStatus. Keys are Permission values (camera=1,
      // microphone=7); anything else reads as denied.
      if (call.method == 'requestPermissions') return {1: 1, 7: 1};
      if (call.method == 'checkPermissionStatus') {
        return {1: 1, 7: 1}[call.arguments as int] ?? 0;
      }
      return null;
    });
    // Issue #46: _autoStart awaits the settings load (path_provider) —
    // an unmocked channel never replies in widget tests, so the load
    // would hang and auto-init would never fire (see widget_test).
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('gal'), (call) async {
      return null;
    });
    addTearDown(() async {
      DualCamerasPlatform.instance = previousPlatform;
      await fake.eventController.close();
    });

    await CrashReporting.init();
    expect(CrashReporting.isInitialized, isFalse);

    await tester.pumpWidget(
        DemoApp(modelManager: model, backgroundCaptions: false));
    await tester.pumpAndSettle();
    // Issue #46: the camera auto-initializes on open when permissions are
    // granted — the boot state is a live camera, not 'Open camera'.
    expect(find.byTooltip('Start recording'), findsOneWidget);
    expect(CrashReporting.isInitialized, isFalse);
  });
}
