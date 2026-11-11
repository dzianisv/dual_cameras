import 'dart:math' as math;

import 'caption_models.dart';

/// Gate caption words to detected speech segments.
///
/// Words that do not overlap any speech segment are dropped — this is what
/// stops silence or noise from producing hallucinated captions, and what
/// stops the karaoke highlight from lingering through a pause. A kept word is
/// clamped to the speech segment it overlaps, so its highlight ends when the
/// speech ends. A word straddling a segment boundary is truncated to the
/// segment, not dropped, as long as the overlap is real.
///
/// [toleranceSeconds] forgives small timestamp/VAD boundary disagreements; a
/// word that only touches a segment within the tolerance still counts as
/// overlapping.
List<CaptionWord> applyVadGate(
  List<CaptionWord> words,
  List<SpeechSegment> segments, {
  double toleranceSeconds = 0.05,
}) {
  if (segments.isEmpty) return const [];
  final gated = <CaptionWord>[];
  for (final word in words) {
    SpeechSegment? best;
    var bestOverlap = 0.0;
    for (final segment in segments) {
      final overlap = math.min(word.end, segment.end) -
          math.max(word.start, segment.start);
      if (overlap > bestOverlap) {
        bestOverlap = overlap;
        best = segment;
      }
    }
    if (best == null || bestOverlap <= toleranceSeconds) continue;
    gated.add(CaptionWord(
      text: word.text,
      start: math.max(word.start, best.start),
      end: math.min(word.end, best.end),
    ));
  }
  return gated;
}
