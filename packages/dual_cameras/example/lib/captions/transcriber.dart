import 'dart:math' as math;

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'caption_models.dart';
import 'speech_detector.dart';
import 'timing_validation.dart';
import 'vad_gate.dart';
import 'word_aggregator.dart';

/// On-device speech-to-text via sherpa-onnx (multilingual Whisper base int8)
/// with token-level timestamps aggregated to word timings for karaoke
/// captions. Nothing leaves the phone.
///
/// [language] is the sherpa-onnx language code: `''` (default) means
/// automatic detection and the detected language comes back in the result;
/// `'ru'` / `'en'` force that language. Auto is unreliable on very short
/// utterances (~1 s of speech can be misdetected as English), which is why
/// callers let the user override it (v0.5.0 phone defect: «Привет» came
/// back as "THERE YET."). Silero VAD runs first — silence or noise never
/// reaches the recognizer, so it cannot hallucinate captions for it — and
/// the decoded words are then gated to the detected speech segments, so
/// highlighting stops during pauses.
class Transcriber {
  /// Transcribe a 16 kHz mono WAV; returns word-level timings plus the
  /// detected language and whether the timings validated.
  /// Runs synchronously on the calling isolate (alpha-grade); callers should
  /// paint a "Transcribing…" state first and yield a frame.
  Future<TranscriptionResult> transcribe({
    required String wavPath,
    required WhisperModelFiles model,
    String language = '',
  }) async {
    sherpa.initBindings();

    final wave = sherpa.readWave(wavPath);
    final audioDuration = wave.samples.length / wave.sampleRate;
    final segments = SpeechDetector(vadModelPath: model.vad)
        .detect(wave.samples, sampleRate: wave.sampleRate);
    if (segments.isEmpty) {
      return const TranscriptionResult(
        words: [],
        detectedLanguage: '',
        timingsValid: true,
      );
    }

    final config = sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        whisper: sherpa.OfflineWhisperModelConfig(
          encoder: model.encoder,
          decoder: model.decoder,
          // Empty language = automatic language detection (sherpa-onnx C
          // API); the detected language comes back in result.lang. A
          // non-empty code forces that language for the whole file.
          language: language,
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
      final stream = recognizer.createStream();
      try {
        stream.acceptWaveform(
          samples: wave.samples,
          sampleRate: wave.sampleRate,
        );
        recognizer.decode(stream);
        final result = recognizer.getResult(stream);
        if (result.text.trim().isEmpty) {
          return TranscriptionResult(
            words: const [],
            detectedLanguage: result.lang,
            timingsValid: true,
          );
        }
        final raw = aggregateWords(result.tokens, result.timestamps)
            .map((word) => CaptionWord(
                  text: word.text,
                  start: word.start,
                  end: math.min(word.end, audioDuration),
                ))
            .toList();
        final words = applyVadGate(raw, segments);
        final validation = validateTimings(words, audioDuration);
        return TranscriptionResult(
          words: words,
          detectedLanguage: result.lang,
          timingsValid: validation.valid,
        );
      } finally {
        stream.free();
      }
    } finally {
      recognizer.free();
    }
  }
}
