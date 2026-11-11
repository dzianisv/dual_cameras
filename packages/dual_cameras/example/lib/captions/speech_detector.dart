import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'caption_models.dart';

/// Silero VAD (via sherpa-onnx) over raw 16 kHz mono samples.
///
/// Feeds the audio in 10-second windows and drains completed segments as
/// they appear, so arbitrarily long recordings do not need to sit in the VAD
/// buffer. Segment boundaries come from the audio itself, not from Whisper —
/// that is what makes the gate independent of the recognizer's hallucinations.
class SpeechDetector {
  SpeechDetector({required this.vadModelPath});

  final String vadModelPath;

  /// Detect speech segments. [samples] are mono float samples at
  /// [sampleRate] (16 kHz in this app). Returns segments in seconds, sorted
  /// by start time. Empty when no speech was detected.
  List<SpeechSegment> detect(
    Float32List samples, {
    int sampleRate = 16000,
  }) {
    sherpa.initBindings();
    final vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(model: vadModelPath),
        sampleRate: sampleRate,
      ),
      // The circular buffer only needs to hold one feed window.
      bufferSizeInSeconds: 30,
    );
    try {
      const window = 16000 * 10;
      final segments = <SpeechSegment>[];
      void drain() {
        while (!vad.isEmpty()) {
          final segment = vad.front();
          vad.pop();
          final start = segment.start / sampleRate;
          final end =
              (segment.start + segment.samples.length) / sampleRate;
          segments.add(SpeechSegment(start: start, end: end));
        }
      }

      for (var offset = 0; offset < samples.length; offset += window) {
        final end = math.min(offset + window, samples.length);
        vad.acceptWaveform(
            Float32List.sublistView(samples, offset, end));
        drain();
      }
      vad.flush();
      drain();
      segments.sort((a, b) => a.start.compareTo(b.start));
      return segments;
    } finally {
      vad.free();
    }
  }
}
