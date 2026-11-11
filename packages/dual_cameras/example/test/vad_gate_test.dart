import 'package:dual_cameras_example/captions/caption_models.dart';
import 'package:dual_cameras_example/captions/vad_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Speech regions of the Russian-numbers fixture: five words separated by
  // 0.4s silences (word durations 1.097 / 0.940 / 0.864 / 1.149 / 1.200).
  const segments = [
    SpeechSegment(start: 0.0, end: 1.097),
    SpeechSegment(start: 1.497, end: 2.437),
    SpeechSegment(start: 2.837, end: 3.701),
    SpeechSegment(start: 4.101, end: 5.250),
    SpeechSegment(start: 5.650, end: 6.850),
  ];

  test('keeps words in speech but clamps their ends to the segment end',
      () {
    // Karaoke aggregation extends each word to the next word's start, so
    // without gating the highlight would linger through the 0.4s gaps.
    final words = applyVadGate(
      const [
        CaptionWord(text: 'один', start: 0.0, end: 1.497),
        CaptionWord(text: 'два', start: 1.497, end: 2.837),
        CaptionWord(text: 'три', start: 2.837, end: 4.101),
        CaptionWord(text: 'четыре', start: 4.101, end: 5.650),
        CaptionWord(text: 'пять', start: 5.650, end: 6.0),
      ],
      segments,
    );
    expect(words.map((w) => w.text).toList(),
        ['один', 'два', 'три', 'четыре', 'пять']);
    // Highlighting stops when the speech stops, not at the next word.
    expect(words[0].end, closeTo(1.097, 0.001));
    expect(words[1].end, closeTo(2.437, 0.001));
    expect(words[2].end, closeTo(3.701, 0.001));
    expect(words[3].end, closeTo(5.250, 0.001));
    expect(words[4].end, 6.0);
    // No word leaks outside a speech segment: every word is contained in
    // (exactly) one segment, so no highlight spans a silence gap.
    for (final word in words) {
      final inside = segments.any((s) =>
          word.start >= s.start - 0.05 && word.end <= s.end + 0.05);
      expect(inside, isTrue, reason: '${word.text} leaks outside speech');
    }
  });

  test('drops a word entirely inside silence', () {
    final words = applyVadGate(
      const [
        CaptionWord(text: 'один', start: 0.0, end: 1.0),
        CaptionWord(text: 'хм', start: 1.2, end: 1.4),
        CaptionWord(text: 'два', start: 1.497, end: 2.4),
      ],
      segments,
    );
    expect(words.map((w) => w.text).toList(), ['один', 'два']);
  });

  test('truncates a word straddling a segment boundary instead of dropping it',
      () {
    final words = applyVadGate(
      const [CaptionWord(text: 'один', start: 1.0, end: 1.3)],
      segments,
    );
    expect(words, hasLength(1));
    expect(words.single.start, 1.0);
    expect(words.single.end, closeTo(1.097, 0.001));
  });

  test('no speech segments means no words at all', () {
    expect(
        applyVadGate(
          const [CaptionWord(text: 'один', start: 0.0, end: 1.0)],
          const [],
        ),
        isEmpty);
  });

  test('snaps a word just before its uncovered segment into it', () {
    // Whisper timestamps run early: a real word can sit entirely in the
    // gap before its speech with no overlap. It snaps into the segment,
    // keeping its duration, anchored at the segment start.
    final words = applyVadGate(
      const [
        CaptionWord(text: 'один', start: 0.0, end: 1.0),
        CaptionWord(text: 'пять', start: 5.45, end: 5.6),
      ],
      segments,
    );
    expect(words.map((w) => w.text).toList(), ['один', 'пять']);
    expect(words[1].start, closeTo(5.65, 0.001));
    expect(words[1].end, closeTo(5.80, 0.001));
  });

  test('does not snap a word to a far uncovered segment', () {
    // More than snapToleranceSeconds (2.0 s) from every uncovered segment:
    // a hallucination in a long silence stays dropped.
    const farSegments = [
      SpeechSegment(start: 0.0, end: 1.0),
      SpeechSegment(start: 5.0, end: 6.0),
    ];
    final words = applyVadGate(
      const [
        CaptionWord(text: 'один', start: 0.0, end: 0.9),
        CaptionWord(text: 'хм', start: 2.0, end: 2.3),
      ],
      farSegments,
    );
    expect(words.map((w) => w.text).toList(), ['один']);
  });

  test('snaps across covered segments that are not between word and target',
      () {
    // The 'спасибо' geometry from the host check: the word's timestamp
    // landed 1.1 s before its own (uncovered) segment. The covered
    // segments are all before the word, none lies between it and its
    // target, so the snap is allowed — unlike 'хм' in the gap test, where
    // the covered second segment sits between the word and its target.
    const segments3 = [
      SpeechSegment(start: 0.0, end: 1.0),
      SpeechSegment(start: 2.0, end: 3.0),
      SpeechSegment(start: 5.0, end: 6.0),
    ];
    final words = applyVadGate(
      const [
        CaptionWord(text: 'один', start: 0.0, end: 0.9),
        CaptionWord(text: 'два', start: 2.0, end: 2.9),
        CaptionWord(text: 'пять', start: 3.5, end: 3.9),
      ],
      segments3,
    );
    expect(words.map((w) => w.text).toList(), ['один', 'два', 'пять']);
    expect(words[2].start, closeTo(5.0, 0.001));
    expect(words[2].end, closeTo(5.4, 0.001));
  });

  test('empty input stays empty', () {
    expect(applyVadGate(const [], segments), isEmpty);
  });
}
