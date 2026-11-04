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

/// Local paths of the downloaded Whisper model files.
@immutable
class WhisperModelFiles {
  const WhisperModelFiles({
    required this.encoder,
    required this.decoder,
    required this.tokens,
  });

  final String encoder;
  final String decoder;
  final String tokens;
}
