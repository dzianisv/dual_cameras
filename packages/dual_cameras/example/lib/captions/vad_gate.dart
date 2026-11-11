import 'dart:math' as math;

import 'caption_models.dart';

/// Gate caption words to detected speech segments.
///
/// Words that overlap a speech segment are kept, clamped to the segment —
/// this stops the karaoke highlight from lingering through a pause.
/// A word straddling a segment boundary is truncated to the segment, not
/// dropped, as long as the overlap is real.
///
/// Whisper's token timestamps run early (about a word early for isolated
/// words), so a real word's time can fall just before its speech segment
/// with no overlap at all. Such a word snaps into the nearest segment that
/// no overlapping word already covers, preserving its duration, as long as
/// the gap is within [snapToleranceSeconds]. A word near a segment that
/// already has a word is a hallucination in a gap — it stays dropped, as
/// does a word far from every uncovered segment.
///
/// [toleranceSeconds] forgives small timestamp/VAD boundary disagreements; a
/// word that only touches a segment within the tolerance still counts as
/// overlapping.
List<CaptionWord> applyVadGate(
  List<CaptionWord> words,
  List<SpeechSegment> segments, {
  double toleranceSeconds = 0.05,
  double snapToleranceSeconds = 1.0,
}) {
  if (segments.isEmpty) return const [];
  final gated = <CaptionWord>[];
  // Pass 1: overlap. Record which segments an overlapping word claims, so
  // pass 2 never snaps a hallucination onto speech that already has a word.
  final covered = <int>{};
  final pending = <CaptionWord>[];
  for (final word in words) {
    var best = -1;
    var bestOverlap = 0.0;
    for (var i = 0; i < segments.length; i++) {
      final overlap = math.min(word.end, segments[i].end) -
          math.max(word.start, segments[i].start);
      if (overlap > bestOverlap) {
        bestOverlap = overlap;
        best = i;
      }
    }
    if (best >= 0 && bestOverlap > toleranceSeconds) {
      covered.add(best);
      gated.add(CaptionWord(
        text: word.text,
        start: math.max(word.start, segments[best].start),
        end: math.min(word.end, segments[best].end),
      ));
    } else {
      pending.add(word);
    }
  }
  // Pass 2: snap a pending word into the nearest uncovered segment.
  for (final word in pending) {
    var best = -1;
    var bestGap = double.infinity;
    for (var i = 0; i < segments.length; i++) {
      if (covered.contains(i)) continue;
      final segment = segments[i];
      final gap = word.end <= segment.start
          ? segment.start - word.end
          : word.start >= segment.end
              ? word.start - segment.end
              : 0.0;
      if (gap < bestGap) {
        bestGap = gap;
        best = i;
      }
    }
    if (best < 0 || bestGap > snapToleranceSeconds) continue;
    final segment = segments[best];
    final duration = word.end - word.start;
    double start;
    double end;
    if (word.end <= segment.start) {
      // Word is before the segment: anchor at the segment start.
      start = segment.start;
      end = math.min(segment.end, start + duration);
    } else if (word.start >= segment.end) {
      // Word is after the segment: anchor at the segment end.
      end = segment.end;
      start = math.max(segment.start, end - duration);
    } else {
      start = math.max(word.start, segment.start);
      end = math.min(word.end, segment.end);
    }
    if (end <= start) continue;
    gated.add(CaptionWord(text: word.text, start: start, end: end));
  }
  gated.sort((a, b) => a.start.compareTo(b.start));
  return gated;
}
