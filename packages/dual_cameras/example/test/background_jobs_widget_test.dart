import 'dart:async';

import 'package:dual_cameras_example/captions/caption_jobs.dart';
import 'package:dual_cameras_example/main.dart';
import 'package:dual_cameras_platform_interface/dual_cameras_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show FakeCamera, FakeModelManager;

class FakeJobs extends CaptionJobs {
  List<CaptionJob> jobs = [];
  bool notifications = true;
  bool failOpen = false;
  bool failList = false;
  final List<String> enqueued = [],
      enqueuedLanguages = [],
      stopped = [],
      opened = [],
      shared = [],
      retried = [];
  Completer<void>? cancelGate;
  @override
  Future<List<CaptionJob>> list() async {
    if (failList) throw StateError('list failed');
    return List.of(jobs);
  }

  @override
  Future<bool> notificationsEnabled() async => notifications;
  @override
  Future<String> enqueue(String mp4, {String language = ''}) async {
    enqueued.add(mp4);
    enqueuedLanguages.add(language);
    return 'new-job';
  }

  @override
  Future<void> cancel(String id) async {
    stopped.add(id);
    await cancelGate?.future;
  }

  @override
  Future<void> open(String id) async {
    if (failOpen) throw StateError('open failed');
    opened.add(id);
  }

  @override
  Future<void> share(String id) async {
    shared.add(id);
  }

  @override
  Future<String?> retry(String id) async {
    retried.add(id);
    return 'retry-job';
  }
}

void main() {
  late FakeCamera camera;
  late FakeJobs jobs;
  late FakeModelManager model;
  late DualCamerasPlatform previous;
  final saved = <String>[];

  setUp(() {
    previous = DualCamerasPlatform.instance;
    camera = FakeCamera();
    DualCamerasPlatform.instance = camera;
    jobs = FakeJobs();
    model = FakeModelManager();
    saved.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('flutter.baseflow.com/permissions/methods'),
            (call) async => call.method == 'requestPermissions'
                ? {for (final value in call.arguments as List) value: 1}
                : null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('gal'), (call) async {
      saved.add(call.method);
      return null;
    });
  });
  tearDown(() async {
    DualCamerasPlatform.instance = previous;
    await camera.eventController.close();
  });

  Future<void> launch(WidgetTester tester) async {
    await tester.pumpWidget(DemoApp(
        modelManager: model, captionJobs: jobs, backgroundCaptions: true));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
    });
  }

  Future<void> sheet(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const Key('menu-captions')));
    await tester.tap(find.byKey(const Key('menu-captions')));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'Android defers model work to job and shows restored progress + Stop',
      (tester) async {
    jobs.jobs = [
      const CaptionJob(
          id: 'one',
          state: 'running',
          stage: 'Transcribing on device',
          progress: 48)
    ];
    await launch(tester);
    expect(model.calls, 0);
    // The top banner is gone (v0.5.2): job progress lives in the Captions
    // sheet and the notification shade, not on the camera screen.
    await sheet(tester);
    expect(find.text('Transcribing on device · 48%'), findsOneWidget);
    expect(
        tester
            .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator))
            .value,
        .48);
    jobs.cancelGate = Completer<void>();
    await tester.tap(find.text('Stop'));
    await tester.pump();
    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(jobs.stopped, ['one']);
    jobs.jobs = [
      const CaptionJob(
          id: 'one', state: 'cancelling', stage: 'Stopping', progress: 48)
    ];
    jobs.cancelGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Stopping captions…'), findsOneWidget);
    expect(find.text('Stop'), findsNothing);
  });

  testWidgets(
      'leaving screen does not cancel native jobs; reopening restores Open/Share',
      (tester) async {
    jobs.jobs = [
      const CaptionJob(
          id: 'one', state: 'running', stage: 'Adding captions', progress: 80)
    ];
    await launch(tester);
    await tester.pumpWidget(const SizedBox());
    expect(jobs.stopped, isEmpty);
    jobs.jobs = [
      const CaptionJob(
          id: 'one',
          state: 'succeeded',
          stage: 'Captions ready',
          progress: 100,
          output: '/private/result.mp4')
    ];
    await launch(tester);
    await sheet(tester);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    expect(jobs.opened, ['one']);
    expect(jobs.shared, ['one']);
  });

  testWidgets('denied notifications keep progress and Stop available in app',
      (tester) async {
    // The sheet is 85% of the viewport, and on the default 800x600 test
    // surface the job card's Stop sits 1 px below the fold (y=601) —
    // every scroll-based attempt to reach it failed: scrollUntilVisible
    // with the default finder throws (several Scrollables), with
    // find.byType(Scrollable).last and with an ancestor-scoped
    // Scrollable it silently scrolled nothing (iterations 4 and 6), and
    // ensureVisible cannot find a lazily-built ListView child at all
    // (iteration 5). Give this test a phone-tall surface instead
    // (a real phone is ~844 logical px tall; the 600 px default is the
    // artificial part), so the card is visible and the Stop taps
    // directly. The test proves the Stop action, not sheet scrolling.
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    jobs.notifications = false;
    jobs.jobs = [
      const CaptionJob(
          id: 'one', state: 'running', stage: 'Downloading model', progress: 10)
    ];
    await launch(tester);
    // v0.5.2: the top banner is gone — the "track progress here" text
    // lives in the Captions sheet's job card, not on the camera screen.
    expect(find.textContaining('Track progress and Stop here'), findsNothing);
    await sheet(tester);
    expect(find.text('Enable notifications in settings'), findsOneWidget);
    expect(find.textContaining('Jobs still run'), findsOneWidget);
    // Tap the Stop in the sheet's job card (not the one on the main
    // screen behind the sheet): scope to the Card showing this job's
    // label.
    final sheetStop = find.descendant(
      of: find.ancestor(
        of: find.textContaining('Downloading model'),
        matching: find.byType(Card),
      ),
      matching: find.text('Stop'),
    );
    await tester.tap(sheetStop);
    await tester.pumpAndSettle();
    expect(jobs.stopped, ['one']);
  });

  testWidgets('failed jobs expose useful error and explicit Retry',
      (tester) async {
    jobs.jobs = [
      const CaptionJob(
          id: 'one',
          state: 'failed',
          stage: 'Failed',
          progress: 5,
          error:
              'Speech model download interrupted. Check your connection and retry.')
    ];
    await launch(tester);
    await sheet(tester);
    expect(find.textContaining('original kept'), findsWidgets);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(jobs.retried, ['one']);
  });

  testWidgets(
      'successful polling preserves action errors until an action succeeds',
      (tester) async {
    jobs.jobs = [
      const CaptionJob(
          id: 'one',
          state: 'succeeded',
          stage: 'Captions ready',
          progress: 100,
          output: '/result.mp4')
    ];
    jobs.failOpen = true;
    await launch(tester);
    await sheet(tester);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close Camera settings'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    await sheet(tester);
    expect(find.textContaining('Could not complete that action'), findsWidgets);
    jobs.failOpen = false;
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not complete that action'), findsNothing);
  });

  testWidgets('list and notification permission failures remain handled',
      (tester) async {
    jobs.failList = true;
    await launch(tester);
    await sheet(tester);
    expect(find.textContaining('Could not load caption jobs'), findsWidgets);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('flutter.baseflow.com/permissions/methods'),
            (call) async {
      throw PlatformException(code: 'permission_request_failed');
    });
    await tester.tap(find.widgetWithText(SwitchListTile, 'Auto-captions'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
        find.textContaining('Could not request notifications'), findsWidgets);
  });

  testWidgets(
      'recordings are saved then handed to native queue without UI inference',
      (tester) async {
    await launch(tester);
    await sheet(tester);
    await tester.tap(find.widgetWithText(SwitchListTile, 'Auto-captions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close Camera settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Open camera'));
    await tester.tap(find.byTooltip('Open camera'));
    await tester.pumpAndSettle();
    for (var n = 0; n < 2; n++) {
      await tester.tap(find.byTooltip('Start recording'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Stop recording'));
      await tester.pumpAndSettle();
    }
    expect(saved.where((method) => method == 'putVideo').length, 2);
    expect(jobs.enqueued, ['/tmp/story.mp4', '/tmp/story.mp4']);
    // Auto by default: the enqueue call carries '' as the language.
    expect(jobs.enqueuedLanguages, ['', '']);
    expect(model.calls, 0);
    expect(camera.starts, 2);
  });
}
