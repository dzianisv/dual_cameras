import 'package:dual_cameras_example/crash_reporting.dart';
import 'package:dual_cameras_example/main.dart';
import 'package:dual_cameras_platform_interface/dual_cameras_platform_interface.dart';
import 'package:flutter/material.dart';
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
            (call) async =>
                call.method == 'requestPermissions' ? {0: 1, 1: 1} : null);
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
    expect(find.byTooltip('Open camera'), findsOneWidget);
    expect(CrashReporting.isInitialized, isFalse);
  });
}
