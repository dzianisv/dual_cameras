import 'package:flutter/widgets.dart';

import 'background_transcriber.dart';
import 'caption_jobs.dart';
import 'caption_pipeline.dart';
import 'model_manager.dart';

/// Invoked by the Android worker's headless Flutter engine, not by a screen.
Future<void> runCaptionJob() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = CaptionJobs.channel;
  final models = ModelManager();
  final transcriber = BackgroundTranscriber();
  final pipeline = CaptionPipeline();
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
      models.cancel();
      transcriber.cancel();
    }
  });
  try {
    final args = await channel.invokeMapMethod<String, Object?>('ready');
    if (args == null) throw StateError('Missing caption job input');
    cancelled = cancelled || args['cancelled'] == true;
    checkCancelled();
    final mp4 = args['mp4'] as String;
    await progress('Preparing speech model', 0);
    final model = await models.ensureModel(onProgress: (value) {
      // Native handler persists and throttles these whole-percentage updates.
      progress('Downloading speech model', (value * 25).floor());
    });
    checkCancelled();
    await progress('Extracting audio', 25);
    final wav = await pipeline.extractAudio(mp4);
    checkCancelled();
    await progress('Transcribing on device', 35);
    final words = await transcriber.transcribe(
        wavPath: wav,
        model: model,
        onProgress: (value) =>
            progress('Transcribing on device', 35 + (value * 40).floor()));
    checkCancelled();
    if (words.isEmpty) {
      await channel
          .invokeMethod<void>('complete', {'path': mp4, 'noSpeech': true});
    } else {
      await progress('Adding captions to video', 75);
      final output = await pipeline.burnCaptions(mp4Path: mp4, words: words);
      checkCancelled();
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
