import 'dart:convert';

import 'package:flutter/services.dart';

import 'caption_models.dart';

/// Platform-channel bridge to the example app's native captions post-processing
/// (audio extraction + caption burn-in). Everything runs on-device.
class CaptionPipeline {
  static const MethodChannel _channel =
      MethodChannel('dual_cameras_example/captions');

  /// Extract the mp4's audio track to a 16 kHz mono WAV for the transcriber.
  /// Returns the WAV path.
  Future<String> extractAudio(String mp4Path) async {
    final wav = await _channel.invokeMethod<String>(
      'extractAudio',
      {'mp4': mp4Path},
    );
    if (wav == null || wav.isEmpty) {
      throw StateError('extractAudio returned no path');
    }
    return wav;
  }

  /// Burn karaoke word-highlight captions into a copy of the mp4.
  /// Returns the captioned mp4 path. The original file is left untouched.
  Future<String> burnCaptions({
    required String mp4Path,
    required List<CaptionWord> words,
  }) async {
    final wordsJson = jsonEncode(words.map((w) => w.toJson()).toList());
    final out = await _channel.invokeMethod<String>(
      'burnCaptions',
      {'mp4': mp4Path, 'words': wordsJson},
    );
    if (out == null || out.isEmpty) {
      throw StateError('burnCaptions returned no path');
    }
    return out;
  }
}
