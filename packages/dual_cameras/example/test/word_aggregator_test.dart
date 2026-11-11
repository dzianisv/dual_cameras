import 'package:dual_cameras_example/captions/caption_models.dart';
import 'package:dual_cameras_example/captions/timing_validation.dart';
import 'package:dual_cameras_example/captions/word_aggregator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('aggregateWords', () {
    test('aggregates Russian words with BPE word markers', () {
      final words = aggregateWords(
        ['Ġодин', 'Ġдва', 'Ġтри', 'Ġчетыре', 'Ġпять'],
        [0.0, 1.5, 2.8, 4.1, 5.6],
      );
      expect(words.map((w) => w.text).toList(),
          ['один', 'два', 'три', 'четыре', 'пять']);
      expect(words.first.start, 0.0);
      expect(words.last.text, 'пять');
    });

    test('skips multilingual special tokens including the language tag',
        () {
      final words = aggregateWords(
        [
          '<|startoftranscript|>',
          '<|ru|>',
          '<|transcribe|>',
          '<|notimestamps|>',
          'Ġодин',
          'Ġдва',
        ],
        [0.0, 0.0, 0.0, 0.0, 0.5, 1.8],
      );
      expect(words.map((w) => w.text).toList(), ['один', 'два']);
      expect(words.first.start, 0.5);
    });

    test('joins continuation tokens into one Russian word', () {
      final words = aggregateWords(
        ['Ġчет', 'ыре'],
        [4.1, 4.3],
      );
      expect(words.map((w) => w.text).toList(), ['четыре']);
      expect(words.single.start, 4.1);
    });

    test('word end is the next word start (karaoke convention)', () {
      final words = aggregateWords(
        ['Ġодин', 'Ġдва'],
        [0.0, 1.5],
      );
      expect(words.first.end, 1.5);
      // Last word ends 0.4s after its last token timestamp.
      expect(words.last.end, closeTo(1.9, 0.001));
    });
  });

  group('validateTimings', () {
    const duration = 6.85;

    test('accepts sane timings', () {
      final result = validateTimings(
        const [
          CaptionWord(text: 'один', start: 0.0, end: 1.5),
          CaptionWord(text: 'два', start: 1.5, end: 2.8),
        ],
        duration,
      );
      expect(result.valid, isTrue);
      expect(result.issues, isEmpty);
    });

    test('accepts an empty word list', () {
      expect(validateTimings(const [], duration).valid, isTrue);
    });

    test('rejects a negative start', () {
      final result = validateTimings(
        const [CaptionWord(text: 'один', start: -0.2, end: 1.0)],
        duration,
      );
      expect(result.valid, isFalse);
      expect(result.issues.single, contains('negative start'));
    });

    test('rejects an end beyond the audio duration', () {
      final result = validateTimings(
        const [CaptionWord(text: 'пять', start: 5.6, end: 9.0)],
        duration,
      );
      expect(result.valid, isFalse);
      expect(result.issues.single, contains('beyond audio'));
    });

    test('rejects non-monotonic starts', () {
      final result = validateTimings(
        const [
          CaptionWord(text: 'два', start: 1.5, end: 2.0),
          CaptionWord(text: 'один', start: 0.5, end: 1.0),
        ],
        duration,
      );
      expect(result.valid, isFalse);
      expect(result.issues.single, contains('before previous start'));
    });

    test('rejects an end before its start', () {
      final result = validateTimings(
        const [CaptionWord(text: 'один', start: 1.0, end: 0.5)],
        duration,
      );
      expect(result.valid, isFalse);
      expect(result.issues.single, contains('before start'));
    });

    test('rejects an implausibly long word', () {
      final result = validateTimings(
        const [CaptionWord(text: 'один', start: 0.0, end: 45.0)],
        120.0,
      );
      expect(result.valid, isFalse);
      expect(result.issues, isNotEmpty);
    });
  });
}
