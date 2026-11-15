import 'package:flutter/widgets.dart';

import '../analytics.dart';
import 'background_transcriber.dart';
import 'caption_jobs.dart';
import 'caption_pipeline.dart';
import 'model_manager.dart';

/// Invoked by the Android worker's headless Flutter engine, not by a screen.
///
/// The optional [models], [transcriber] and [pipeline] parameters exist
/// only for tests: the real transcriber spawns a sherpa-onnx isolate that
/// can never run under `flutter test`, so tests pass fakes returning a
/// fixed [TranscriptionResult] and burn output path. Production callers
/// pass nothing and get the real objects.
Future<void> runCaptionJob({
  ModelManager? models,
  BackgroundTranscriber? transcriber,
  CaptionPipeline? pipeline,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  // The background isolate has its own Dart statics, so the main
  // isolate's init does not carry over — init here. With no key this is
  // a no-op (same contract as the foreground path): no init, no network,
  // no event. A failing init leaves the job unaffected.
  await Analytics.init();
  const channel = CaptionJobs.channel;
  final modelManager = models ?? ModelManager();
  final backgroundTranscriber = transcriber ?? BackgroundTranscriber();
  final captionPipeline = pipeline ?? CaptionPipeline();
  var cancelled = false;
  var lastProgress = -1;
  void checkCancelled() {
    if (cancelled) throw StateError('Caption job stopped');
  }

  Future<void> progress(String stage, int value) async {
    if (cancelled || value == lastProgress) return;
    lastProgress = value;
    await channel
        .invokeMethod<void>('progress', {'stage': stage, 'progress': value});
  }

  channel.setMethodCallHandler((call) async {
    if (call.method == 'cancel') {
      cancelled = true;
      modelManager.cancel();
      backgroundTranscriber.cancel();
    }
  });
  try {
    final args = await channel.invokeMapMethod<String, Object?>('ready');
    if (args == null) throw StateError('Missing caption job input');
    cancelled = cancelled || args['cancelled'] == true;
    checkCancelled();
    final mp4 = args['mp4'] as String;
    // The caption language chosen when the job was enqueued ('' = Auto).
    // The native side stores it with the job; a missing key means Auto.
    final language = args['language'] as String? ?? '';
    await progress('Preparing speech model', 0);
    final model = await modelManager.ensureModel(onProgress: (value) {
      // Native handler persists and throttles these whole-percentage updates.
      progress('Downloading speech model', (value * 25).floor());
    });
    checkCancelled();
    await progress('Extracting audio', 25);
    final wav = await captionPipeline.extractAudio(mp4);
    checkCancelled();
    await progress('Transcribing on device', 35);
    final result = await backgroundTranscriber.transcribe(
        wavPath: wav,
        model: model,
        language: language,
        onProgress: (value) =>
            progress('Transcribing on device', 35 + (value * 40).floor()));
    final words = result.words;
    checkCancelled();
    if (words.isEmpty) {
      await channel
          .invokeMethod<void>('complete', {'path': mp4, 'noSpeech': true});
    } else {
      await progress('Adding captions to video', 75);
      final output =
          await captionPipeline.burnCaptions(mp4Path: mp4, words: words);
      checkCancelled();
      // Analytics is belt-and-braces: its own try/catch, so an event
      // failure can never flip a completed job to 'failed'. No event on
      // the noSpeech path above (foreground parity).
      try {
        Analytics.captionsDone(
          wordCount: words.length,
          language: result.detectedLanguage,
          captionLanguage: language,
          job: 'background',
        );
        // Best effort: flush the queued event before `complete`, the
        // terminal signal after which the engine may tear down.
        await Analytics.flush();
      } catch (e) {
        debugPrint('StoryCam: background captions analytics failed: $e');
      }
      await channel
          .invokeMethod<void>('complete', {'path': output, 'noSpeech': false});
    }
  } catch (error) {
    await channel.invokeMethod<void>(
        cancelled ? 'cancelled' : 'failed', {'error': '$error'});
  } finally {
    channel.setMethodCallHandler(null);
  }
}
