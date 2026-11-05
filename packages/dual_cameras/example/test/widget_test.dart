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
    await tester.pumpWidget(DemoApp(modelManager: model, backgroundCaptions: false));
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
    await tester.pumpWidget(DemoApp(modelManager: model, backgroundCaptions: false));
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
    await tester.tap(find.byTooltip('Start recording'));
    await tester.pump();
    expect(fake.starts, 2); // Model preparation must not block the next clip.
    model.gate!.completeError(Exception('Download interrupted'));
    await tester.pumpAndSettle();
    expect(find.textContaining('plain video kept'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(galleryCalls.where((call) => call == 'putVideo').length, 1);
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
    await tester.ensureVisible(find.text('Captions off'));
    await tester.tap(find.text('Captions off'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.tap(find.byTooltip('Close Captions'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Open camera'));
    await tester.tap(find.byTooltip('Open camera'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Start recording'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Stop recording'));
    await tester.pumpAndSettle();
    expect(model.calls, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(fake.disposals, 1);
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
    fake.stopFiles.addAll(['/tmp/first.mp4', '/tmp/second.mp4']);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dual_cameras_example/captions'), (call) async {
      final source = call.arguments['mp4'] as String;
      extracted.add(source);
      if (source == '/tmp/first.mp4') return firstExtraction.future;
      throw StateError('No audio');
    });
    await openCamera(tester);
    await tester.ensureVisible(find.text('Captions off'));
    await tester.tap(find.text('Captions off'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.tap(find.byTooltip('Close Captions'));
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
    expect(find.textContaining('plain video kept'), findsOneWidget);
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
    await tester.tap(find.byTooltip('Start recording'));
    await tester.pumpAndSettle();
    expect(fake.starts, 2);
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

  testWidgets('exposure applies while dragging and coalesces pending values',
      (tester) async {
    await openCamera(tester);
    await tester.tap(find.byTooltip('Camera settings'));
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
