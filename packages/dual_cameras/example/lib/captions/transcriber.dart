import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'caption_models.dart';
import 'word_aggregator.dart';

/// On-device speech-to-text via sherpa-onnx (Whisper base.en int8) with
/// token-level timestamps aggregated to word timings for karaoke captions.
/// Nothing leaves the phone.
class Transcriber {
  /// Transcribe a 16 kHz mono WAV; returns word-level timings.
  /// Runs synchronously on the calling isolate (alpha-grade); callers should
  /// paint a "Transcribing…" state first and yield a frame.
  Future<List<CaptionWord>> transcribe({
    required String wavPath,
    required WhisperModelFiles model,
  }) async {
    sherpa.initBindings();

    final config = sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        whisper: sherpa.OfflineWhisperModelConfig(
          encoder: model.encoder,
          decoder: model.decoder,
          language: 'en',
          task: 'transcribe',
          enableTokenTimestamps: true,
        ),
        tokens: model.tokens,
        modelType: 'whisper',
        numThreads: 4,
      ),
    );
    final recognizer = sherpa.OfflineRecognizer(config);
    try {
      final wave = sherpa.readWave(wavPath);
      final stream = recognizer.createStream();
      try {
        stream.acceptWaveform(
          samples: wave.samples,
          sampleRate: wave.sampleRate,
        );
        recognizer.decode(stream);
        final result = recognizer.getResult(stream);
        if (result.text.trim().isEmpty) return const [];
        return aggregateWords(result.tokens, result.timestamps);
      } finally {
        stream.free();
      }
    } finally {
      recognizer.free();
    }
  }
}
