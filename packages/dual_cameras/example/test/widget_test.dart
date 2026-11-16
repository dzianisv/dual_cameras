import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dual_cameras_example/main.dart';
import 'package:dual_cameras_example/captions/caption_job_notifier.dart';
import 'package:dual_cameras_example/captions/caption_language_store.dart';
import 'package:dual_cameras_example/captions/model_download_notifier.dart';
import 'package:dual_cameras_example/captions/model_manager.dart';
import 'package:dual_cameras_example/captions/caption_models.dart';
import 'package:dual_cameras_example/captions/review_prompt_gate.dart';
import 'package:dual_cameras_example/captions/transcriber.dart';
import 'package:dual_cameras_example/map/camera_settings.dart';
import 'package:dual_cameras_example/map/map_location.dart';
import 'package:dual_cameras_example/map/place_name.dart';
import 'package:dual_cameras_example/review_prompt.dart';
import 'package:dual_cameras_example/ui/filter_slider.dart';
import 'package:dual_cameras_example/ui/map_circle.dart';
import 'package:dual_cameras_platform_interface/dual_cameras_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

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
  int mapProgressCalls = 0;
  int mapDoneCalls = 0;
  final List<String> mapFailed = [];
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
  Future<void> showMapProgress(double progress) async {
    mapProgressCalls++;
  }

  @override
  Future<void> showMapDone() async {
    mapDoneCalls++;
  }

  @override
  Future<void> showMapFailed(String error) async {
    mapFailed.add(error);
  }

  @override
  Future<void> clear() async {
    clearCalls++;
  }
}

/// Fake on-device transcriber (issue #50, F2 fix): returns one word, so
/// the foreground caption job completes and the captioned twin exists.
/// The real Transcriber is sherpa-onnx FFI and cannot run in a widget
/// test; injected through the DemoApp transcriber seam.
class FakeTranscriber extends Transcriber {
  @override
  Future<TranscriptionResult> transcribe({
    required String wavPath,
    required WhisperModelFiles model,
    String language = '',
  }) async {
    return const TranscriptionResult(
      words: [CaptionWord(text: 'hello', start: 0, end: 1)],
      detectedLanguage: 'en',
      timingsValid: true,
    );
  }
}

/// Fake Play review prompt (issue #37): records requests and returns a
/// chosen availability, so tests count prompts without Play.
class FakeReviewPrompt implements ReviewPrompt {
  bool available = true;
  int availabilityChecks = 0;
  int requests = 0;

  @override
  Future<bool> isAvailable() async {
    availabilityChecks++;
    return available;
  }

  @override
  Future<void> requestReview() async {
    requests++;
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

  // Issue #48: fail lens switches (the probe offered a ratio the switch
  // rejects) or hold them in flight (a tap landing while busy). The
  // gate is captured per call, so clearing it after the first call lets
  // a queued second switch through.
  Exception? setLensError;
  Completer<void>? setLensGate;

  @override
  Future<void> setLens(bool front, double ratio) async {
    lensSelections.add((front, ratio));
    final gate = setLensGate;
    if (gate != null) await gate.future;
    if (setLensError != null) throw setLensError!;
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

/// Fake video_player platform (issue #50): answers create with a texture
/// id and emits a single initialized event, so the in-app player opens
/// in widget tests without a real video or native player. Play/pause/
/// seek/volume/looping/speed are counted no-ops; getPosition stays at
/// zero (so the play-position timer never schedules a frame); the view
/// is an empty box.
class FakeVideoPlayerPlatform extends VideoPlayerPlatform
    with MockPlatformInterfaceMixin {
  int playCalls = 0;
  int pauseCalls = 0;
  int disposeCalls = 0;

  @override
  Future<void> init() async {}

  @override
  Future<int?> create(DataSource dataSource) async => 0;

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) =>
      Stream<VideoEvent>.value(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(seconds: 10),
          size: const Size(640, 360),
        ),
      );

  @override
  Future<void> play(int playerId) async {
    playCalls++;
  }

  @override
  Future<void> pause(int playerId) async {
    pauseCalls++;
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Future<void> dispose(int playerId) async {
    disposeCalls++;
  }

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.shrink();
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

/// Test harness for MapCircle: holds position + zoom like the camera
/// screen does, feeding gesture reports back in as the new zoom (the
/// parent contract from issue #47, D1/D4).
class MapCircleHarness extends StatefulWidget {
  const MapCircleHarness({
    super.key,
    required this.initialPosition,
    this.initialZoom = 16.0,
    this.placeName,
    this.showTiles = true,
  });

  final LatLng initialPosition;
  final double initialZoom;
  final String? placeName;
  final bool showTiles;

  @override
  State<MapCircleHarness> createState() => MapCircleHarnessState();
}

class MapCircleHarnessState extends State<MapCircleHarness> {
  late LatLng position = widget.initialPosition;
  late double zoom = widget.initialZoom;

  /// Every zoom the map reported, in order (one per gesture, D4).
  final List<double> zoomReports = [];

  void setPosition(LatLng next) => setState(() => position = next);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: MapCircle(
            position: position,
            headingDeg: 0,
            mode: CompassMode.headingUp,
            zoom: zoom,
            placeName: widget.placeName,
            onZoomChanged: (z) {
              zoomReports.add(z);
              setState(() => zoom = z);
            },
            showTiles: widget.showTiles,
          ),
        ),
      ),
    );
  }
}

/// Whether a bottom-menu item reads as ON (bold white, issue #20 v4).
bool menuItemIsBold(WidgetTester tester, String key) {
  final text = tester.widget<Text>(find.descendant(
      of: find.byKey(Key(key)), matching: find.byType(Text)));
  return text.style?.fontWeight == FontWeight.w800;
}

/// Whether a lens pill reads as selected (white pill, issue #48): the
/// selected pill is the stored pick, so this is the stored-pick check.
bool lensPillIsSelected(WidgetTester tester, String label) {
  final container = tester.widget<Container>(find.descendant(
      of: find.byKey(ValueKey('lens-$label')),
      matching: find.byType(Container)));
  return (container.decoration as BoxDecoration?)?.color == Colors.white;
}

void main() {
  late FakeCamera fake;
  late FakeModelManager model;
  late DualCamerasPlatform previousPlatform;
  // Permission statuses by Permission value (camera=1, microphone=7 —
  // permission_handler values, not 0/1): the mocks below answer both the
  // request and the status check from this map.
  final permissions = <int, int>{1: 1, 7: 1};
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
            (call) async {
      // Issue #46: _start checks status before requesting, so the mock
      // must answer checkPermissionStatus too — a null reply throws
      // inside decodePermissionStatus and the camera never opens.
      // Unknown permissions (e.g. location=3) read as denied, matching
      // the old mock which never granted anything it was not asked about.
      if (call.method == 'requestPermissions') return permissions;
      if (call.method == 'checkPermissionStatus') {
        return permissions[call.arguments as int] ?? 0;
      }
      return null;
    });
    // Issue #46: _autoStart awaits the settings load, which reads the
    // documents directory via path_provider — an unmocked channel never
    // replies in widget tests, so the load would hang forever and
    // auto-init would never fire. A null reply makes path_provider
    // throw MissingPlatformDirectoryException, which the store catches
    // and turns into defaults.
    //
    // Issue #47: flutter_map's tile provider needs a real cache directory
    // (getApplicationCacheDirectory) when a FlutterMap is pumped with
    // tiles — without it the provider throws MissingPlatformDirectoryException
    // into the test. The documents directory stays unmocked (null) so the
    // settings stores keep starting from defaults in tests.
    final tileCacheDir =
        Directory.systemTemp.createTempSync('storycam-tile-cache-');
    addTearDown(() => tileCacheDir.deleteSync(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async {
      if (call.method == 'getApplicationCacheDirectory') {
        return tileCacheDir.path;
      }
      return null;
    });
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

  /// Issue #46: the camera auto-initializes on open when permissions are
  /// granted, so pumping + settling is the whole open — no 'Open camera'
  /// tap. That button is the retry now, used only when init fails or
  /// permissions are denied.
  Future<void> openCamera(WidgetTester tester,
      {CaptionJobNotifier? captions,
      MapLocationService? mapLocationService,
      CameraSettingsStore? cameraSettingsStore,
      PlaceNameService? placeNameService,
      ReviewPrompt? reviewPrompt,
      ReviewPromptGate? reviewPromptGate,
      String? appVersion,
      Future<void> Function(File file)? deleteFile,
      Transcriber? transcriber}) async {
    await tester.pumpWidget(DemoApp(
        modelManager: model,
        backgroundCaptions: false,
        captionJobNotifier: captions,
        cameraSettingsStore: cameraSettingsStore,
        mapLocationService: mapLocationService,
        placeNameService: placeNameService,
        reviewPrompt: reviewPrompt,
        reviewPromptGate: reviewPromptGate,
        appVersion: appVersion,
        deleteFile: deleteFile,
        transcriber: transcriber));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Start recording'), findsOneWidget);
    expect(find.text('Ready to tell your story'), findsOneWidget);
  }

  /// One full recording: start, then stop and save to the gallery.
  Future<void> recordAndStop(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Start recording'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Stop recording'));
    await tester.pumpAndSettle();
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
    // Issue #46: the camera auto-initialized on open; 'Open camera' is
    // gone, the record button is live.
    expect(find.byTooltip('Start recording'), findsOneWidget);
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
    // Issue #46: the camera auto-initialized on open; no 'Open camera' tap.
    expect(find.byTooltip('Start recording'), findsOneWidget);
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
    // Issue #46: the camera auto-initialized on open; no 'Open camera' tap.
    expect(find.byTooltip('Start recording'), findsOneWidget);
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

  testWidgets('camera auto-initializes on open with no tap', (tester) async {
    await tester.pumpWidget(DemoApp(modelManager: model, backgroundCaptions: false));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Start recording'), findsOneWidget);
    expect(find.text('Ready to tell your story'), findsOneWidget);
    expect(find.byTooltip('Open camera'), findsNothing);
    expect(find.byType(Texture), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('permanently denied permission is never re-prompted on open',
      (tester) async {
    permissions[1] = 4; // camera: PermissionStatus.permanentlyDenied
    permissions[7] = 4; // microphone: permanentlyDenied
    var cameraMicRequests = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('flutter.baseflow.com/permissions/methods'),
            (call) async {
      if (call.method == 'requestPermissions') {
        final requested = (call.arguments as List).cast<int>();
        if (requested.contains(1) || requested.contains(7)) {
          cameraMicRequests++;
        }
        return permissions;
      }
      if (call.method == 'checkPermissionStatus') {
        return permissions[call.arguments as int] ?? 0;
      }
      return null;
    });
    await tester.pumpWidget(DemoApp(modelManager: model, backgroundCaptions: false));
    await tester.pumpAndSettle();
    expect(cameraMicRequests, 0);
    expect(find.textContaining('Camera and microphone access required'),
        findsOneWidget);
    expect(find.byTooltip('Open camera'), findsOneWidget);
    expect(find.byType(Texture), findsNothing);
    expect(tester.takeException(), isNull);
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
    // Issue #46: the camera auto-initialized on open; no 'Open camera' tap.
    expect(find.byTooltip('Start recording'), findsOneWidget);
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
    // Issue #25: the Debug-tuning tile must keep its expanded state when
    // the _busy indicator is inserted/removed above it. Flip _busy via
    // 'Reset aspect → auto' (a _guard call whose aspect calls are gated
    // here), then re-query the Slider fresh — never reuse the captured
    // object — and assert the tile is still expanded and the slider live.
    final busyGate = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dual_cameras/debug'),
            (call) async {
      if (call.method == 'setAspectOverride') {
        values.add((call.arguments['aspect'] as num).toDouble());
        await busyGate.future;
      }
      return null;
    });
    await tester.scrollUntilVisible(find.text('Reset aspect → auto'), 100,
        scrollable: find
            .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable))
            .last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Reset aspect → auto'));
    await tester.tap(find.text('Reset aspect → auto'));
    await tester.pump();
    await tester.pump();
    // _busy is true: the panel is pointer-blocked while the indicator is
    // inserted above the tile. (The indicator itself sits far off-screen
    // while scrolled down here, so ListView lazily unbuilds it — the
    // in-tree proof of the flip is the IgnorePointer, not the indicator.)
    expect(
        tester
            .widget<IgnorePointer>(
                find.byKey(const ValueKey('debug-tuning-panel')))
            .ignoring,
        isTrue);
    expect(find.text('Front aspect'), findsOneWidget);
    busyGate.complete();
    await tester.pumpAndSettle();
    // _busy is false again: the panel is live and the tile is still
    // expanded. A remounted tile would have collapsed and hidden its rows.
    expect(
        tester
            .widget<IgnorePointer>(
                find.byKey(const ValueKey('debug-tuning-panel')))
            .ignoring,
        isFalse);
    expect(find.text('Front aspect'), findsOneWidget);
    final sliderAfterFlip = tester.widget<Slider>(find
        .byWidgetPredicate((widget) => widget is Slider && widget.min == 0)
        .first);
    sliderAfterFlip.onChanged!(1.0);
    await tester.pumpAndSettle();
    expect(values, [.75, 1.5, 0, 0, 1.0]);
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
    // Heading cone removed (issue #83): no cone anywhere, dot only.
    expect(find.byKey(const Key('map-heading-cone')), findsNothing);
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
    // 'Original' after 'Vice City' would never arrive (issue #20 fix round 2
    // / T3). Tap Vice City when the loop reaches it.
    for (final name in [
      'Original',
      'Moody',
      'Hyper',
      'Midnight',
      'Simple',
      'Jakarta',
      'Vice City',
      'San Andreas',
    ]) {
      await tester.scrollUntilVisible(find.text(name), 100,
          scrollable: find.descendant(
              of: find.byType(FilterSlider),
              matching: find.byType(Scrollable)));
      await tester.pumpAndSettle();
      expect(find.text(name), findsOneWidget);
      if (name == 'Vice City') {
        await tester.tap(find.text('Vice City'));
        await tester.pumpAndSettle();
        expect(fake.filter, VideoFilter.viceCity);
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

  testWidgets('lens switch failure shows an error and keeps the stored pick',
      (tester) async {
    await openCamera(tester);
    // Rear pills from the fake API (0.5 / 1), 1 selected by default.
    expect(lensPillIsSelected(tester, '1'), isTrue);
    // Issue #48: the probe offered 0.5 but the switch rejects it (the
    // Android focal-ratio / zoom-range mismatch). The attempt reaches
    // the platform, the error surfaces on screen, and the stored pick
    // stays on 1 — the failed tap never saves, never re-selects.
    fake.setLensError =
        Exception('Lens 0.5x is not available right now');
    await tester.tap(find.byKey(const Key('lens-0.5')));
    await tester.pumpAndSettle();
    expect(fake.lensSelections, [(false, 0.5)]);
    expect(find.textContaining('Lens switch failed'), findsOneWidget);
    expect(lensPillIsSelected(tester, '1'), isTrue);
    expect(lensPillIsSelected(tester, '0.5'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lens tap while busy is queued, not dropped', (tester) async {
    await openCamera(tester);
    // Hold the first switch in flight: _busy is true, pills stay enabled.
    final gate = Completer<void>();
    fake.setLensGate = gate;
    await tester.tap(find.byKey(const Key('lens-0.5')));
    await tester.pump();
    expect(fake.lensSelections, [(false, 0.5)]);
    // Second tap while busy: queued at once ('Please wait…'), not fired.
    await tester.tap(find.byKey(const Key('lens-1')));
    await tester.pump();
    expect(find.textContaining('Please wait…'), findsOneWidget);
    expect(fake.lensSelections, [(false, 0.5)]);
    // The in-flight switch lands; the queued tap fires after it and the
    // pre-wait status comes back (no stuck 'Please wait…').
    fake.setLensGate = null;
    gate.complete();
    await tester.pumpAndSettle();
    expect(fake.lensSelections, [(false, 0.5), (false, 1.0)]);
    expect(lensPillIsSelected(tester, '1'), isTrue);
    expect(find.textContaining('Please wait…'), findsNothing);
    expect(tester.takeException(), isNull);
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

  // In-app review prompt (issue #37): T1–T5. The prompt is requested at
  // most once per app version, on the first completed recording of that
  // version — never on first launch, never on a sideloaded build.
  testWidgets('T1 review prompt is not requested on first launch',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('review-prompt-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final review = FakeReviewPrompt();
    final gate = ReviewPromptGate(documentsDirectory: () async => dir);
    await tester.pumpWidget(DemoApp(
        modelManager: model,
        backgroundCaptions: false,
        reviewPrompt: review,
        reviewPromptGate: gate,
        appVersion: '0.5.11'));
    await tester.pumpAndSettle();
    expect(review.requests, 0);
    expect(review.availabilityChecks, 0);
    expect(File('${dir.path}/review_prompt_version.txt').existsSync(),
        isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'T2 review prompt is requested once on the first save of a version',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('review-prompt-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final review = FakeReviewPrompt();
    final gate = ReviewPromptGate(documentsDirectory: () async => dir);
    await openCamera(tester,
        reviewPrompt: review,
        reviewPromptGate: gate,
        appVersion: '0.5.11');
    await recordAndStop(tester);
    expect(find.text('Video saved to gallery'), findsOneWidget);
    expect(review.requests, 1);
    expect(
        File('${dir.path}/review_prompt_version.txt').readAsStringSync(),
        '0.5.11');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'T3 review prompt is not requested again on the second save of a version',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('review-prompt-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final review = FakeReviewPrompt();
    final gate = ReviewPromptGate(documentsDirectory: () async => dir);
    await openCamera(tester,
        reviewPrompt: review,
        reviewPromptGate: gate,
        appVersion: '0.5.11');
    await recordAndStop(tester);
    await recordAndStop(tester);
    expect(fake.stops, 2);
    expect(find.text('Video saved to gallery'), findsOneWidget);
    expect(review.requests, 1);
    expect(
        File('${dir.path}/review_prompt_version.txt').readAsStringSync(),
        '0.5.11');
    expect(tester.takeException(), isNull);
  });

  testWidgets('T4 review prompt re-arms when the app version changes',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('review-prompt-');
    addTearDown(() => dir.deleteSync(recursive: true));
    // Prompted already for 0.5.11 in a previous session.
    File('${dir.path}/review_prompt_version.txt')
        .writeAsStringSync('0.5.11');
    final review = FakeReviewPrompt();
    final gate = ReviewPromptGate(documentsDirectory: () async => dir);
    await openCamera(tester,
        reviewPrompt: review,
        reviewPromptGate: gate,
        appVersion: '0.5.12');
    await recordAndStop(tester);
    expect(find.text('Video saved to gallery'), findsOneWidget);
    expect(review.requests, 1);
    expect(
        File('${dir.path}/review_prompt_version.txt').readAsStringSync(),
        '0.5.12');
    expect(tester.takeException(), isNull);
  });

  testWidgets('T5 sideloaded shape requests nothing and changes nothing',
      (tester) async {
    // Variant A: Play reports unavailable (sideloaded build) — skip
    // WITHOUT marking, so a later Play install can still prompt.
    final dir = Directory.systemTemp.createTempSync('review-prompt-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final review = FakeReviewPrompt()..available = false;
    final gate = ReviewPromptGate(documentsDirectory: () async => dir);
    await openCamera(tester,
        reviewPrompt: review,
        reviewPromptGate: gate,
        appVersion: '0.5.11');
    await recordAndStop(tester);
    expect(find.text('Video saved to gallery'), findsOneWidget);
    // Issue #50: the persistent Share button is gone — the
    // last-video thumbnail takes its place after a recording.
    expect(find.byKey(const Key('share-button')), findsNothing);
    expect(find.byKey(const Key('last-video-thumbnail')), findsOneWidget);
    expect(review.requests, 0);
    expect(File('${dir.path}/review_prompt_version.txt').existsSync(),
        isFalse);
    expect(tester.takeException(), isNull);

    // Variant B: no method-channel handler, so the real Play call throws
    // (MissingPluginException) — swallowed, no crash, nothing marked.
    // Pump a SizedBox first: pumping a second DemoApp over the first
    // reuses the old screen state (camera already open), so the fresh
    // screen only exists after the old one is disposed.
    final dir2 = Directory.systemTemp.createTempSync('review-prompt-');
    addTearDown(() => dir2.deleteSync(recursive: true));
    final gate2 = ReviewPromptGate(documentsDirectory: () async => dir2);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.pumpWidget(DemoApp(
        modelManager: model,
        backgroundCaptions: false,
        reviewPromptGate: gate2,
        appVersion: '0.5.11'));
    await tester.pumpAndSettle();
    // Issue #46: the camera auto-initialized on open; no 'Open camera' tap.
    expect(find.byTooltip('Start recording'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Ready to tell your story'), findsOneWidget);
    await recordAndStop(tester);
    expect(find.text('Video saved to gallery'), findsOneWidget);
    // Issue #50: the persistent Share button is gone — the
    // last-video thumbnail takes its place after a recording.
    expect(find.byKey(const Key('share-button')), findsNothing);
    expect(find.byKey(const Key('last-video-thumbnail')), findsOneWidget);
    expect(File('${dir2.path}/review_prompt_version.txt').existsSync(),
        isFalse);
    expect(tester.takeException(), isNull);
  });

  // ---- Issue #47: map pinch-to-zoom, zoom setting, place name ----

  /// Live zoom / center of the pumped FlutterMap.
  double mapZoom(WidgetTester tester) => tester
      .widget<FlutterMap>(find.byType(FlutterMap))
      .mapController!
      .camera
      .zoom;
  LatLng mapCenter(WidgetTester tester) => tester
      .widget<FlutterMap>(find.byType(FlutterMap))
      .mapController!
      .camera
      .center;

  /// Two-finger spread on the map circle (pinch zoom in).
  Future<void> pinchIn(WidgetTester tester) async {
    final center = tester.getCenter(find.byKey(const Key('map-circle')));
    final first = await tester.startGesture(center + const Offset(-20, 0));
    final second = await tester.startGesture(center + const Offset(20, 0));
    await tester.pump();
    for (var i = 1; i <= 5; i++) {
      await first.moveTo(center + Offset(-20.0 - i * 8, 0));
      await second.moveTo(center + Offset(20.0 + i * 8, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
  }

  /// A PlaceNameService backed by a MockClient (the sanctioned exception
  /// to the no-mock rule, for this network client only — issue #47, N7)
  /// that answers the Nominatim switch + reverse endpoints from canned
  /// responses and records every request.
  PlaceNameService testPlaceNames({
    required Directory dir,
    List<Uri>? reverseRequests,
    List<DateTime>? reverseTimes,
    List<Uri>? switchRequests,
    List<String>? userAgents,
    String Function(Uri url)? reverseBody,
    int reverseStatus = 200,
    Duration reverseDelay = Duration.zero,
    bool Function()? switchFails,
    bool switchEnabled = true,
    Duration minRequestInterval = const Duration(milliseconds: 1100),
    Duration switchRetryInterval = const Duration(seconds: 60),
    Duration requestTimeout = const Duration(seconds: 10),
  }) {
    final client = MockClient((request) async {
      if (request.url.host == 'dzianisv.github.io') {
        switchRequests?.add(request.url);
        if (switchFails?.call() ?? false) {
          return http.Response('boom', 500);
        }
        return http.Response('{"enabled": $switchEnabled}', 200,
            headers: {'content-type': 'application/json'});
      }
      if (request.url.host == 'nominatim.openstreetmap.org') {
        reverseRequests?.add(request.url);
        reverseTimes?.add(DateTime.now());
        userAgents?.add(request.headers['User-Agent'] ?? '');
        if (reverseDelay > Duration.zero) {
          await Future.delayed(reverseDelay);
        }
        final body = reverseBody?.call(request.url) ??
            '{"display_name": "12, Main Street, Springfield, Illinois, United States", '
                '"address": {"city": "Springfield", "state": "Illinois", "country": "United States"}}';
        return http.Response(body, reverseStatus,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('not found', 404);
    });
    return PlaceNameService(
      client: client,
      documentsDirectory: () async => dir,
      appVersion: '0.5.11',
      minRequestInterval: minRequestInterval,
      switchRetryInterval: switchRetryInterval,
      requestTimeout: requestTimeout,
    );
  }

  testWidgets('pinch zooms the map and reports the final zoom once',
      (tester) async {
    final harnessKey = GlobalKey<MapCircleHarnessState>();
    await tester.pumpWidget(MapCircleHarness(
      key: harnessKey,
      initialPosition: const LatLng(51.5, -0.12),
    ));
    await tester.pump();
    expect(mapZoom(tester), 16.0);

    await pinchIn(tester);

    final zoomed = mapZoom(tester);
    expect(zoomed, greaterThan(16.0));
    expect(harnessKey.currentState!.zoomReports, [zoomed]);
    // The dot re-centered on the position after the gesture.
    final center = mapCenter(tester);
    expect(center.latitude, closeTo(51.5, 1e-6));
    expect(center.longitude, closeTo(-0.12, 1e-6));
    expect(tester.takeException(), isNull);
  });

  testWidgets('double-tap zooms and reports once, re-centering the dot',
      (tester) async {
    final harnessKey = GlobalKey<MapCircleHarnessState>();
    await tester.pumpWidget(MapCircleHarness(
      key: harnessKey,
      initialPosition: const LatLng(51.5, -0.12),
    ));
    await tester.pump();
    expect(mapZoom(tester), 16.0);

    // Tap off-center: double-tap zoom moves the center toward the tap
    // point, so the end-handler re-center is load-bearing here.
    final tapAt = tester.getCenter(find.byKey(const Key('map-circle'))) +
        const Offset(30, 0);
    await tester.tapAt(tapAt);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(tapAt);
    await tester.pumpAndSettle();

    final zoomed = mapZoom(tester);
    expect(zoomed, greaterThan(16.0));
    expect(harnessKey.currentState!.zoomReports, [zoomed]);
    final center = mapCenter(tester);
    expect(center.latitude, closeTo(51.5, 1e-6));
    expect(center.longitude, closeTo(-0.12, 1e-6));
    expect(tester.takeException(), isNull);
  });

  testWidgets('position update after a pinch keeps the pinched zoom',
      (tester) async {
    final harnessKey = GlobalKey<MapCircleHarnessState>();
    await tester.pumpWidget(MapCircleHarness(
      key: harnessKey,
      initialPosition: const LatLng(51.5, -0.12),
    ));
    await tester.pump();
    await pinchIn(tester);
    final zoomed = mapZoom(tester);
    expect(zoomed, greaterThan(16.0));

    // A new fix: re-centers, keeps the pinched zoom (no reset to 16).
    harnessKey.currentState!.setPosition(const LatLng(51.501, -0.119));
    await tester.pump();
    expect(mapZoom(tester), zoomed);
    final center = mapCenter(tester);
    expect(center.latitude, closeTo(51.501, 1e-6));
    expect(center.longitude, closeTo(-0.119, 1e-6));
    expect(tester.takeException(), isNull);
  });

  testWidgets('position update mid-pinch does not jump the map',
      (tester) async {
    final harnessKey = GlobalKey<MapCircleHarnessState>();
    await tester.pumpWidget(MapCircleHarness(
      key: harnessKey,
      initialPosition: const LatLng(51.5, -0.12),
    ));
    await tester.pump();
    final center = tester.getCenter(find.byKey(const Key('map-circle')));
    final first = await tester.startGesture(center + const Offset(-20, 0));
    final second = await tester.startGesture(center + const Offset(20, 0));
    await tester.pump();
    // Three moves: the first is inside the scale slop (no zoom yet), the
    // second is accepted as the gesture start (scale still 1.0), the
    // third actually zooms — only then is a pinch in flight.
    await first.moveTo(center + const Offset(-28, 0));
    await second.moveTo(center + const Offset(28, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await first.moveTo(center + const Offset(-36, 0));
    await second.moveTo(center + const Offset(36, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await first.moveTo(center + const Offset(-44, 0));
    await second.moveTo(center + const Offset(44, 0));
    await tester.pump(const Duration(milliseconds: 16));
    final midZoom = mapZoom(tester);
    final midCenter = mapCenter(tester);
    expect(midZoom, greaterThan(16.0));

    // A fix arrives mid-gesture: the re-center is deferred, so the
    // camera must not jump.
    harnessKey.currentState!.setPosition(const LatLng(51.501, -0.119));
    await tester.pump();
    expect(mapZoom(tester), midZoom);
    expect(mapCenter(tester).latitude, closeTo(midCenter.latitude, 1e-9));
    expect(mapCenter(tester).longitude, closeTo(midCenter.longitude, 1e-9));

    // Finish the gesture: exactly one report, re-centered on the latest
    // fix.
    await first.moveTo(center + const Offset(-60, 0));
    await second.moveTo(center + const Offset(60, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    expect(harnessKey.currentState!.zoomReports.length, 1);
    final endCenter = mapCenter(tester);
    expect(endCenter.latitude, closeTo(51.501, 1e-6));
    expect(endCenter.longitude, closeTo(-0.119, 1e-6));
    expect(tester.takeException(), isNull);
  });

  testWidgets('stored zoom 18.5 is the first-paint zoom on relaunch',
      (tester) async {
    await tester.pumpWidget(const MapCircleHarness(
      initialPosition: LatLng(51.5, -0.12),
      initialZoom: 18.5,
    ));
    await tester.pump();
    // First paint, before any position update.
    expect(mapZoom(tester), 18.5);
    expect(tester.takeException(), isNull);
  });

  testWidgets('N badge and blue dot render at zoom 19.0',
      (tester) async {
    await tester.pumpWidget(const MapCircleHarness(
      initialPosition: LatLng(51.5, -0.12),
      initialZoom: 19.0,
    ));
    await tester.pump();
    expect(find.text('N'), findsOneWidget);
    // Heading cone removed (issue #83): no cone anywhere, dot only.
    expect(find.byKey(const Key('map-heading-cone')), findsNothing);
    expect(find.byKey(const Key('map-dot')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('place pill renders with a name and hides without one',
      (tester) async {
    await tester.pumpWidget(const MapCircleHarness(
      initialPosition: LatLng(51.5, -0.12),
      placeName: 'San Francisco, California',
      showTiles: false,
    ));
    await tester.pump();
    expect(find.text('San Francisco, California'), findsOneWidget);
    expect(find.byKey(const Key('map-place-name')), findsOneWidget);

    await tester.pumpWidget(const MapCircleHarness(
      initialPosition: LatLng(51.5, -0.12),
      showTiles: false,
    ));
    await tester.pump();
    expect(find.byKey(const Key('map-place-name')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('OSM attribution renders when tiles are shown',
      (tester) async {
    await tester.pumpWidget(const MapCircleHarness(
      initialPosition: LatLng(51.5, -0.12),
    ));
    await tester.pump();
    expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
    expect(find.byKey(const Key('map-attribution')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('map zoom slider previews live and persists on release',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('storycam-47-settings-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = CameraSettingsStore(documentsDirectory: () async => dir);
    final positions = StreamController<LatLng>.broadcast();
    addTearDown(positions.close);
    await openCamera(tester,
        cameraSettingsStore: store,
        mapLocationService: FakeMapLocationService(
            positions: positions.stream,
            headings: const Stream<double>.empty()));
    positions.add(const LatLng(51.5, -0.12));
    await tester.pump();
    await tester.pump();
    expect(find.byType(MapCircle), findsOneWidget);

    await tester.tap(find.byKey(const Key('menu-map')));
    await tester.pumpAndSettle();
    final slider = find.byKey(const Key('map-zoom-slider'));
    expect(slider, findsOneWidget);
    expect(find.text('Map zoom 16.0'), findsOneWidget);

    // Drag 16.0 -> 18.5. A drag starts at the touched position, so start
    // at the widget center — the midpoint value 10.5 of the 2–19 range
    // (issue #82; the track padding is symmetric, so the center is the
    // midpoint under any theme) — and move +8.0 of value. One value unit
    // spans trackWidth/17, where the track is the slider width less the
    // overlay/thumb padding (BaseSliderTrackShape.getPreferredRect), so
    // read that padding from the live theme instead of assuming it.
    final rect = tester.getRect(slider);
    final theme = SliderTheme.of(tester.element(slider));
    // The theme in this test leaves the shapes null; fall back to the
    // framework defaults (the same shapes SliderThemeData uses).
    final overlayWidth = (theme.overlayShape ?? const RoundSliderOverlayShape())
        .getPreferredSize(true, true)
        .width;
    final thumbWidth = (theme.thumbShape ?? const RoundSliderThumbShape())
        .getPreferredSize(true, true)
        .width;
    final trackWidth =
        rect.width - (overlayWidth > thumbWidth ? overlayWidth : thumbWidth);
    await tester.dragFrom(
        rect.center, Offset(trackWidth * (8.0 / 17), 0));
    await tester.pumpAndSettle();
    expect(find.text('Map zoom 18.5'), findsOneWidget);
    // Live: the map behind the sheet re-zoomed.
    expect(tester.widget<MapCircle>(find.byType(MapCircle)).zoom, 18.5);

    // Released (drag end saves): a fresh store load restores 18.5.
    final restored = await CameraSettingsStore(
            documentsDirectory: () async => dir)
        .load();
    expect(restored.mapZoom, 18.5);
    expect(tester.takeException(), isNull);
  });

  testWidgets('place pill shows the reverse-geocoded name after a fix',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('storycam-47-places-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final positions = StreamController<LatLng>.broadcast();
    addTearDown(positions.close);
    final placeNames = testPlaceNames(dir: dir, reverseRequests: []);
    await openCamera(tester,
        mapLocationService: FakeMapLocationService(
            positions: positions.stream,
            headings: const Stream<double>.empty()),
        placeNameService: placeNames);
    positions.add(const LatLng(39.7817, -89.6501));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('Springfield, Illinois'), findsOneWidget);
    expect(find.byKey(const Key('map-place-name')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('CameraSettings.fromJson clamps mapZoom to 2-19', () {
    expect(CameraSettings.fromJson({'mapZoom': 25}).mapZoom, 19.0);
    expect(CameraSettings.fromJson({'mapZoom': 0}).mapZoom, 2.0);
    expect(CameraSettings.fromJson({'mapZoom': 2}).mapZoom, 2.0);
    expect(CameraSettings.fromJson({'mapZoom': 18.5}).mapZoom, 18.5);
    expect(CameraSettings.fromJson({}).mapZoom, 16.0);
    expect(CameraSettings.fromJson({'mapZoom': 'high'}).mapZoom, 16.0);
    expect(const CameraSettings().mapZoom, 16.0);
    expect(
        const CameraSettings().copyWith(mapZoom: 17.5).toJson()['mapZoom'],
        17.5);
  });

  test('PlaceNameService looks up once per 100 m move, 1.1 s floor',
      () async {
    final dir = Directory.systemTemp.createTempSync('storycam-47-places-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final reverseRequests = <Uri>[];
    final reverseTimes = <DateTime>[];
    final userAgents = <String>[];
    final service = testPlaceNames(
      dir: dir,
      reverseRequests: reverseRequests,
      reverseTimes: reverseTimes,
      userAgents: userAgents,
    );
    const springfield = LatLng(39.7817, -89.6501);
    expect(await service.lookup(springfield), 'Springfield, Illinois');
    expect(reverseRequests, hasLength(1));
    expect(userAgents, ['StoryCam/0.5.11 (app.storycam)']);
    // ~44 m away: no request, same label.
    expect(await service.lookup(const LatLng(39.7821, -89.6501)),
        'Springfield, Illinois');
    expect(reverseRequests, hasLength(1));
    // ~156 m away: a request fires, at least 1.1 s after the first.
    expect(await service.lookup(const LatLng(39.7831, -89.6501)),
        'Springfield, Illinois');
    expect(reverseRequests, hasLength(2));
    expect(reverseTimes[1].difference(reverseTimes[0]),
        greaterThanOrEqualTo(const Duration(milliseconds: 1100)));
  });

  test('PlaceNameService serves cache hits without a request, persistently',
      () async {
    final dir = Directory.systemTemp.createTempSync('storycam-47-places-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final reverseRequests = <Uri>[];
    final first = testPlaceNames(dir: dir, reverseRequests: reverseRequests);
    const springfield = LatLng(39.7817, -89.6501);
    expect(await first.lookup(springfield), 'Springfield, Illinois');
    expect(reverseRequests, hasLength(1));
    // Same rounded cell (4 decimals): cache hit, no request.
    expect(await first.lookup(const LatLng(39.78171, -89.65011)),
        'Springfield, Illinois');
    expect(reverseRequests, hasLength(1));
    // A fresh service on the same directory: the persistent cache
    // survives, no reverse request.
    final secondRequests = <Uri>[];
    final second =
        testPlaceNames(dir: dir, reverseRequests: secondRequests);
    expect(await second.lookup(springfield), 'Springfield, Illinois');
    expect(secondRequests, isEmpty);
  });

  test('PlaceNameService returns null on error and on timeout', () async {
    final dir = Directory.systemTemp.createTempSync('storycam-47-places-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final errorService = testPlaceNames(
        dir: dir, reverseRequests: [], reverseStatus: 500);
    expect(await errorService.lookup(const LatLng(39.7817, -89.6501)),
        isNull);

    final dir2 = Directory.systemTemp.createTempSync('storycam-47-places-');
    addTearDown(() => dir2.deleteSync(recursive: true));
    final slowService = testPlaceNames(
      dir: dir2,
      reverseRequests: [],
      reverseDelay: const Duration(milliseconds: 500),
      requestTimeout: const Duration(milliseconds: 100),
    );
    expect(await slowService.lookup(const LatLng(39.7817, -89.6501)),
        isNull);
  });

  test('PlaceNameService stays off for the session when the switch is off',
      () async {
    final dir = Directory.systemTemp.createTempSync('storycam-47-places-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final reverseRequests = <Uri>[];
    final switchRequests = <Uri>[];
    final service = testPlaceNames(
      dir: dir,
      reverseRequests: reverseRequests,
      switchRequests: switchRequests,
      switchEnabled: false,
    );
    expect(await service.lookup(const LatLng(39.7817, -89.6501)), isNull);
    expect(reverseRequests, isEmpty);
    // Second lookup, far away: still off, and the switch is NOT
    // re-fetched (the fetched-disabled verdict holds for the session).
    expect(await service.lookup(const LatLng(39.8000, -89.6501)), isNull);
    expect(reverseRequests, isEmpty);
    expect(switchRequests, hasLength(1));
  });

  test('PlaceNameService retries a failed switch fetch on a later attempt',
      () async {
    final dir = Directory.systemTemp.createTempSync('storycam-47-places-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final reverseRequests = <Uri>[];
    final switchRequests = <Uri>[];
    var switchFails = true;
    final service = testPlaceNames(
      dir: dir,
      reverseRequests: reverseRequests,
      switchRequests: switchRequests,
      switchFails: () => switchFails,
      switchRetryInterval: const Duration(milliseconds: 200),
    );
    // Fetch failed: no lookup on that attempt.
    expect(await service.lookup(const LatLng(39.7817, -89.6501)), isNull);
    expect(switchRequests, hasLength(1));
    expect(reverseRequests, isEmpty);
    // Immediate retry: the failed fetch is NOT repeated inside the
    // retry interval.
    expect(await service.lookup(const LatLng(39.8000, -89.6501)), isNull);
    expect(switchRequests, hasLength(1));
    expect(reverseRequests, isEmpty);
    // After the interval, the fetch is retried — and now succeeds.
    await Future.delayed(const Duration(milliseconds: 250));
    switchFails = false;
    expect(await service.lookup(const LatLng(39.7817, -89.6501)),
        'Springfield, Illinois');
    expect(switchRequests, hasLength(2));
    expect(reverseRequests, hasLength(1));
  });

  test('PlaceNameService evicts the oldest cache entry past 50', () async {
    final dir = Directory.systemTemp.createTempSync('storycam-47-places-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final reverseRequests = <Uri>[];
    final service = testPlaceNames(
      dir: dir,
      reverseRequests: reverseRequests,
      minRequestInterval: Duration.zero,
    );
    // 51 distinct positions, each ~222 m from the previous.
    for (var i = 0; i < 51; i++) {
      await service.lookup(LatLng(39.7817 + i * 0.002, -89.6501));
    }
    expect(reverseRequests, hasLength(51));
    // The first entry was evicted: looking it up again sends a request.
    reverseRequests.clear();
    await service.lookup(const LatLng(39.7817, -89.6501));
    expect(reverseRequests, hasLength(1));
    // The last entry is still cached: no request.
    reverseRequests.clear();
    await service.lookup(const LatLng(39.7817 + 50 * 0.002, -89.6501));
    expect(reverseRequests, isEmpty);
  });

  test('PlaceNameService formats locality fallbacks and display_name',
      () async {
    final dir = Directory.systemTemp.createTempSync('storycam-47-places-');
    addTearDown(() => dir.deleteSync(recursive: true));
    // Village fallback, country as region.
    final village = testPlaceNames(
      dir: dir,
      reverseRequests: [],
      reverseBody: (_) =>
          '{"address": {"village": "Krupki", "country": "Belarus"}}',
    );
    expect(await village.lookup(const LatLng(54.3, 29.1)), 'Krupki, Belarus');

    // Suburb fallback in the locality chain.
    final dir2 = Directory.systemTemp.createTempSync('storycam-47-places-');
    addTearDown(() => dir2.deleteSync(recursive: true));
    final suburb = testPlaceNames(
      dir: dir2,
      reverseRequests: [],
      reverseBody: (_) =>
          '{"address": {"suburb": "Kreuzberg", "state": "Berlin"}}',
    );
    expect(
        await suburb.lookup(const LatLng(52.5, 13.4)), 'Kreuzberg, Berlin');

    // No usable locality: display_name fallback drops the house number
    // and road segments.
    final dir3 = Directory.systemTemp.createTempSync('storycam-47-places-');
    addTearDown(() => dir3.deleteSync(recursive: true));
    final street = testPlaceNames(
      dir: dir3,
      reverseRequests: [],
      reverseBody: (_) =>
          '{"display_name": "12, Main Street, Springfield, Illinois, United States", '
              '"address": {}}',
    );
    expect(await street.lookup(const LatLng(39.7817, -89.6501)),
        'Springfield, Illinois');

    // Nothing usable at all: null, no label.
    final dir4 = Directory.systemTemp.createTempSync('storycam-47-places-');
    addTearDown(() => dir4.deleteSync(recursive: true));
    final empty = testPlaceNames(
      dir: dir4,
      reverseRequests: [],
      reverseBody: (_) => '{"address": {}}',
    );
    expect(await empty.lookup(const LatLng(0, 0)), isNull);
  });

  // Issue #50 helpers: one full recording with a real file on disk
  // (the camera fake returns '/tmp/story.mp4' from stopRecording, and
  // Open/Share/Delete all check the file exists). The thumbnail channel
  // (dual_cameras_example/thumbnail, native frame extraction) answers
  // with a 1x1 PNG, so the tile renders the real-frame path.
  Future<void> recordVideoWithFile(WidgetTester tester) async {
    File('/tmp/story.mp4').writeAsStringSync('fake-video');
    addTearDown(() {
      final file = File('/tmp/story.mp4');
      if (file.existsSync()) file.deleteSync();
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dual_cameras_example/thumbnail'),
            (call) async => base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='));
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dual_cameras_example/thumbnail'),
            null));
    await recordAndStop(tester);
  }

  /// Issue #50: mock the share channel (dual_cameras_example/share).
  /// [deleteResult] is the map every deleteVideo call answers with;
  /// [deleteResults] answers each deleteVideo call in order instead —
  /// for a twin delete where the original succeeds and the twin is
  /// cancelled. shareVideo answers null (success). Returns the recorded
  /// (method, arguments) calls.
  List<(String, Object?)> mockShareChannel(
      {Map<String, Object>? deleteResult,
      List<Map<String, Object>>? deleteResults}) {
    final calls = <(String, Object?)>[];
    var deleteCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dual_cameras_example/share'),
            (call) async {
      calls.add((call.method, call.arguments));
      if (call.method == 'deleteVideo') {
        final result = deleteResults != null
            ? deleteResults[deleteCalls]
            : deleteResult;
        deleteCalls++;
        return result;
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dual_cameras_example/share'), null));
    return calls;
  }

  /// Issue #50: record a video, then tap the thumbnail so the popup
  /// menu opens. Returns after the menu has settled, with all three
  /// items present.
  Future<void> openLastVideoMenu(WidgetTester tester) async {
    await recordVideoWithFile(tester);
    expect(find.byKey(const Key('share-button')), findsNothing);
    expect(find.byKey(const Key('last-video-thumbnail')), findsOneWidget);
    await tester.tap(find.byKey(const Key('last-video-thumbnail')));
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    expect(find.byKey(const Key('last-video-menu-open')), findsOneWidget);
    expect(
        find.byKey(const Key('last-video-menu-delete')), findsOneWidget);
    expect(find.byKey(const Key('last-video-menu-share')), findsOneWidget);
  }

  testWidgets('last-video thumbnail opens the menu and Open plays the video',
      (tester) async {
    final player = FakeVideoPlayerPlatform();
    final previousPlayer = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = player;
    addTearDown(() => VideoPlayerPlatform.instance = previousPlayer);
    final captions = FakeCaptionJobNotifier();
    await openCamera(tester, captions: captions);
    await openLastVideoMenu(tester);
    // Real-frame tile: the mocked thumbnail bytes render as an Image.
    expect(
        find.descendant(
            of: find.byKey(const Key('last-video-thumbnail')),
            matching: find.byType(Image)),
        findsOneWidget);
    await tester.tap(find.byKey(const Key('last-video-menu-open')));
    await tester.pumpAndSettle();
    // Player route: autoplayed, close button present, camera tile gone.
    expect(find.byKey(const Key('player-close')), findsOneWidget);
    expect(player.playCalls, 1);
    expect(find.byKey(const Key('last-video-thumbnail')), findsNothing);
    await tester.tap(find.byKey(const Key('player-close')));
    await tester.pumpAndSettle();
    // The page disposes the controller in an unawaited future whose
    // subscription-cancel step needs a real event-loop turn — flush it
    // with runAsync before counting.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    expect(find.byKey(const Key('player-close')), findsNothing);
    expect(find.byKey(const Key('last-video-thumbnail')), findsOneWidget);
    expect(player.disposeCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('last-video menu Share opens the share sheet with the file',
      (tester) async {
    final shareCalls = mockShareChannel();
    await openCamera(tester);
    await openLastVideoMenu(tester);
    await tester.tap(find.byKey(const Key('last-video-menu-share')));
    await tester.pumpAndSettle();
    expect(shareCalls.length, 1);
    expect(shareCalls.single.$1, 'shareVideo');
    expect((shareCalls.single.$2 as Map)['path'], '/tmp/story.mp4');
    expect(find.text('Video saved to gallery'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('last-video menu Delete removes the video and the thumbnail',
      (tester) async {
    final shareCalls = mockShareChannel(deleteResult: {
      'cacheDeleted': true,
      'galleryDeleted': true,
      'cancelled': false,
    });
    final captions = FakeCaptionJobNotifier();
    await openCamera(tester, captions: captions);
    await openLastVideoMenu(tester);
    // initState already cleared the notifier once (stale-notification
    // cleanup); Delete's job stop must add exactly one more.
    final clearsBeforeDelete = captions.clearCalls;
    await tester.tap(find.byKey(const Key('last-video-menu-delete')));
    await tester.pumpAndSettle();
    expect(shareCalls.length, 1);
    expect(shareCalls.single.$1, 'deleteVideo');
    expect((shareCalls.single.$2 as Map)['path'], '/tmp/story.mp4');
    // Delete stops the in-flight caption job first.
    expect(captions.clearCalls, clearsBeforeDelete + 1);
    expect(find.text('Video deleted.'), findsOneWidget);
    expect(find.byKey(const Key('last-video-thumbnail')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('last-video menu Delete cancelled keeps the video',
      (tester) async {
    mockShareChannel(deleteResult: {
      'cacheDeleted': false,
      'galleryDeleted': false,
      'cancelled': true,
    });
    final captions = FakeCaptionJobNotifier();
    await openCamera(tester, captions: captions);
    await openLastVideoMenu(tester);
    await tester.tap(find.byKey(const Key('last-video-menu-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Video kept.'), findsOneWidget);
    expect(find.byKey(const Key('last-video-thumbnail')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'last-video menu Delete with the twin cancelled deletes the original only',
      (tester) async {
    // F2: the original's delete succeeds and the twin's is cancelled —
    // the status must not claim the video is kept, and the thumbnail
    // must go away with the deleted original.
    final shareCalls = mockShareChannel(deleteResults: [
      {
        'cacheDeleted': true,
        'galleryDeleted': true,
        'cancelled': false,
      },
      {
        'cacheDeleted': false,
        'galleryDeleted': false,
        'cancelled': true,
      },
    ]);
    final captions = FakeCaptionJobNotifier();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dual_cameras_example/captions'),
            (call) async {
      if (call.method == 'extractAudio') return '/tmp/audio.wav';
      if (call.method == 'burnCaptions') return '/tmp/story-captioned.mp4';
      throw StateError('unexpected ${call.method}');
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dual_cameras_example/captions'), null));
    await openCamera(tester,
        captions: captions, transcriber: FakeTranscriber());
    // Auto-captions on, as in the caption-job tests.
    await tester.ensureVisible(find.byKey(const Key('menu-captions')));
    await tester.tap(find.byKey(const Key('menu-captions')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, 'Auto-captions'));
    await tester.tap(find.byTooltip('Close Camera settings'));
    await tester.pumpAndSettle();
    await recordVideoWithFile(tester);
    // The caption job finishes in the background: the twin exists once
    // the notifier reports done.
    for (var i = 0; captions.done.isEmpty && i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(captions.done, isNotEmpty);
    expect(find.byKey(const Key('last-video-thumbnail')), findsOneWidget);
    await tester.tap(find.byKey(const Key('last-video-thumbnail')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('last-video-menu-delete')));
    await tester.pumpAndSettle();
    expect(shareCalls.length, 2);
    expect((shareCalls[0].$2 as Map)['path'], '/tmp/story.mp4');
    expect(
        (shareCalls[1].$2 as Map)['path'], '/tmp/story-captioned.mp4');
    expect(find.text('Video deleted, captioned copy kept.'), findsOneWidget);
    expect(find.text('Video kept.'), findsNothing);
    expect(find.byKey(const Key('last-video-thumbnail')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'last-video menu Delete with the twin delete failing on iOS deletes the original only (issue #56)',
      (tester) async {
    // Issue #56, iOS analog of the F2 leg above: the original's delete
    // succeeds and the twin's throws — the status must not claim total
    // failure, and the thumbnail must go away with the deleted original.
    // The routing seam (defaultTargetPlatform) drives the iOS leg on
    // the Linux test host; the deleteFile seam forces the twin throw,
    // which the filesystem cannot (the host runs as root).
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final deleteCalls = <String>[];
    Future<void> deleteFile(File file) async {
      deleteCalls.add(file.path);
      if (file.path == '/tmp/story-captioned.mp4') {
        throw const FileSystemException('Simulated twin delete failure',
            '/tmp/story-captioned.mp4');
      }
      await file.delete();
    }

    final captions = FakeCaptionJobNotifier();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dual_cameras_example/captions'),
            (call) async {
      if (call.method == 'extractAudio') return '/tmp/audio.wav';
      if (call.method == 'burnCaptions') return '/tmp/story-captioned.mp4';
      throw StateError('unexpected ${call.method}');
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dual_cameras_example/captions'), null));
    // The iOS leg only deletes files that exist, so the twin must be a
    // real file on disk for the throw to be reached.
    File('/tmp/story-captioned.mp4').writeAsStringSync('fake-captioned');
    addTearDown(() {
      final twin = File('/tmp/story-captioned.mp4');
      if (twin.existsSync()) twin.deleteSync();
    });
    await openCamera(tester,
        captions: captions,
        transcriber: FakeTranscriber(),
        deleteFile: deleteFile);
    // Auto-captions on, as in the caption-job tests.
    await tester.ensureVisible(find.byKey(const Key('menu-captions')));
    await tester.tap(find.byKey(const Key('menu-captions')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, 'Auto-captions'));
    await tester.tap(find.byTooltip('Close Camera settings'));
    await tester.pumpAndSettle();
    await recordVideoWithFile(tester);
    // The caption job finishes in the background: the twin exists once
    // the notifier reports done.
    for (var i = 0; captions.done.isEmpty && i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(captions.done, isNotEmpty);
    expect(find.byKey(const Key('last-video-thumbnail')), findsOneWidget);
    await tester.tap(find.byKey(const Key('last-video-thumbnail')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('last-video-menu-delete')));
    // The iOS leg does real dart:io file I/O, which only completes on
    // the real event loop — flush it with runAsync turns until both
    // deletes have been attempted, then settle.
    for (var i = 0; deleteCalls.length < 2 && i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    // Reset inline, not only in tearDown: flutter_test verifies all
    // foundation debug variables are unset at the end of the test body,
    // before tearDowns run — restoring only in tearDown fails that check.
    debugDefaultTargetPlatformOverride = null;
    expect(deleteCalls, ['/tmp/story.mp4', '/tmp/story-captioned.mp4']);
    expect(File('/tmp/story.mp4').existsSync(), isFalse);
    expect(File('/tmp/story-captioned.mp4').existsSync(), isTrue);
    expect(find.text('Video deleted, captioned copy kept.'), findsOneWidget);
    expect(find.text('Video kept.'), findsNothing);
    expect(find.text('Could not delete video. See settings for details.'),
        findsNothing);
    expect(find.byKey(const Key('last-video-thumbnail')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'map-only burn runs with captions off and takes the map twin, never the caption label (issue #49)',
      (tester) async {
    // Captions off (default), map on (default) with location granted:
    // the take burns map-only — no transcription, words = [], the
    // manifest carries snapshots, and the output is the map twin.
    final shareCalls = mockShareChannel(deleteResults: [
      {
        'cacheDeleted': true,
        'galleryDeleted': true,
        'cancelled': false,
      },
      {
        'cacheDeleted': false,
        'galleryDeleted': false,
        'cancelled': true,
      },
    ]);
    // getTemporaryDirectory is unmocked in setUp (null reply) — the
    // snapshot capture needs a real temp dir in tests.
    final tempDir = Directory.systemTemp.createTempSync('storycam-map-');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async {
      if (call.method == 'getTemporaryDirectory') return tempDir.path;
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null));
    Map<String, Object?>? burnArgs;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dual_cameras_example/captions'),
            (call) async {
      if (call.method == 'burnCaptions') {
        burnArgs = (call.arguments as Map<Object?, Object?>)
            .cast<String, Object?>();
        return '/tmp/story-map.mp4';
      }
      // extractAudio must never run on the map-only pass (C2:
      // transcription is skipped entirely when captions are off).
      throw StateError('unexpected ${call.method}');
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dual_cameras_example/captions'), null));
    final captions = FakeCaptionJobNotifier();
    await openCamera(tester,
        captions: captions,
        mapLocationService: FakeMapLocationService());
    // The map circle must be on screen for the snapshot tick to capture.
    expect(find.byKey(const Key('map-circle')), findsOneWidget);
    // Fake video file + thumbnail mock (as recordVideoWithFile does),
    // but the take is started and stopped manually: snapshot capture is
    // real async I/O (temp dir + boundary render + PNG write), so the
    // take must live until the first snapshot lands — recordAndStop's
    // ~12 ms take ends before the capture even starts.
    File('/tmp/story.mp4').writeAsStringSync('fake-video');
    addTearDown(() {
      final file = File('/tmp/story.mp4');
      if (file.existsSync()) file.deleteSync();
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dual_cameras_example/thumbnail'),
            (call) async => base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='));
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dual_cameras_example/thumbnail'), null));
    await tester.tap(find.byTooltip('Start recording'));
    await tester.pumpAndSettle();
    // Wait for the first snapshot to be fully written, not just
    // created: writeAsBytes creates the file (0 bytes) before the bytes
    // land, and the snapshot's bookkeeping (captured++ + track add)
    // runs only after the write future completes — sighting a 0-byte
    // file and stopping at once orphans it (STOP FLUSH TIMEOUT, then
    // SNAPSHOT STALE after-write). Require size > 0 and unchanged
    // across two checks 200 ms apart, then drain real async once more.
    var snapshotBytes = 0;
    var snapshotStable = false;
    for (var i = 0; !snapshotStable && i < 50; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      final files = tempDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.contains('map_') && f.path.endsWith('.png'))
          .toList();
      final bytes = files.isEmpty ? 0 : files.first.lengthSync();
      if (bytes > 0 && bytes == snapshotBytes) {
        snapshotStable = true;
      }
      snapshotBytes = bytes;
    }
    expect(snapshotBytes, greaterThan(0));
    expect(snapshotStable, isTrue);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    await tester.tap(find.byTooltip('Stop recording'));
    await tester.pumpAndSettle();
    // The burn finishes in the background: the map notifier reports done.
    // Snapshot capture does real dart:io I/O — flush it with runAsync
    // turns (same pattern as the iOS twin test above).
    for (var i = 0; captions.mapDoneCalls == 0 && i < 50; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(captions.mapDoneCalls, 1);
    expect(captions.mapFailed, isEmpty);
    // N-G: no caption label anywhere — no captions were burned.
    expect(captions.done, isEmpty);
    expect(captions.progresses, isEmpty);
    expect(burnArgs, isNotNull);
    expect(burnArgs!['words'], '[]');
    final manifest = burnArgs!['mapManifest'] as String;
    expect(manifest, contains('map_'));
    expect(manifest, contains('"mapVisible":true'));
    // Delete: the map burn is the twin — the original goes, the map copy
    // is cancelled, and the status names the map copy, not a caption.
    expect(find.byKey(const Key('last-video-thumbnail')), findsOneWidget);
    await tester.tap(find.byKey(const Key('last-video-thumbnail')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('last-video-menu-delete')));
    await tester.pumpAndSettle();
    expect(shareCalls.length, 2);
    expect((shareCalls[0].$2 as Map)['path'], '/tmp/story.mp4');
    expect((shareCalls[1].$2 as Map)['path'], '/tmp/story-map.mp4');
    expect(find.text('Video deleted, map copy kept.'), findsOneWidget);
    expect(find.text('Video deleted, captioned copy kept.'), findsNothing);
    expect(find.byKey(const Key('last-video-thumbnail')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('record row fits a 320dp screen without overlap (issue #50)',
      (tester) async {
    // A-F4: per-edge placement on a 320dp screen — left cluster ends at
    // 116dp, centred capture spans 120-200dp (4dp clear), swap starts
    // at 272dp. The binding bound is W >= 312dp, not the 244dp total.
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await openCamera(tester);
    await recordVideoWithFile(tester);
    final thumb =
        tester.getRect(find.byKey(const Key('last-video-thumbnail')));
    final photo = tester.getRect(find.byTooltip('Take photo'));
    final capture = tester.getRect(find.byKey(const Key('capture-control')));
    final swap = tester.getRect(find.byTooltip('Swap cameras'));
    expect(thumb.left, 0);
    expect(thumb.width, 56);
    expect(photo.left, 68);
    expect(photo.right, 116);
    expect(capture.left, 120);
    expect(capture.right, 200);
    expect(swap.left, 272);
    expect(swap.right, 320);
    expect(photo.right, lessThanOrEqualTo(capture.left));
    expect(capture.right, lessThanOrEqualTo(swap.left));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'open with no player reports the failure and keeps the thumbnail',
      (tester) async {
    await openCamera(tester);
    await openLastVideoMenu(tester);
    await tester.tap(find.byKey(const Key('last-video-menu-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('player-close')), findsNothing);
    expect(find.text('Could not play video. See settings for details.'),
        findsOneWidget);
    expect(find.byKey(const Key('last-video-thumbnail')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
