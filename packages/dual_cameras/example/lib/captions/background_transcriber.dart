import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'caption_models.dart';
import 'speech_detector.dart';
import 'timing_validation.dart';
import 'vad_gate.dart';
import 'word_aggregator.dart';

/// Keeps native inference off the engine's channel isolate, so notification
/// Stop is received even while Whisper is decoding. Cancellation unwinds at
/// the next chunk boundary; native recognizer/stream resources are always freed.
///
/// [language] is the sherpa-onnx language code (see [Transcriber]): `''`
/// (default) auto-detects per chunk, a non-empty code forces that language
/// for every chunk. Auto is unreliable on very short utterances, which is
/// why callers let the user override it. Silero VAD runs before decoding
/// so silence/noise cannot hallucinate captions, and decoded words are gated
/// to the detected speech segments so highlighting stops during pauses.
class BackgroundTranscriber {
  SendPort? _control;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _control?.send('cancel');
  }

  Future<TranscriptionResult> transcribe({
    required String wavPath,
    required WhisperModelFiles model,
    required void Function(double) onProgress,
    String language = '',
  }) async {
    final receive = ReceivePort();
    final result = Completer<TranscriptionResult>();
    final subscription = receive.listen((dynamic message) {
      if (message is SendPort) {
        _control = message;
        if (_cancelled) _control!.send('cancel');
      } else if (message is double) {
        if (!_cancelled) onProgress(message);
      } else if (message is TranscriptionResult) {
        if (!result.isCompleted) result.complete(message);
      } else if (message is Map && message.containsKey('error')) {
        if (!result.isCompleted) {
          result.completeError(StateError(message['error'] as String));
        }
      } else if (message == null && !result.isCompleted) {
        result.completeError(
            StateError('Speech recognition stopped unexpectedly'));
      }
    });
    try {
      await Isolate.spawn(
          _decode, (receive.sendPort, wavPath, model, language),
          onExit: receive.sendPort, errorsAreFatal: true);
      return await result.future;
    } finally {
      _control = null;
      await subscription.cancel();
      receive.close();
    }
  }
}

Future<void> _decode(
    (SendPort, String, WhisperModelFiles, String) args) async {
  final (reply, wavPath, model, language) = args;
  final commands = ReceivePort();
  var cancelled = false;
  commands.listen((_) => cancelled = true);
  reply.send(commands.sendPort);
  sherpa.OfflineRecognizer? recognizer;
  late Object terminal;
  try {
    // Yield before initialization so a queued Stop can prevent loading a model.
    await Future<void>.delayed(Duration.zero);
    if (cancelled) throw StateError('Caption job stopped');
    sherpa.initBindings();
    final wave = sherpa.readWave(wavPath);
    final audioDuration = wave.samples.length / wave.sampleRate;
    final segments = SpeechDetector(vadModelPath: model.vad)
        .detect(wave.samples, sampleRate: wave.sampleRate);
    if (segments.isEmpty) {
      reply.send(1.0);
      terminal = const TranscriptionResult(
        words: [],
        detectedLanguage: '',
        timingsValid: true,
      );
    } else {
      recognizer = sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          whisper: sherpa.OfflineWhisperModelConfig(
            encoder: model.encoder,
            decoder: model.decoder,
            // Empty language = automatic language detection (sherpa-onnx C
            // API); the detected language comes back in result.lang. A
            // non-empty code forces that language for every chunk.
            language: language,
            task: 'transcribe',
            enableTokenTimestamps: true,
          ),
          tokens: model.tokens,
          modelType: 'whisper',
          numThreads: 2,
        ),
      ));
      final words = <CaptionWord>[];
      final langs = <String, int>{};
      // Short segments provide honest audio-based progress and safe Stop points.
      // Do not kill a Dart isolate inside an FFI call: that can leak native state.
      final chunkSize = wave.sampleRate * 10;
      for (var offset = 0; offset < wave.samples.length; offset += chunkSize) {
        await Future<void>.delayed(Duration.zero);
        if (cancelled) throw StateError('Caption job stopped');
        final end = math.min(offset + chunkSize, wave.samples.length);
        final stream = recognizer.createStream();
        try {
          stream.acceptWaveform(
            samples: Float32List.sublistView(wave.samples, offset, end),
            sampleRate: wave.sampleRate,
          );
          recognizer.decode(stream);
          final decoded = recognizer.getResult(stream);
          if (decoded.text.trim().isNotEmpty) {
            if (decoded.lang.isNotEmpty) {
              langs[decoded.lang] = (langs[decoded.lang] ?? 0) + 1;
            }
            final shift = offset / wave.sampleRate;
            final chunkEnd = end / wave.sampleRate;
            words.addAll(
                aggregateWords(decoded.tokens, decoded.timestamps).map(
                    (word) => CaptionWord(
                        text: word.text,
                        start: math.min(shift + word.start, chunkEnd),
                        end: math.min(shift + word.end, chunkEnd))));
          }
        } finally {
          stream.free();
        }
        reply.send(end / wave.samples.length);
      }
      await Future<void>.delayed(Duration.zero);
      if (cancelled) throw StateError('Caption job stopped');
      final gated = applyVadGate(words, segments);
      final validation = validateTimings(gated, audioDuration);
      // Language is detected per chunk; the most frequent non-empty one wins.
      var detectedLanguage = '';
      var bestCount = 0;
      langs.forEach((lang, count) {
        if (count > bestCount) {
          bestCount = count;
          detectedLanguage = lang;
        }
      });
      terminal = TranscriptionResult(
        words: gated,
        detectedLanguage: detectedLanguage,
        timingsValid: validation.valid,
      );
    }
  } catch (error) {
    terminal = {'error': '$error'};
  } finally {
    recognizer?.free();
    commands.close();
  }
  // Completion may tear down the headless engine: release all FFI state first.
  reply.send(terminal);
}
