import 'caption_models.dart';

/// Result of validating word timings against the audio they came from.
class TimingValidation {
  const TimingValidation({required this.valid, required this.issues});

  /// True when every check passed.
  final bool valid;

  /// Human-readable problems; empty when [valid] is true.
  final List<String> issues;
}

/// Validate karaoke word timings.
///
/// Checks: starts are non-negative and non-decreasing, every word ends at or
/// after it starts and no later than the audio duration (plus a small
/// tolerance for decoder rounding), and no single word or inter-word gap is
/// absurdly long. Real pauses between sentences can last seconds, so the gap
/// limit is deliberately generous — this catches garbage timestamps, not
/// natural speech rhythm.
///
/// Returns the list of problems; [TimingValidation.valid] is true when the
/// list is empty. Words are never dropped here — callers decide what to do
/// with an invalid result.
TimingValidation validateTimings(
  List<CaptionWord> words,
  double audioDurationSeconds,
) {
  const tolerance = 0.5;
  const maxWordSeconds = 30.0;
  const maxGapSeconds = 60.0;
  final issues = <String>[];
  var previousStart = -1.0;
  var previousEnd = 0.0;
  for (var i = 0; i < words.length; i++) {
    final word = words[i];
    if (word.start < 0) {
      issues.add('word $i (${word.text}): negative start ${word.start}');
    }
    if (word.start < previousStart) {
      issues.add('word $i (${word.text}): start ${word.start} before '
          'previous start $previousStart');
    }
    if (word.end < word.start) {
      issues.add('word $i (${word.text}): end ${word.end} before start '
          '${word.start}');
    }
    if (word.end > audioDurationSeconds + tolerance) {
      issues.add('word $i (${word.text}): end ${word.end} beyond audio '
          'duration $audioDurationSeconds');
    }
    if (word.end - word.start > maxWordSeconds) {
      issues.add('word $i (${word.text}): implausibly long '
          '(${word.end - word.start}s)');
    }
    if (i > 0 && word.start - previousEnd > maxGapSeconds) {
      issues.add('gap before word $i (${word.text}): '
          '${word.start - previousEnd}s of silence');
    }
    previousStart = word.start;
    previousEnd = word.end;
  }
  return TimingValidation(valid: issues.isEmpty, issues: issues);
}
