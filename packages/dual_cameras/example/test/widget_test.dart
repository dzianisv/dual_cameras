import 'dart:async';
import 'dart:ui' as ui;

import 'package:dual_cameras_example/main.dart';
import 'package:dual_cameras_example/captions/model_manager.dart';
import 'package:dual_cameras_example/captions/caption_models.dart';
import 'package:dual_cameras_platform_interface/dual_cameras_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class FakeModelManager extends ModelManager {
  int calls = 0;
  bool fail = false;
  Completer<WhisperModelFiles>? gate;
  void Function(double)? progress;
  static const files = WhisperModelFiles(
      encoder: 'encoder', decoder: 'decoder', tokens: 'tokens');
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
}

class FakeCamera extends DualCamerasPlatform with MockPlatformInterfaceMixin {
  final eventController = StreamController<DualCameraEvent>.broadcast();
  bool supported = true;
  int starts = 0, stops = 0, photos = 0, disposals = 0;
  VideoFilter filter = VideoFilter.none;
  Completer<void>? startGate;
  Completer<InitResult>? initGate;
  Completer<CameraCapabilities>? probeGate;

  @override
  Stream<DualCameraEvent> get events => eventController.stream;
  @override
  Future<CameraCapabilities> probeSupport() async => probeGate == null
      ? CameraCapabilities(isSupported: supported)
      : probeGate!.future;
  @override
  Future<InitResult> initialize(RecordingConfig config) async =>
      initGate == null
          ? InitResult(
              textureId: 42,
              capabilities: CameraCapabilities(isSupported: true))
          : initGate!.future;
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
    return '/tmp/story.mp4';
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

  @override
  Future<void> swapPrimary() async {}
  @override
  Future<void> setLayout(LayoutConfig config) async {}
  @override
  Future<void> dispose() async {
    disposals++;
  }
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

  Future<void> openCamera(WidgetTester tester) async {
    await tester.pumpWidget(DemoApp(modelManager: model));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open camera'));
    await tester.pumpAndSettle();
    expect(find.text('Ready to tell your story'), findsOneWidget);
  }

  Future<void> showControl(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('startup model progress and retry do not block camera capture',
      (tester) async {
    model.fail = true;
    await openCamera(tester);
    expect(
        find.textContaining('Caption model download failed'), findsOneWidget);
    model.fail = false;
    model.gate = Completer<WhisperModelFiles>();
    await tester.tap(find.text('Retry'));
    await tester.pump();
    model.progress!(.42);
    await tester.pump();
    expect(find.textContaining('Preparing captions · 42%'), findsOneWidget);
    await tester.tap(find.byTooltip('Start recording'));
    await tester.pump();
    expect(fake.starts, 1);
    expect(model.calls, 2);
    model.gate!.complete(FakeModelManager.files);
    await tester.pumpAndSettle();
    expect(find.text('Captions ready · on device'), findsOneWidget);
  });

  testWidgets(
      'captions await startup download once and keep saved original on failure',
      (tester) async {
    model.gate = Completer<WhisperModelFiles>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dual_cameras_example/captions'),
            (call) async => '/tmp/audio.wav');
    await tester.pumpWidget(DemoApp(modelManager: model));
    await tester.pump();
    await tester.ensureVisible(find.text('Captions off'));
    await tester.tap(find.text('Captions off'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    await tester.tap(find.byTooltip('Close Captions'));
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
    model.gate!.completeError(Exception('Download interrupted'));
    await tester.pumpAndSettle();
    expect(find.textContaining('plain video kept'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(galleryCalls.where((call) => call == 'putVideo').length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late model completion after disposal is safe', (tester) async {
    model.gate = Completer<WhisperModelFiles>();
    await tester.pumpWidget(DemoApp(modelManager: model));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    model.progress!(.7);
    model.gate!.complete(FakeModelManager.files);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsupported device keeps capture disabled', (tester) async {
    fake.supported = false;
    await tester.pumpWidget(DemoApp(modelManager: model));
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
    await tester.pumpWidget(DemoApp(modelManager: model));
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
        isNull);
    await tester.tap(find.byTooltip('Stop recording'));
    await tester.pumpAndSettle();
    expect(fake.stops, 1);
    expect(galleryCalls.where((call) => call == 'putVideo').length, 1);
    expect(find.text('Video saved to gallery'), findsOneWidget);
    expect(find.textContaining('/tmp/'), findsNothing);
  });

  testWidgets('filters, captions, settings close and back retain state',
      (tester) async {
    await openCamera(tester);
    final filters = find.text('Filters · Original');
    await showControl(tester, filters);
    await tester.tap(filters);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Moody'));
    await tester.pumpAndSettle();
    expect(fake.filter, VideoFilter.moody);
    await tester.tap(find.byTooltip('Close Filters'));
    await tester.pumpAndSettle();
    final captions = find.text('Captions off');
    await showControl(tester, captions);
    await tester.tap(captions);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Captions on'), findsOneWidget);
    await tester.tap(find.byTooltip('Camera settings'));
    await tester.pumpAndSettle();
    expect(find.text('Exposure'), findsOneWidget);
    expect(find.text('Debug tuning'), findsOneWidget);
    await tester.tap(find.byTooltip('Close Camera settings'));
    await tester.pumpAndSettle();
    expect(find.text('Debug tuning'), findsNothing);
    expect(find.text('Filters · Moody'), findsOneWidget);
  });

  testWidgets('pending initialization finishes before session disposal',
      (tester) async {
    fake.initGate = Completer<InitResult>();
    await tester.pumpWidget(DemoApp(modelManager: model));
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
    await tester.pumpWidget(DemoApp(modelManager: model));
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
        await tester.scrollUntilVisible(find.text('Exposure'), 100,
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
}
