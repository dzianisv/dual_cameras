import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dual_cameras_example/main.dart';
import 'package:dual_cameras_example/captions/caption_job_notifier.dart';
import 'package:dual_cameras_example/captions/caption_language_store.dart';
import 'package:dual_cameras_example/captions/model_download_notifier.dart';
import 'package:dual_cameras_example/captions/model_manager.dart';
import 'package:dual_cameras_example/captions/caption_models.dart';
import 'package:dual_cameras_example/map/map_location.dart';
import 'package:dual_cameras_example/ui/filter_slider.dart';
import 'package:dual_cameras_example/ui/map_circle.dart';
import 'package:dual_cameras_platform_interface/dual_cameras_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class FakeModelManager extends ModelManager {
  int calls = 0;
  bool fail = false;
  bool cancelCalled = false;
  Completer<WhisperModelFiles>? gate;
  void Function(double)? progress;
  static const files = WhisperModelFiles(
      encoder: 'encoder',
      decoder: 'decoder',
      tokens: 'tokens',
      vad: 'vad');
  @override
  Future<WhisperModelFiles> ensureModel(
      {required void Function(double) onProgress}) async {
    calls++;
    progress = onProgress;
    if (fail) throw Exception('Offline');
    if (gate != null) return gate!.future;
    onProgress(1);
    return files;
  }

  @override
  void cancel() {
    // Mirrors the real manager: abort the in-flight download. The gate is
    // the fake's in-flight attempt — fail it with the same stop exception
    // the real cancel produces, so the screen takes the stopped path.
    cancelCalled = true;
    if (gate != null && !gate!.isCompleted) {
      gate!.completeError(
          const ModelDownloadException('Caption job stopped'));
    }
    super.cancel();
  }
}

class FakeModelDownloadNotifier implements ModelDownloadNotifier {
  final List<double> progresses = [];
  int readyCalls = 0;
  int stoppedCalls = 0;
  final List<String> failed = [];
  void Function()? _onStop;

  @override
  set onStop(void Function()? value) => _onStop = value;

  /// Simulate the user tapping Stop on the progress notification.
  void simulateStop() => _onStop?.call();

  @override
  Future<void> showProgress(double progress) async {
    progresses.add(progress);
  }

  @override
  Future<void> showReady() async {
    readyCalls++;
  }

  @override
  Future<void> showStopped() async {
    stoppedCalls++;
  }

  @override
  Future<void> showFailed(String error) async {
    failed.add(error);
  }
}

class FakeCaptionJobNotifier implements CaptionJobNotifier {
  final List<(CaptionStage, double)> progresses = [];
  final List<(int, String)> done = [];
  int noSpeechCalls = 0;
  final List<String> failed = [];
  int clearCalls = 0;
  void Function()? _onStop;

  @override
  set onStop(void Function()? value) => _onStop = value;

  /// Simulate the user tapping Stop on the progress notification.
  void simulateStop() => _onStop?.call();

  @override
  Future<void> showProgress(CaptionStage stage, double stageProgress) async {
    progresses.add((stage, stageProgress));
  }

  @override
  Future<void> showDone(int words, String language) async {
    done.add((words, language));
  }

  @override
  Future<void> showNoSpeech() async {
    noSpeechCalls++;
  }

  @override
  Future<void> showFailed(String error) async {
    failed.add(error);
  }

  @override
  Future<void> clear() async {
    clearCalls++;
  }
}

class FakeCamera extends DualCamerasPlatform with MockPlatformInterfaceMixin {
  final eventController = StreamController<DualCameraEvent>.broadcast();
  bool supported = true;
  int starts = 0, stops = 0, photos = 0, disposals = 0;
  VideoFilter filter = VideoFilter.none;
  DualResolution? resolution;
  Completer<void>? startGate;
  Completer<void>? exposureGate;
  final List<double> exposures = [];
  final List<String> stopFiles = [];
  Completer<InitResult>? initGate;
  Completer<CameraCapabilities>? probeGate;

  @override
  Stream<DualCameraEvent> get events => eventController.stream;
  @override
  Future<CameraCapabilities> probeSupport() async => probeGate == null
      ? CameraCapabilities(isSupported: supported)
      : probeGate!.future;
  @override
  Future<InitResult> initialize(RecordingConfig config) async {
    resolution = config.resolution;
    return initGate == null
        ? InitResult(
            textureId: 42,
            capabilities: CameraCapabilities(isSupported: true))
        : initGate!.future;
  }
  @override
  Future<ExposureCompensationRange> getExposureCompensationRange() async =>
      ExposureCompensationRange(minEv: -2, maxEv: 2, stepEv: .5);
  @override
  Future<void> startRecording() async {
    starts++;
    await startGate?.future;
  }

  @override
  Future<String> stopRecording() async {
    stops++;
    return stopFiles.isEmpty ? '/tmp/story.mp4' : stopFiles.removeAt(0);
  }

  @override
  Future<String> takePhoto() async {
    photos++;
    return '/tmp/story.jpg';
  }

  @override
  Future<void> setFilter(VideoFilter value) async {
    filter = value;
  }

  // Issue #20: lenses + 4K probe. Defaults mirror a phone with an
  // ultrawide rear (0.5/1) and a front zoom preset (1/1.5); 4K off.
  List<LensOption> lensesFront = [
    LensOption(ratio: 1, label: '1'),
    LensOption(ratio: 1.5, label: '1.5'),
  ];
  List<LensOption> lensesRear = [
    LensOption(ratio: 0.5, label: '0.5'),
    LensOption(ratio: 1, label: '1'),
  ];
  final List<(bool, double)> lensSelections = [];
  bool supports4kValue = false;

  @override
  Future<List<LensOption>> getLenses(bool front) async =>
      front ? lensesFront : lensesRear;

  @override
  Future<void> setLens(bool front, double ratio) async {
    lensSelections.add((front, ratio));
  }

  @override
  Future<bool> supports4k() async => supports4kValue;

  @override
  Future<void> setExposureCompensation(double value) async {
    exposures.add(value);
    await exposureGate?.future;
  }

  @override
  Future<void> swapPrimary() async {}
  @override
  Future<void> setLayout(LayoutConfig config) async {}
  @override
  Future<void> dispose() async {
    disposals++;
  }
}

/// Fake location service for widget tests: feeds fixed streams, no plugin.
/// `positions`/`headings` are the raw streams (usually a StreamController
/// the test drives); a single fixed fix can be passed instead via [position]
/// / [heading].
class FakeMapLocationService extends MapLocationService {
  FakeMapLocationService({
    bool permissionGranted = true,
    LatLng? position,
    double? heading,
    Stream<LatLng>? positions,
    Stream<double>? headings,
  }) : super(
          requestLocationPermission: () async => permissionGranted,
          checkLocationPermission: () async => permissionGranted,
          positionStream: () => positions ??
              (position == null
                  ? const Stream<LatLng>.empty()
                  : Stream<LatLng>.value(position)),
          headingStream: () => headings ??
              (heading == null
                  ? const Stream<double>.empty()
                  : Stream<double>.value(heading)),
        );
}

/// Whether a bottom-menu item reads as ON (bold white, issue #20 v4).
bool menuItemIsBold(WidgetTester tester, String key) {
  final text = tester.widget<Text>(find.descendant(
      of: find.byKey(Key(key)), matching: find.byType(Text)));
  return text.style?.fontWeight == FontWeight.w800;
}

void main() {
  late FakeCamera fake;
  late FakeModelManager model;
  late DualCamerasPlatform previousPlatform;
  final permissions = <int, int>{0: 1, 1: 1};
  final galleryCalls = <String>[];

  setUp(() {
    previousPlatform = DualCamerasPlatform.instance;
    fake = FakeCamera();
    model = FakeModelManager();
    DualCamerasPlatform.instance = fake;
    permissions.updateAll((key, value) => 1);
    galleryCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('flutter.baseflow.com/permissions/methods'),
            (call) async =>
                call.method == 'requestPermissions' ? permissions : null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('gal'), (call) async {
      galleryCalls.add(call.method);
      return null;
    });
  });
  tearDown(() async {
    DualCamerasPlatform.instance = previousPlatform;
    await fake.eventController.close();
  });

  Future<void> openCamera(WidgetTester tester,
      {CaptionJobNotifier? captions,
      MapLocationService? mapLocationService}) async {
    await tester.pumpWidget(DemoApp(
        modelManager: model,
        backgroundCaptions: false,
        captionJobNotifier: captions,
        mapLocationService: mapLocationService));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open camera'));
    await tester.pumpAndSettle();
    expect(find.text('Ready to tell your story'), findsOneWidget);
  }

  testWidgets('model download reports to notification, never a top banner',
      (tester) async {
    final downloads = FakeModelDownloadNotifier();
    model.fail = true;
    await tester.pumpWidget(DemoApp(
        modelManager: model,
        backgroundCaptions: false,
        modelDownloadNotifier: downloads));
    await tester.pumpAndSettle();
    // No model state anywhere on the camera screen, even while the
    // download fails (v0.5.2: the banner is gone for good).
    expect(find.textContaining('Caption model download failed'), findsNothing);
    expect(find.textContaining('Preparing captions'), findsNothing);
    expect(find.text('Captions ready · on device'), findsNothing);
    expect(downloads.failed, isNotEmpty);
    // The failure + Retry live in the Captions sheet.
    await tester.ensureVisible(find.byKey(const Key('menu-captions')));
    await tester.tap(find.byKey(const Key('menu-captions')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Caption model download failed'),
        findsOneWidget);
    model.fail = false;
    model.gate = Completer<WhisperModelFiles>();
    await tester.tap(find.text('Retry'));
    await tester.pump();
    model.progress!(.42);
    await tester.pump();
    expect(downloads.progresses, contains(.42));
    await tester.tap(find.byTooltip('Close Camera settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open camera'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Start recording'));
    await tester.pump();
    expect(fake.starts, 1);
    expect(model.calls, 2);
    model.gate!.complete(FakeModelManager.files);
    await tester.pumpAndSettle();
    expect(downloads.readyCalls, 1);
    expect(find.text('Captions ready · on device'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'captions await startup download once and keep saved original on failure',
      (tester) async {
    model.gate = Completer<WhisperModelFiles>();
    final captions = FakeCaptionJobNotifier();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dual_cameras_example/captions'),
            (call) async => '/tmp/audio.wav');
    await tester.pumpWidget(DemoApp(
        modelManager: model,
        backgroundCaptions: false,
        captionJobNotifier: captions));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('menu-captions')));
    await tester.tap(find.byKey(const Key('menu-captions')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    // The Captions section is last in the sheet's lazily-built
    // ListView: scroll the tile into view before tapping it (issue #20
    // fix round 2 / T1). Bounded pumps, not pumpAndSettle: the model
    // gate is still pending here, so the indicator is indeterminate
    // and pumpAndSettle can never settle.
    await tester.scrollUntilVisible(
        find.widgetWithText(SwitchListTile, 'Auto-captions'), 100,
        scrollable: find
            .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable))
            .last);
    await tester.pump();
    await tester.tap(find.widgetWithText(SwitchListTile, 'Auto-captions'));
    await tester.pump();
    await tester.tap(find.byTooltip('Close Camera settings'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.ensureVisible(find.byTooltip('Open camera'));
    await tester.tap(find.byTooltip('Open camera'));
    await tester.pump();
    await tester.tap(find.byTooltip('Start recording'));
    await tester.pump();
    await tester.tap(find.byTooltip('Stop recording'));
    await tester.pump();
    expect(galleryCalls.where((call) => call == 'putVideo').length, 1);
    expect(model.calls, 1);
    await tester.tap(find.byTooltip('Start recording'));
    await tester.pump();
    expect(fake.starts, 2); // Model preparation must not block the next clip.
    model.gate!.completeError(Exception('Download interrupted'));
    await tester.pumpAndSettle();
    // The failure went to the caption notification (v0.5.3), not to
    // in-app text: only clip 1's job had finished recording and failed.
    expect(captions.failed, hasLength(1));
    expect(find.textContaining('plain video kept'), findsNothing);
    // The model failure + Retry live in the Captions sheet now (v0.5.2),
    // not as a banner on the camera screen. Captions were enabled earlier
    // in this test, so the menu item reads 'Captions' as on (bold).
    await tester.ensureVisible(find.byKey(const Key('menu-captions')));
    await tester.tap(find.byKey(const Key('menu-captions')));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    expect(galleryCalls.where((call) => call == 'putVideo').length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stopping the model download cancels it and offers retry',
      (tester) async {
    final downloads = FakeModelDownloadNotifier();
    model.gate = Completer<WhisperModelFiles>();
    await tester.pumpWidget(DemoApp(
        modelManager: model,
        backgroundCaptions: false,
        modelDownloadNotifier: downloads));
    await tester.pump();
    model.progress!(.42);
    await tester.pump();
    expect(downloads.progresses, contains(.42));
    // No download state on the camera screen (v0.5.2).
    expect(find.textContaining('Downloading caption model'), findsNothing);
    // Stop from the notification (v0.5.3): cancels the real download.
    downloads.simulateStop();
    await tester.pumpAndSettle();
    expect(model.cancelCalled, isTrue);
    expect(downloads.stoppedCalls, 1);
    expect(downloads.failed, isEmpty);
    // The stop is offered retry in the Captions sheet, not a failure.
    await tester.ensureVisible(find.byKey(const Key('menu-captions')));
    await tester.tap(find.byKey(const Key('menu-captions')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Download stopped'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    // Retry starts a fresh download: the stop must not poison it.
    model.gate = Completer<WhisperModelFiles>();
    await tester.tap(find.text('Retry'));
    await tester.pump();
    model.progress!(.9);
    await tester.pump();
    expect(downloads.progresses, contains(.9));
    model.gate!.complete(FakeModelManager.files);
    await tester.pumpAndSettle();
    expect(downloads.readyCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stopping a caption job aborts it and keeps the original',
      (tester) async {
    final captions = FakeCaptionJobNotifier();
    final extracted = Completer<String>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dual_cameras_example/captions'),
            (call) async {
      if (call.method == 'extractAudio') return extracted.future;
      throw StateError('unexpected ${call.method}');
    });
    await openCamera(tester, captions: captions);
    await tester.ensureVisible(find.byKey(const Key('menu-captions')));
    await tester.tap(find.byKey(const Key('menu-captions')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, 'Auto-captions'));
    await tester.tap(find.byTooltip('Close Camera settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Start recording'));
    await tester.tap(find.byTooltip('Start recording'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Stop recording'));
    await tester.pumpAndSettle();
    // The job is in its extracting stage: progress went to the
    // notification, nothing in-app — not on the camera screen, not in the
    // Captions sheet.
    expect(captions.progresses.map((p) => p.$1),
        contains(CaptionStage.extracting));
    expect(find.textContaining('Extracting audio'), findsNothing);
    expect(find.textContaining('Preparing captions'), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('menu-captions')));
    await tester.tap(find.byKey(const Key('menu-captions')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Extracting audio'), findsNothing);
    expect(find.textContaining('Preparing captions'), findsNothing);
    await tester.tap(find.byTooltip('Close Camera settings'));
    await tester.pumpAndSettle();
    // Stop from the notification (v0.5.3): the job aborts at the next
    // stage boundary.
    final clearsBeforeStop = captions.clearCalls;
    captions.simulateStop();
    await tester.pump();
    expect(captions.clearCalls, greaterThan(clearsBeforeStop));
    extracted.complete('/tmp/audio.wav');
    await tester.pumpAndSettle();
    // The aborted job never transcribed or burned anything, and the
    // original is the only video saved.
    expect(captions.done, isEmpty);
    expect(captions.failed, isEmpty);
    expect(galleryCalls.where((call) => call == 'putVideo').length, 1);
    expect(find.textContaining('Extracting audio'), findsNothing);
    expect(find.textContaining('Captions failed'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stopping a caption job waiting on the model aborts it',
      (tester) async {
    final captions = FakeCaptionJobNotifier();
    model.gate = Completer<WhisperModelFiles>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dual_cameras_example/captions'),
            (call) async => '/tmp/audio.wav');
    await openCamera(tester, captions: captions);
    await tester.ensureVisible(find.byKey(const Key('menu-captions')));
    await tester.tap(find.byKey(const Key('menu-captions')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, 'Auto-captions'));
    await tester.tap(find.byTooltip('Close Camera settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Start recording'));
    await tester.tap(find.byTooltip('Start recording'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Stop recording'));
    await tester.pumpAndSettle();
    // The job is waiting on the model: progress shows preparing-model in
    // the notification, nothing in-app.
    expect(captions.progresses.map((p) => p.$1),
        contains(CaptionStage.preparingModel));
    expect(find.textContaining('Preparing speech model'), findsNothing);
    captions.simulateStop();
    await tester.pump();
    model.gate!.complete(FakeModelManager.files);
    await tester.pumpAndSettle();
    // The model arrived after the stop: the job must not run.
    expect(captions.done, isEmpty);
    expect(captions.failed, isEmpty);
    expect(galleryCalls.where((call) => call == 'putVideo').length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('caption language picker saves the choice',
      (tester) async {
    // Synchronous file IO: awaiting real async IO hangs inside
    // testWidgets' fake-async zone, so use the sync dart:io calls.
    final dir = Directory.systemTemp.createTempSync('caption-lang-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store =
        CaptionLanguageStore(documentsDirectory: () async => dir);
    // Bounded pumps, not pumpAndSettle: in foreground mode the model
    // indicator is indeterminate while the model loads, so
    // pumpAndSettle can never settle here (the other foreground
    // captions test uses pump() for the same reason). The picker is
    // scrolled into view after the sheet opens (T1) — it sits below
    // the fold at the default 800x600 surface.
    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    await tester.pumpWidget(DemoApp(
        modelManager: model,
        backgroundCaptions: false,
        captionLanguageStore: store));
    await settle();
    await tester.tap(find.byKey(const Key('menu-captions')));
    await settle();
    // The Captions section is last in the sheet's lazily-built
    // ListView: scroll the picker into view before querying it
    // (issue #20 fix round 2 / T1).
    await tester.scrollUntilVisible(find.text('Caption language'), 100,
        scrollable: find
            .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable))
            .last);
    await settle();
    expect(find.text('Caption language'), findsOneWidget);
    expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Auto'))
            .selected,
        isTrue);
    await tester.tap(find.text('Русский'));
    await settle();
    // Give the store's async save a moment to flush to disk.
    await tester.pump(const Duration(seconds: 1));
    expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Русский'))
            .selected,
        isTrue);
    expect(File('${dir.path}/caption_language.txt').readAsStringSync(),
        'ru');
    expect(tester.takeException(), isNull);
  });

  testWidgets('caption language restores the saved choice on launch',
      (tester) async {
    // Synchronous file IO (see the test above).
    final dir = Directory.systemTemp.createTempSync('caption-lang-');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/caption_language.txt').writeAsStringSync('ru');
    final store =
        CaptionLanguageStore(documentsDirectory: () async => dir);

    await tester.pumpWidget(DemoApp(
        modelManager: model,
        backgroundCaptions: false,
        captionLanguageStore: store));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const Key('menu-captions')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // Scroll the picker into view first (issue #20 fix round 2 / T1):
    // the Captions section is last in the sheet's lazily-built
    // ListView, so the chip is not built yet at this point.
    await tester.scrollUntilVisible(
        find.widgetWithText(ChoiceChip, 'Русский'), 100,
        scrollable: find
            .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable))
            .last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Русский'))
            .selected,
        isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving while captions await model promptly disposes camera',
      (tester) async {
    model.gate = Completer<WhisperModelFiles>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dual_cameras_example/captions'),
            (call) async => '/tmp/audio.wav');
    await tester.pumpWidget(DemoApp(modelManager: model, backgroundCaptions: false));
    await tester.pump();
    model.progress!(.1);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('menu-captions')));
    await tester.tap(find.byKey(const Key('menu-captions')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, 'Auto-captions'));
    await tester.tap(find.byTooltip('Close Camera settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Open camera'));
    await tester.tap(find.byTooltip('Open camera'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Start recording'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Stop recording'));
    await tester.pumpAndSettle();
    expect(model.calls, 1);
    // Delta, not an absolute count: dispose() is fire-and-forget async,
    // so a previous test's deferred disposal can land on this test's
    // fake platform before the leave step (iteration 4 saw disposals=2
    // with no product change). What this test proves is that leaving
    // disposes the camera exactly once more.
    final disposalsBeforeLeaving = fake.disposals;
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(fake.disposals, disposalsBeforeLeaving + 1);
    expect(model.gate!.isCompleted, isFalse);
    model.gate!.complete(FakeModelManager.files);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'caption jobs keep source paths, serialize and recover after failure',
      (tester) async {
    final firstExtraction = Completer<String>();
    final extracted = <String>[];
    final captions = FakeCaptionJobNotifier();
    fake.stopFiles.addAll(['/tmp/first.mp4', '/tmp/second.mp4']);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dual_cameras_example/captions'), (call) async {
      final source = call.arguments['mp4'] as String;
      extracted.add(source);
      if (source == '/tmp/first.mp4') return firstExtraction.future;
      throw StateError('No audio');
    });
    await openCamera(tester, captions: captions);
    await tester.ensureVisible(find.byKey(const Key('menu-captions')));
    await tester.tap(find.byKey(const Key('menu-captions')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, 'Auto-captions'));
    await tester.tap(find.byTooltip('Close Camera settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Start recording'));
    for (var clip = 0; clip < 2; clip++) {
      await tester.tap(find.byTooltip('Start recording'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Stop recording'));
      await tester.pumpAndSettle();
    }
    expect(fake.starts, 2);
    expect(galleryCalls.where((call) => call == 'putVideo').length, 2);
    expect(extracted, ['/tmp/first.mp4']);
    firstExtraction.completeError(StateError('No audio'));
    await tester.pumpAndSettle();
    expect(extracted, ['/tmp/first.mp4', '/tmp/second.mp4']);
    // Both jobs failed at extraction: the failures went to the caption
    // notification (v0.5.3), not to in-app text.
    expect(captions.failed, hasLength(2));
    expect(find.textContaining('plain video kept'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('gallery save prevents repeated capture until original is saved',
      (tester) async {
    final saved = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('gal'), (call) async {
      galleryCalls.add(call.method);
      if (call.method == 'putVideo') await saved.future;
      return null;
    });
    await openCamera(tester);
    await tester.tap(find.byTooltip('Start recording'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Stop recording'));
    await tester.pump();
    await tester.tap(find.byTooltip('Start recording'));
    await tester.pump();
    expect(fake.starts, 1);
    expect(fake.stops, 1);
    expect(galleryCalls.where((call) => call == 'putVideo').length, 1);
    saved.complete();
    await tester.pumpAndSettle();
    // The tap that landed while the save was in flight was queued, not
    // dropped (v0.5.2): clip 2 starts on its own once the original is
    // saved, with no second tap.
    expect(fake.starts, 2);
    expect(find.byTooltip('Stop recording'), findsOneWidget);
  });

  testWidgets('late model completion after disposal is safe', (tester) async {
    model.gate = Completer<WhisperModelFiles>();
    await tester.pumpWidget(DemoApp(modelManager: model, backgroundCaptions: false));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    model.progress!(.7);
    model.gate!.complete(FakeModelManager.files);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsupported device keeps capture disabled', (tester) async {
    fake.supported = false;
    await tester.pumpWidget(DemoApp(modelManager: model, backgroundCaptions: false));
    await tester.pumpAndSettle();
    expect(find.text('StoryCam'), findsOneWidget);
    await tester.tap(find.byTooltip('Open camera'));
    await tester.pumpAndSettle();
    expect(fake.starts, 0);
    expect(find.textContaining('Dual camera is unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('permission denial stays actionable', (tester) async {
    permissions[1] = 0;
    await tester.pumpWidget(DemoApp(modelManager: model, backgroundCaptions: false));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open camera'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Camera and microphone access required'),
        findsOneWidget);
    expect(find.byTooltip('Open camera'), findsOneWidget);
    expect(find.byType(Texture), findsNothing);
  });

  testWidgets('record lock prevents repeat taps and stop saves once',
      (tester) async {
    await openCamera(tester);
    final semantics = tester.ensureSemantics();
    expect(
        tester
            .getSemantics(find.byKey(const Key('capture-control')))
            .getSemanticsData()
            .hasAction(ui.SemanticsAction.tap),
        isTrue);
    semantics.dispose();
    fake.startGate = Completer<void>();
    await tester.tap(find.byTooltip('Start recording'));
    await tester.pump();
    await tester.tap(find.byTooltip('Start recording'));
    await tester.pump();
    expect(fake.starts, 1);
    fake.startGate!.complete();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Stop recording'), findsOneWidget);
    expect(
        tester
            .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.photo_camera_outlined))
            .onPressed,
        isNotNull);
    await tester.tap(find.byTooltip('Take photo'));
    await tester.pumpAndSettle();
    expect(fake.photos, 1);
    expect(fake.stops, 0);
    expect(find.byTooltip('Stop recording'), findsOneWidget);
    await tester.tap(find.byTooltip('Stop recording'));
    await tester.pumpAndSettle();
    expect(fake.stops, 1);
    expect(galleryCalls.where((call) => call == 'putVideo').length, 1);
    expect(find.text('Video saved to gallery'), findsOneWidget);
    expect(find.textContaining('/tmp/'), findsNothing);
  });

  testWidgets('hung camera command times out and the shutter recovers',
      (tester) async {
    fake.startGate = Completer<void>();
    await tester.pumpWidget(DemoApp(
        modelManager: model,
        backgroundCaptions: false,
        cameraCommandTimeout: const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open camera'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Start recording'));
    await tester.pump();
    expect(fake.starts, 1);
    // The native call never returns; the watchdog must surface the error
    // and free the lock instead of dead-buttoning the screen (v0.5.2).
    // Fake-async: advance the test clock so the 100 ms watchdog timer
    // fires — a real `runAsync` delay leaves the fake clock still, so the
    // timeout would never fire inside the test.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.textContaining('Recording failed'), findsOneWidget);
    expect(find.byTooltip('Start recording'), findsOneWidget);
    fake.startGate!.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('filters, captions, settings close and back retain state',
      (tester) async {
    await openCamera(tester);
    // Filter slider (issue #20): tap Moody in the slider — there is no
    // separate Filters sheet anymore.
    await tester.tap(find.text('Moody'));
    await tester.pumpAndSettle();
    expect(fake.filter, VideoFilter.moody);
    // Captions via the bottom menu → Settings at the Captions section.
    await tester.tap(find.byKey(const Key('menu-captions')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, 'Auto-captions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close Camera settings'));
    await tester.pumpAndSettle();
    expect(menuItemIsBold(tester, 'menu-captions'), isTrue);
    // Settings sheet still has Exposure + Debug tuning (deep in the sheet).
    await tester.tap(find.byTooltip('Camera settings'));
    await tester.pumpAndSettle();
    final sheetScrollable = find.descendant(
        of: find.byType(ListView), matching: find.byType(Scrollable)).last;
    await tester.scrollUntilVisible(find.text('Exposure'), 100,
        scrollable: sheetScrollable);
    await tester.pumpAndSettle();
    expect(find.text('Exposure'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Debug tuning'), 100,
        scrollable: sheetScrollable);
    await tester.pumpAndSettle();
    expect(find.text('Debug tuning'), findsOneWidget);
    await tester.tap(find.byTooltip('Close Camera settings'));
    await tester.pumpAndSettle();
    expect(find.text('Debug tuning'), findsNothing);
    // The slider still shows the picked filter.
    expect(find.text('Moody'), findsOneWidget);
  });

  testWidgets('exposure applies while dragging and coalesces pending values',
      (tester) async {
    await openCamera(tester);
    await tester.tap(find.byTooltip('Camera settings'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Exposure'), 100,
        scrollable: find
            .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable))
            .last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Exposure'));
    await tester.pumpAndSettle();
    fake.exposureGate = Completer<void>();
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(.5);
    await tester.pump();
    expect(fake.exposures, [.5]);
    slider.onChanged!(1);
    slider.onChanged!(1.5);
    await tester.pump();
    expect(fake.exposures, [.5]);
    fake.exposureGate!.complete();
    await tester.pumpAndSettle();
    expect(fake.exposures, [.5, 1.5]);
  });

  testWidgets('exposure pointer drag survives pending native update',
      (tester) async {
    await openCamera(tester);
    await tester.tap(find.byTooltip('Camera settings'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Exposure'), 100,
        scrollable: find
            .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable))
            .last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Exposure'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(Slider));
    await tester.pumpAndSettle();
    fake.exposureGate = Completer<void>();
    final drag =
        await tester.startGesture(tester.getCenter(find.byType(Slider)));
    await drag.moveBy(const Offset(50, 0));
    await tester.pump();
    expect(fake.exposures, isNotEmpty); // Sent before the pointer is released.
    await drag.moveBy(const Offset(-100, 0));
    await tester.pump();
    final latest = tester.widget<Slider>(find.byType(Slider)).value;
    expect(latest, isNot(fake.exposures.first));
    expect(fake.exposures.length, 1);
    await drag.up();
    fake.exposureGate!.complete();
    await tester.pumpAndSettle();
    expect(fake.exposures.last, latest);
    expect(tester.takeException(), isNull);
  });

  testWidgets('debug aspect applies live and coalesces pending values',
      (tester) async {
    final gate = Completer<void>();
    final values = <double>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dual_cameras/debug'),
            (call) async {
      if (call.method == 'setAspectOverride') {
        values.add((call.arguments['aspect'] as num).toDouble());
        await gate.future;
      }
      return null;
    });
    await openCamera(tester);
    await tester.tap(find.byTooltip('Camera settings'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Debug tuning'), 100,
        scrollable: find
            .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable))
            .last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Debug tuning'));
    await tester.tap(find.text('Debug tuning'));
    await tester.pumpAndSettle();
    final slider = tester.widget<Slider>(find
        .byWidgetPredicate((widget) => widget is Slider && widget.min == 0)
        .first);
    slider.onChanged!(.75);
    await tester.pump();
    expect(values, [.75]);
    slider.onChanged!(1.25);
    slider.onChanged!(1.5);
    await tester.pump();
    expect(values, [.75]);
    gate.complete();
    await tester.pumpAndSettle();
    expect(values, [.75, 1.5]);
  });

  testWidgets('pending initialization finishes before session disposal',
      (tester) async {
    fake.initGate = Completer<InitResult>();
    await tester.pumpWidget(DemoApp(modelManager: model, backgroundCaptions: false));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open camera'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    expect(fake.disposals, 0);
    await tester.runAsync(() async {
      fake.initGate!.complete(InitResult(
          textureId: 42, capabilities: CameraCapabilities(isSupported: true)));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(fake.disposals, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late support probe is safe after leaving screen',
      (tester) async {
    fake.probeGate = Completer<CameraCapabilities>();
    await tester.pumpWidget(DemoApp(modelManager: model, backgroundCaptions: false));
    await tester.pumpWidget(const SizedBox());
    fake.probeGate!.complete(CameraCapabilities(isSupported: true));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(390, 844),
    const Size(320, 480),
    const Size(844, 390)
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
          'layout ${size.width}x${size.height} text $scale, safe controls and sheets',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 32, bottom: 24);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await openCamera(tester);
        final shutter = tester.getRect(find.byTooltip('Start recording'));
        expect(shutter.top, greaterThanOrEqualTo(32));
        expect(shutter.bottom, lessThanOrEqualTo(size.height - 24));
        expect(shutter.width, greaterThanOrEqualTo(48));
        final aspect = tester.getSize(find.byType(Texture));
        expect(aspect.width / aspect.height, closeTo(9 / 16, .0001));
        await tester.tap(find.byTooltip('Camera settings'));
        await tester.pumpAndSettle();
        // 100 scrolls, not the default 50 (issue #20 fix round 2,
        // layout 320x480 text 2.0): at that size/scale the sheet is
        // ~5400px tall and 'Exposure' sits ~4500px down it, while
        // 50 x 100px steps only reach ~4000px (each drag nets ~80px).
        // The sheet itself scrolls fine — measured by jumping the
        // scroll position; only the test's scroll budget was short.
        await tester.scrollUntilVisible(find.text('Exposure'), 100,
            maxScrolls: 100,
            scrollable: find
                .descendant(
                    of: find.byType(ListView),
                    matching: find.byType(Scrollable))
                .last);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Exposure'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Exposure'));
        await tester.pumpAndSettle();
        expect(find.byType(Slider), findsWidgets);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Close Camera settings'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }

  // ---- Issue #20: map circle, bottom menu, filter slider, lens pills ----

  testWidgets('map circle shows the blue dot and hides when location is denied',
      (tester) async {
    final positions = StreamController<LatLng>.broadcast();
    final headings = StreamController<double>.broadcast();
    addTearDown(positions.close);
    addTearDown(headings.close);
    await openCamera(tester,
        mapLocationService: FakeMapLocationService(
            positions: positions.stream, headings: headings.stream));
    // No fix yet: the plain disc is shown, without the blue dot
    // (issue #20 fix round 2 / T4 — the pre-fix expectation was wrong:
    // MapCircle documents a plain disc pre-fix).
    expect(find.byType(MapCircle), findsOneWidget);
    expect(find.byKey(const Key('map-dot')), findsNothing);
    positions.add(const LatLng(51.5, -0.12));
    // Two pumps: the position crosses two async hops (test controller
    // -> MapLocationService re-broadcast -> screen listener), so one
    // pump only delivers the first hop.
    await tester.pump();
    await tester.pump();
    expect(find.byType(MapCircle), findsOneWidget);
    expect(find.byKey(const Key('map-dot')), findsOneWidget);
    expect(find.byKey(const Key('map-heading-cone')), findsOneWidget);
    // A heading turn keeps the circle (heading-up default).
    headings.add(90);
    await tester.pump();
    expect(find.byType(MapCircle), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Denied permission: the circle never appears, no crash, no prompt.
    await tester.pumpWidget(const SizedBox());
    await openCamera(tester,
        mapLocationService:
            FakeMapLocationService(permissionGranted: false));
    await tester.pumpAndSettle();
    expect(find.byType(MapCircle), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bottom menu shows on/off state and opens settings at the section',
      (tester) async {
    await openCamera(tester);
    // Map on (circle on by default), rear primary, captions off.
    expect(menuItemIsBold(tester, 'menu-map'), isTrue);
    expect(menuItemIsBold(tester, 'menu-front'), isFalse);
    expect(menuItemIsBold(tester, 'menu-rear'), isTrue);
    expect(menuItemIsBold(tester, 'menu-captions'), isFalse);
    expect(menuItemIsBold(tester, 'menu-settings'), isTrue);
    // A menu tap opens the dialog AT that section — never a direct toggle.
    await tester.tap(find.byKey(const Key('menu-rear')));
    await tester.pumpAndSettle();
    expect(find.text('Video quality'), findsOneWidget);
    await tester.tap(find.byTooltip('Close Camera settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('menu-captions')));
    await tester.pumpAndSettle();
    expect(find.text('Auto-captions'), findsOneWidget);
    await tester.tap(find.byTooltip('Close Camera settings'));
    await tester.pumpAndSettle();
    // Nothing was toggled by the taps.
    expect(menuItemIsBold(tester, 'menu-map'), isTrue);
    expect(menuItemIsBold(tester, 'menu-rear'), isTrue);
    expect(menuItemIsBold(tester, 'menu-captions'), isFalse);
  });

  testWidgets('filter slider switches the filter', (tester) async {
    await openCamera(tester);
    expect(fake.filter, VideoFilter.none);
    await tester.tap(find.text('Moody'));
    await tester.pumpAndSettle();
    expect(fake.filter, VideoFilter.moody);
    // Every filter from the PRD is on the slider (scroll to each in turn —
    // the horizontal list only builds what is in view). Visit in slider
    // order: scrollUntilVisible only scrolls forward, so looping back to
    // 'Original' after 'GTA' would never arrive (issue #20 fix round 2
    // / T3). Tap GTA when the loop reaches it.
    for (final name in [
      'Original',
      'Moody',
      'Hyper',
      'Midnight',
      'Simple',
      'Jakarta',
      'GTA',
      'San Andreas',
      'GTA 3',
    ]) {
      await tester.scrollUntilVisible(find.text(name), 100,
          scrollable: find.descendant(
              of: find.byType(FilterSlider),
              matching: find.byType(Scrollable)));
      await tester.pumpAndSettle();
      expect(find.text(name), findsOneWidget);
      if (name == 'GTA') {
        await tester.tap(find.text('GTA'));
        await tester.pumpAndSettle();
        expect(fake.filter, VideoFilter.gta);
      }
    }
  });

  testWidgets('lens pills come from the API and switch the lens',
      (tester) async {
    await openCamera(tester);
    // Rear pills from the fake API (0.5 / 1), 1 selected by default.
    expect(find.byKey(const Key('lens-0.5')), findsOneWidget);
    expect(find.byKey(const Key('lens-1')), findsOneWidget);
    expect(find.byKey(const Key('lens-1.5')), findsNothing);
    await tester.tap(find.byKey(const Key('lens-0.5')));
    await tester.pumpAndSettle();
    expect(fake.lensSelections, [(false, 0.5)]);
  });

  testWidgets('lens pills swap when the primary camera swaps',
      (tester) async {
    await openCamera(tester);
    expect(find.byKey(const Key('lens-0.5')), findsOneWidget);
    await tester.tap(find.byTooltip('Swap cameras'));
    await tester.pumpAndSettle();
    // Front pills now (1 / 1.5), rear 0.5 gone.
    expect(find.byKey(const Key('lens-1.5')), findsOneWidget);
    expect(find.byKey(const Key('lens-0.5')), findsNothing);
    await tester.tap(find.byKey(const Key('lens-1.5')));
    await tester.pumpAndSettle();
    expect(fake.lensSelections, [(true, 1.5)]);
  });

  testWidgets('map section switches compass mode and hides the circle',
      (tester) async {
    final positions = StreamController<LatLng>.broadcast();
    addTearDown(positions.close);
    await openCamera(tester,
        mapLocationService: FakeMapLocationService(
            positions: positions.stream,
            headings: const Stream<double>.empty()));
    positions.add(const LatLng(51.5, -0.12));
    await tester.pump();
    expect(find.byType(MapCircle), findsOneWidget);
    await tester.tap(find.byKey(const Key('menu-map')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('North-up'));
    await tester.pumpAndSettle();
    // Hide the circle from the same section.
    await tester.tap(find.widgetWithText(SwitchListTile, 'Location circle'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close Camera settings'));
    await tester.pumpAndSettle();
    expect(find.byType(MapCircle), findsNothing);
    expect(menuItemIsBold(tester, 'menu-map'), isFalse);
  });

  testWidgets('rear video quality offers 4K only when the device supports it',
      (tester) async {
    await openCamera(tester);
    await tester.tap(find.byKey(const Key('menu-rear')));
    await tester.pumpAndSettle();
    expect(find.text('4K is not available on this device.'), findsOneWidget);
    final chip4k =
        tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '4K'));
    expect(chip4k.onSelected, isNull);
    await tester.tap(find.byTooltip('Close Camera settings'));
    await tester.pumpAndSettle();

    // Same screen, 4K-capable fake: the chip is enabled and selects 4K.
    fake.supports4kValue = true;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await openCamera(tester);
    await tester.tap(find.byKey(const Key('menu-rear')));
    await tester.pumpAndSettle();
    expect(find.text('4K is not available on this device.'), findsNothing);
    await tester.tap(find.text('4K'));
    await tester.pumpAndSettle();
    expect(fake.resolution, DualResolution.ultraHd2160);
  });

  testWidgets('mirror selfie row wires the debug channel', (tester) async {
    final values = <bool>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dual_cameras/debug'),
            (call) async {
      if (call.method == 'setMirrorFront') {
        values.add(call.arguments['on'] as bool);
      }
      return null;
    });
    await openCamera(tester);
    // _reapplyTuning already sent the stored value on start; the tap
    // below must be the only call after this point.
    values.clear();
    await tester.tap(find.byKey(const Key('menu-front')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, 'Mirror selfie'));
    await tester.pumpAndSettle();
    // mirrorFront defaults to true, so tapping the ON switch sends
    // false (issue #20 fix round 2 / T5 — the old [true] expectation
    // was wrong).
    expect(values, [false]);
  });

  testWidgets('slider, pills and menu overlay the full-screen preview',
      (tester) async {
    await openCamera(tester);
    final preview = tester.getRect(find.byType(Texture));
    // The video is full-screen (letterboxed 9:16 inside the Stack).
    expect(preview.width, greaterThan(0));
    final slider = tester.getRect(find.byKey(const Key('filter-slider')));
    final pills = tester.getRect(find.byKey(const Key('lens-pills')));
    final menu = tester.getRect(find.byKey(const Key('bottom-menu')));
    final shutter = tester.getRect(find.byTooltip('Start recording'));
    // All controls sit inside the preview area, stacked bottom-up:
    // pills above the slider, slider above the shutter, menu at the bottom.
    for (final rect in [slider, pills, menu, shutter]) {
      expect(preview.contains(rect.center), isTrue);
    }
    expect(pills.bottom, lessThanOrEqualTo(slider.top));
    expect(slider.bottom, lessThanOrEqualTo(shutter.top));
    expect(shutter.bottom, lessThanOrEqualTo(menu.top));
  });
}
