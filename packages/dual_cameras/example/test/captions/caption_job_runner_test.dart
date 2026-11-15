import 'package:dual_cameras_example/analytics.dart';
import 'package:dual_cameras_example/captions/background_transcriber.dart';
import 'package:dual_cameras_example/captions/caption_job_runner.dart';
import 'package:dual_cameras_example/captions/caption_jobs.dart';
import 'package:dual_cameras_example/captions/caption_models.dart';
import 'package:dual_cameras_example/captions/caption_pipeline.dart';
import 'package:dual_cameras_example/captions/model_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Fakes for the FFI/native boundary only (see the mock-test exception
// recorded on issue #41): the real transcriber spawns a sherpa-onnx
// isolate that can never run under `flutter test`, and the pipeline
// calls native code. The fakes stand in for that boundary; the test
// still exercises the real `runCaptionJob` orchestration and the real
// `Analytics.capture` path with an injected sink.
class FakeModelManager extends ModelManager {
  @override
  Future<WhisperModelFiles> ensureModel({
    required void Function(double progress) onProgress,
  }) async {
    onProgress(1);
    return const WhisperModelFiles(
      encoder: 'encoder',
      decoder: 'decoder',
      tokens: 'tokens',
      vad: 'vad',
    );
  }

  @override
  void cancel() {}
}

class FakeTranscriber extends BackgroundTranscriber {
  FakeTranscriber({
    this.words = const [
      CaptionWord(text: 'hello', start: 0, end: 0.5),
      CaptionWord(text: 'world', start: 0.5, end: 1),
    ],
    this.detectedLanguage = 'en',
  });

  final List<CaptionWord> words;
  final String detectedLanguage;

  @override
  Future<TranscriptionResult> transcribe({
    required String wavPath,
    required WhisperModelFiles model,
    required void Function(double) onProgress,
    String language = '',
  }) async {
    onProgress(1);
    return TranscriptionResult(
      words: words,
      detectedLanguage: detectedLanguage,
      timingsValid: true,
    );
  }

  @override
  void cancel() {}
}

class FakePipeline extends CaptionPipeline {
  @override
  Future<String> extractAudio(String mp4Path) async => '/tmp/fake.wav';

  @override
  Future<String> burnCaptions({
    required String mp4Path,
    required List<CaptionWord> words,
    MapBurnManifest? mapManifest,
  }) async =>
      '/tmp/fake-captioned.mp4';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Mirrors test/analytics_test.dart: injected no-op initializer + capture
  // sink, no key, no network. `flutter test` runs without
  // --dart-define POSTHOG_API_KEY, so the no-key test sees the real empty
  // key and the gating logic is genuinely exercised.
  const testKey = 'phc_test_analytics_key';
  late List<(String, Map<String, Object>)> seen;

  setUp(() {
    Analytics.resetForTest();
    seen = [];
  });

  tearDown(() {
    Analytics.resetForTest();
  });

  Future<void> initAnalyticsForTest({
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
    );
  }

  /// Mock `caption_jobs` channel answering `ready` with a Russian job,
  /// recording every call. Returns the recorded calls.
  List<MethodCall> installChannelMock() {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(CaptionJobs.channel, (call) async {
      calls.add(call);
      if (call.method == 'ready') {
        return {'mp4': '/tmp/story.mp4', 'language': 'ru', 'cancelled': false};
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(CaptionJobs.channel, null));
    return calls;
  }

  Future<List<MethodCall>> runFakeJob({
    BackgroundTranscriber? transcriber,
  }) async {
    final calls = installChannelMock();
    await runCaptionJob(
      models: FakeModelManager(),
      transcriber: transcriber ?? FakeTranscriber(),
      pipeline: FakePipeline(),
    );
    return calls;
  }

  test('Stop before ready acknowledges cancellation without preparing a model',
      () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(CaptionJobs.channel, (call) async {
      calls.add(call);
      if (call.method == 'ready') return {'cancelled': true};
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(CaptionJobs.channel, null));

    await runCaptionJob();

    expect(calls.map((call) => call.method), ['ready', 'cancelled']);
  });

  test('background job emits exactly one captions_done with a key', () async {
    await initAnalyticsForTest();
    final calls = await runFakeJob();

    final done =
        seen.where((event) => event.$1 == 'captions_done').toList();
    expect(done, hasLength(1));
    expect(done.single.$2['word_count'], 2);
    expect(done.single.$2['language'], 'en');
    expect(done.single.$2['caption_language'], 'ru');
    expect(done.single.$2['job'], 'background');
    expect(done.single.$2['app_version'], '0.5.10+15');
    expect(done.single.$2['install_source'], 'unknown');
    // The job itself completed normally.
    expect(calls.last.method, 'complete');
    expect(calls.last.arguments['path'], '/tmp/fake-captioned.mp4');
    expect(calls.last.arguments['noSpeech'], isFalse);
  });

  test('background job emits nothing without a key', () async {
    // No Analytics.init with a key: runCaptionJob's own init() sees the
    // empty --dart-define and stays off.
    final calls = await runFakeJob();

    expect(Analytics.isInitialized, isFalse);
    expect(seen, isEmpty);
    expect(calls.last.method, 'complete');
    expect(calls.last.arguments['noSpeech'], isFalse);
  });

  test('noSpeech job emits no captions_done', () async {
    await initAnalyticsForTest();
    final calls = await runFakeJob(
      transcriber: FakeTranscriber(words: const [], detectedLanguage: ''),
    );

    expect(
      seen.where((event) => event.$1 == 'captions_done'),
      isEmpty,
    );
    expect(calls.last.method, 'complete');
    expect(calls.last.arguments['path'], '/tmp/story.mp4');
    expect(calls.last.arguments['noSpeech'], isTrue);
  });

  test('analytics failure does not break the job', () async {
    // Throwing initializer: init stays off, the job still completes.
    await Analytics.init(
      apiKeyOverride: testKey,
      initializer: (_) async {
        throw Exception('PostHog unreachable');
      },
      captureSink: (event, properties) => seen.add((event, properties)),
    );
    expect(Analytics.isInitialized, isFalse);
    var calls = await runFakeJob();
    expect(calls.last.method, 'complete');
    expect(calls.last.arguments['noSpeech'], isFalse);
    expect(seen, isEmpty);

    // Throwing capture sink: the event is dropped, the job still completes.
    Analytics.resetForTest();
    await initAnalyticsForTest(
      sink: (_, __) {
        throw Exception('transport down');
      },
    );
    expect(Analytics.isInitialized, isTrue);
    calls = await runFakeJob();
    expect(calls.last.method, 'complete');
    expect(calls.last.arguments['noSpeech'], isFalse);
  });
}
