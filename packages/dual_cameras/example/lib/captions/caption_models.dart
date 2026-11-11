import 'package:flutter/foundation.dart';

/// A single word with its spoken time range (seconds), for karaoke captions.
@immutable
class CaptionWord {
  const CaptionWord({
    required this.text,
    required this.start,
    required this.end,
  });

  final String text;
  final double start;
  final double end;

  Map<String, Object> toJson() => {
        'text': text,
        'start': start,
        'end': end,
      };
}

/// Local paths of the downloaded Whisper + VAD model files.
@immutable
class WhisperModelFiles {
  const WhisperModelFiles({
    required this.encoder,
    required this.decoder,
    required this.tokens,
    required this.vad,
  });

  final String encoder;
  final String decoder;
  final String tokens;

  /// Silero VAD model, used to gate captions to detected speech.
  final String vad;
}

/// One continuous stretch of detected speech, in seconds.
@immutable
class SpeechSegment {
  const SpeechSegment({required this.start, required this.end});

  final double start;
  final double end;
}

/// Everything a transcription run produces.
///
/// [detectedLanguage] is the language Whisper auto-detected (BCP 47-ish code
/// such as 'ru' or 'en'), or '' when nothing was detected (e.g. silence).
/// [timingsValid] says whether the word timings passed validation against the
/// audio duration; words are still returned when it is false so the caller can
/// decide, but such a result must not be presented as verified captions.
@immutable
class TranscriptionResult {
  const TranscriptionResult({
    required this.words,
    required this.detectedLanguage,
    required this.timingsValid,
  });

  final List<CaptionWord> words;
  final String detectedLanguage;
  final bool timingsValid;
}
