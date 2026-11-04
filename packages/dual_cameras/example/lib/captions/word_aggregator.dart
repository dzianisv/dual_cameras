import 'caption_models.dart';

/// Aggregate Whisper token-level timestamps into word-level timings for
/// karaoke highlighting.
///
/// sherpa-onnx Whisper with `enableTokenTimestamps` returns per-token start
/// times. Whisper's BPE marks word beginnings with 'Ġ' (U+0120, a space).
/// Each word's end is the next word's start (karaoke convention: a word stays
/// highlighted until the next one begins).
List<CaptionWord> aggregateWords(
  List<String> tokens,
  List<double> timestamps,
) {
  final words = <CaptionWord>[];
  var current = '';
  var currentStart = 0.0;

  void flush(double end) {
    final text = current.trim();
    if (text.isNotEmpty) {
      words.add(CaptionWord(text: text, start: currentStart, end: end));
    }
    current = '';
  }

  for (var i = 0; i < tokens.length; i++) {
    final tok = tokens[i];
    // Skip special/timestamp tokens like <|0.00|>, <|startoftranscript|>.
    if (tok.startsWith('<|') && tok.endsWith('|>')) continue;
    final t = i < timestamps.length ? timestamps[i] : 0.0;
    final normalized = tok.replaceAll('Ġ', ' ');
    if (normalized.startsWith(' ') && current.trim().isNotEmpty) {
      flush(t);
    }
    if (current.isEmpty) currentStart = t;
    current += normalized;
  }
  if (current.trim().isNotEmpty) {
    final lastT = timestamps.isNotEmpty ? timestamps.last : 0.0;
    flush(lastT + 0.4);
  }
  // Word end = next word's start.
  for (var i = 0; i < words.length - 1; i++) {
    words[i] = CaptionWord(
      text: words[i].text,
      start: words[i].start,
      end: words[i + 1].start,
    );
  }
  return words;
}
