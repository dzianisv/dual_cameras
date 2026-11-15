import 'dart:io';

import 'package:dual_cameras_example/analytics.dart';
import 'package:dual_cameras_example/main.dart';
import 'package:dual_cameras_platform_interface/dual_cameras_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' as wt;

void main() {
  // The no-key tests assume `flutter test` runs without
  // --dart-define POSTHOG_API_KEY (true in CI). If a key were defined,
  // the "no key" test would see a non-empty key and fail — correctly,
  // since the gating logic would then be untested.
  const testKey = 'phc_test_analytics_key';

  late Directory stateDir;
  late List<(String, Map<String, Object>)> seen;

  setUp(() {
    Analytics.resetForTest();
    stateDir = Directory.systemTemp.createTempSync('analytics_test_');
    seen = [];
  });

  tearDown(() {
    Analytics.resetForTest();
    if (stateDir.existsSync()) stateDir.deleteSync(recursive: true);
  });

  Future<void> initForTest({
    Future<void> Function(String apiKey)? initializer,
    void Function(String event, Map<String, Object> properties)? sink,
  }) async {
    await Analytics.init(
      apiKeyOverride: testKey,
      initializer: initializer ?? (_) async {},
      versionOverride: '0.5.10+15',
      installSourceOverride: 'unknown',
      captureSink:
          sink ?? ((event, properties) => seen.add((event, properties))),
      documentsDirectory: () async => stateDir,
    );
  }

  List<String> eventsNamed(String name) =>
      seen.where((e) => e.$1 == name).map((e) => e.$1).toList();

  test('no key: init is a no-op and PostHog stays uninitialized', () async {
    var initializerCalls = 0;
    await Analytics.init(initializer: (_) async {
      initializerCalls++;
    });
    expect(initializerCalls, 0);
    expect(Analytics.isInitialized, isFalse);
  });

  test('key present: init runs once with that key', () async {
    final seenKeys = <String>[];
    await Analytics.init(
      apiKeyOverride: testKey,
      initializer: (key) async {
        seenKeys.add(key);
      },
    );
    expect(seenKeys, [testKey]);
    expect(Analytics.isInitialized, isTrue);
  });

  test('failing initializer: init does not throw, analytics stays off',
      () async {
    await Analytics.init(
      apiKeyOverride: testKey,
      initializer: (_) async {
        throw Exception('PostHog unreachable');
      },
    );
    expect(Analytics.isInitialized, isFalse);
  });

  testWidgets('app boots with no key and analytics stays uninitialized',
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
    // Issue #46: _autoStart awaits the settings load, which reads the
    // documents directory via path_provider — an unmocked channel never
    // replies in widget tests, so the load would hang and auto-init
    // would never fire. A null reply means defaults (see widget_test).
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

    await Analytics.init();
    expect(Analytics.isInitialized, isFalse);

    await tester
        .pumpWidget(DemoApp(modelManager: model, backgroundCaptions: false));
    await tester.pumpAndSettle();
    // Issue #46: the camera auto-initializes on open when permissions are
    // granted — the boot state is a live camera, not 'Open camera'.
    expect(find.byTooltip('Start recording'), findsOneWidget);
    expect(Analytics.isInitialized, isFalse);
    // No-key build writes no state file.
    expect(File('${stateDir.path}/analytics_state.json').existsSync(), isFalse);
  });

  test('capture before init is a no-op and never throws', () async {
    // No init at all: nothing to observe, just no throw.
    Analytics.capture('record_started');
    await initForTest();
    expect(Analytics.isInitialized, isTrue);
    Analytics.capture('record_started',
        properties: {'captions_on': false, 'caption_language': 'auto'});
    expect(eventsNamed('record_started'), hasLength(1));
    Analytics.resetForTest();
    Analytics.capture('record_started');
    expect(eventsNamed('record_started'), hasLength(1));
  });

  test('capture with a failing transport never throws', () async {
    await Analytics.init(
      apiKeyOverride: testKey,
      initializer: (_) async {},
      captureSink: (_, __) {
        throw Exception('transport down');
      },
    );
    expect(() => Analytics.capture('record_started'), returnsNormally);
    expect(Analytics.isInitialized, isTrue);
  });

  test('capture attaches app_version and install_source', () async {
    await initForTest();
    Analytics.capture('share_done', properties: {'captions_on': true});
    expect(seen, hasLength(1));
    expect(seen.single.$1, 'share_done');
    expect(seen.single.$2['app_version'], '0.5.10+15');
    expect(seen.single.$2['install_source'], 'unknown');
    expect(seen.single.$2['captions_on'], isTrue);
  });

  test('app_open reports first_open once, then false', () async {
    await initForTest();
    await Analytics.appOpen();
    await Analytics.appOpen();
    expect(eventsNamed('app_open'), hasLength(2));
    expect(seen[0].$2['first_open'], isTrue);
    expect(seen[1].$2['first_open'], isFalse);
    // Persisted: a fresh init over the same state dir still says false.
    Analytics.resetForTest();
    await initForTest();
    await Analytics.appOpen();
    expect(eventsNamed('app_open'), hasLength(3));
    expect(seen[2].$2['first_open'], isFalse);
  });

  test('core_action_repeat fires on the 2nd recording, not the 1st', () async {
    await initForTest();
    await Analytics.coreActionDone(captionsOn: true, captionLanguage: 'ru');
    expect(eventsNamed('core_action_done'), hasLength(1));
    expect(eventsNamed('core_action_repeat'), isEmpty);
    await Analytics.coreActionDone(captionsOn: true, captionLanguage: 'ru');
    expect(eventsNamed('core_action_done'), hasLength(2));
    expect(eventsNamed('core_action_repeat'), hasLength(1));
    expect(seen.last.$2['recording_number'], 2);
    expect(seen.last.$2['caption_language'], 'ru');
    // Persisted: a fresh init over the same state dir counts 3.
    Analytics.resetForTest();
    await initForTest();
    await Analytics.coreActionDone(captionsOn: false, captionLanguage: '');
    expect(eventsNamed('core_action_repeat'), hasLength(2));
    expect(seen.last.$2['recording_number'], 3);
    expect(seen.last.$2['caption_language'], 'auto');
  });

  group('hook firing (capture sink)', () {
    late wt.FakeCamera fake;
    late wt.FakeModelManager model;
    late DualCamerasPlatform previousPlatform;

    setUp(() {
      previousPlatform = DualCamerasPlatform.instance;
      fake = wt.FakeCamera();
      model = wt.FakeModelManager();
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
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('dual_cameras_example/share'),
              (call) async => null);
    });

    tearDown(() async {
      DualCamerasPlatform.instance = previousPlatform;
      await fake.eventController.close();
    });

    Future<void> openCamera(WidgetTester tester) async {
      await tester
          .pumpWidget(DemoApp(modelManager: model, backgroundCaptions: false));
      await tester.pumpAndSettle();
      // Issue #46: the camera auto-initializes on open — no tap.
      expect(find.byTooltip('Start recording'), findsOneWidget);
      expect(find.text('Ready to tell your story'), findsOneWidget);
    }

    testWidgets('model_ready fires when the model loads (cached)',
        (tester) async {
      await initForTest();
      await openCamera(tester);
      // _prepareModel runs at startup; the fake reports no intermediate
      // progress, so the model counts as cached.
      expect(eventsNamed('model_ready'), hasLength(1));
      expect(seen.single.$2['cached'], isTrue);
      expect(seen.single.$2['app_version'], '0.5.10+15');
      expect(tester.takeException(), isNull);
    });

    testWidgets('model_download_failed fires with a reason code',
        (tester) async {
      model.fail = true;
      await initForTest();
      await openCamera(tester);
      expect(eventsNamed('model_download_failed'), hasLength(1));
      expect(seen.single.$2['reason'], 'download');
      expect(eventsNamed('model_ready'), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('record, stop, repeat and share fire at their hooks',
        (tester) async {
      await initForTest();
      await openCamera(tester);
      expect(eventsNamed('model_ready'), hasLength(1));

      await tester.tap(find.byTooltip('Start recording'));
      await tester.pumpAndSettle();
      expect(eventsNamed('record_started'), hasLength(1));
      expect(seen.last.$2['captions_on'], isFalse);
      expect(seen.last.$2['caption_language'], 'auto');

      await tester.tap(find.byTooltip('Stop recording'));
      await tester.pumpAndSettle();
      expect(eventsNamed('core_action_done'), hasLength(1));
      expect(eventsNamed('core_action_repeat'), isEmpty);

      // Share needs the saved file to exist on disk.
      File('/tmp/story.mp4').writeAsStringSync('fake-video');
      addTearDown(() {
        final file = File('/tmp/story.mp4');
        if (file.existsSync()) file.deleteSync();
      });
      // Issue #50: the Share button is gone — Share is a menu item
      // behind the last-video thumbnail now.
      await tester.tap(find.byKey(const Key('last-video-thumbnail')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('last-video-menu-share')));
      await tester.pumpAndSettle();
      expect(eventsNamed('share_done'), hasLength(1));

      // Second recording: the repeat event fires with number 2.
      await tester.tap(find.byTooltip('Start recording'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Stop recording'));
      await tester.pumpAndSettle();
      expect(eventsNamed('record_started'), hasLength(2));
      expect(eventsNamed('core_action_done'), hasLength(2));
      expect(eventsNamed('core_action_repeat'), hasLength(1));
      expect(seen.last.$2['recording_number'], 2);
      expect(tester.takeException(), isNull);
    });
  });
}
