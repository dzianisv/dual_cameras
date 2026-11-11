import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'caption_models.dart';

/// Silero VAD (via sherpa-onnx) over raw 16 kHz mono samples.
///
/// Feeds the audio one VAD window (512 samples) at a time and drains
/// completed segments after each chunk, the way a streaming VAD is meant to
/// be used. This matters: feeding a whole file in one call makes the VAD
/// return only the last speech burst (verified against sherpa-onnx 2.0.1 —
/// a 6.85 s five-word file fed at once yields a single 0.31 s segment at the
/// tail, while 512-sample chunks yield one segment per word), and feeding
/// in 0.5 s or 1 s chunks merges neighbouring words into one segment, so
/// the karaoke gate can no longer tell words apart across the gaps.
/// Segment boundaries come from the audio itself, not from Whisper —
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
      // One VAD window per feed call (must match
      // SileroVadModelConfig.windowSize, 512 samples at 16 kHz). Larger
      // chunks merge speech bursts across the gaps; a single whole-file
      // feed loses every segment but the last — see the class doc.
      const feedChunkSamples = 512;
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

      for (var offset = 0; offset < samples.length; offset += feedChunkSamples) {
        final end = math.min(offset + feedChunkSamples, samples.length);
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
