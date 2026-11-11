import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dual_cameras_example/captions/background_transcriber.dart';
import 'package:dual_cameras_example/captions/model_manager.dart';
import 'package:dual_cameras_example/captions/speech_detector.dart';
import 'package:dual_cameras_example/captions/transcriber.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Real-decode host check for the multilingual build.
///
/// Runs only on CI (or when STORYCAM_HOST_INFERENCE=1 locally). It downloads
/// the exact production model files, decodes the committed real-speech
/// Russian fixtures, and asserts the five number words (as digits — Whisper
/// normalizes spoken numbers), the five Cyrillic words, lang=ru, sane
/// timestamps, VAD gating across the inter-word silences, and no words on
/// silence/noise.
///
/// This is a host check only: it proves the model + decoder + VAD behave as
/// the app needs. It does NOT prove anything about Android (camera, mic,
/// background work, burn-in) — that still needs a phone.
///
/// The fixture is real human speech (five single-word clips from Wikimedia
/// Commons, The Shtooka Project, CC-BY-2.0-FR — see test/fixtures/README.md),
/// concatenated with 0.4s silences between words.
/// Pre-load the sherpa-onnx Linux .so from the pub cache, so the bare-name
/// dlopen the package does under `flutter test` finds it.
///
/// Under `flutter test`, `Isolate.resolvePackageUriSync` is unavailable, so
/// the package's own auto-resolution returns null and `initBindings()` tries
/// `DynamicLibrary.open('libsherpa-onnx-c-api.so')`, which is not on the
/// loader path. The libs ship in `sherpa_onnx_linux/linux/<arch>/` (with
/// `$ORIGIN` RPATH, so libonnxruntime.so resolves from the same dir). The
/// .so carries SONAME `libsherpa-onnx-c-api.so`, so pre-loading it by
/// absolute path makes the bare-name open — in this isolate and in spawned
/// isolates (same process) — return the same handle.
///
/// Returns the lib dir. Throws [StateError] when the lib cannot be located.
String _preloadNativeLib() {
  final config = File('.dart_tool/package_config.json').absolute;
  if (!config.existsSync()) {
    throw StateError(
        'package_config.json not found (cwd ${Directory.current.path})');
  }
  final data = jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
  final packages = (data['packages'] as List).cast<Map<String, dynamic>>();
  final entry = packages.firstWhere(
    (p) => p['name'] == 'sherpa_onnx_linux',
    orElse: () => throw StateError(
        'sherpa_onnx_linux not in package_config.json'),
  );
  final pkgDir =
      config.uri.resolveUri(Uri.parse(entry['rootUri'] as String));
  final arch =
      Platform.version.contains('arm64') ||
              Platform.version.contains('aarch64')
          ? 'aarch64'
          : 'x64';
  // Join with path separators, not Uri.resolve: a rootUri without a trailing
  // slash makes resolve() replace the package dir segment instead of
  // appending to it.
  final sep = Platform.pathSeparator;
  final libFile = File(
      '${File.fromUri(pkgDir).path}${sep}linux$sep$arch${sep}libsherpa-onnx-c-api.so');
  if (!libFile.existsSync()) {
    throw StateError('native lib not found at ${libFile.path}');
  }
  DynamicLibrary.open(libFile.path);
  return libFile.parent.path;
}

void main() {
  test('host inference: multilingual model decodes Russian fixture',
      () async {
    if (Platform.environment['CI'] != 'true' &&
        Platform.environment['STORYCAM_HOST_INFERENCE'] != '1') {
      markTestSkipped('host inference runs on CI or with '
          'STORYCAM_HOST_INFERENCE=1');
      return;
    }

    // If the native library cannot load on this host, the check is
    // unverified — skip loudly instead of failing on an environment limit.
    try {
      _preloadNativeLib();
    } catch (error) {
      markTestSkipped('sherpa-onnx Linux native lib not resolvable: $error');
      return;
    }
    try {
      sherpa.initBindings();
    } catch (error) {
      markTestSkipped('sherpa-onnx native library unavailable: $error');
      return;
    }

    final temp =
        await Directory.systemTemp.createTemp('host-inference-');
    try {
      final manager = ModelManager(
        documentsDirectory: () async => temp,
      );
      final model = await manager.ensureModel(onProgress: (_) {});
      // Report the hashes of the exact bytes downloaded: the encoder/decoder
      // pins are cross-checked here (LFS oid == SHA-256 claim), and the
      // tokens/VAD hashes are printed so they can be pinned afterwards.
      for (final path in [
        model.encoder,
        model.decoder,
        model.tokens,
        model.vad
      ]) {
        final file = File(path);
        final digest =
            await crypto.sha256.bind(file.openRead()).first;
        // ignore: avoid_print
        print('host-inference model ${file.uri.pathSegments.last}: '
            '${await file.length()} bytes sha256=$digest');
      }

      const fixture = 'test/fixtures/russian_numbers.wav';
      const silence = 'test/fixtures/silence.wav';
      const noise = 'test/fixtures/noise.wav';
      for (final path in [fixture, silence, noise]) {
        expect(File(path).existsSync(), isTrue, reason: 'missing $path');
      }

      // Diagnostics (printed, not asserted): raw decode without the
      // transcriber's VAD gate, so a failure can be attributed to the
      // recognizer, the VAD, or the gate instead of guessed at.
      final wave = sherpa.readWave(fixture);
      var maxAbs = 0.0;
      for (final s in wave.samples) {
        if (s.abs() > maxAbs) maxAbs = s.abs();
      }
      // ignore: avoid_print
      print('host-inference diag wave: sampleRate=${wave.sampleRate} '
          'samples=${wave.samples.length} '
          'duration=${(wave.samples.length / wave.sampleRate).toStringAsFixed(3)}s '
          'maxAbs=${maxAbs.toStringAsFixed(4)}');
      final vadSegments = SpeechDetector(vadModelPath: model.vad)
          .detect(wave.samples, sampleRate: wave.sampleRate);
      // ignore: avoid_print
      print('host-inference diag vad segments: ${vadSegments.map((s) => '[${s.start.toStringAsFixed(3)}, ${s.end.toStringAsFixed(3)}]').join(', ')}');
      final rawConfig = sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          whisper: sherpa.OfflineWhisperModelConfig(
            encoder: model.encoder,
            decoder: model.decoder,
            language: '',
            task: 'transcribe',
            enableTokenTimestamps: true,
          ),
          tokens: model.tokens,
          modelType: 'whisper',
          numThreads: 4,
        ),
      );
      final rawRecognizer = sherpa.OfflineRecognizer(rawConfig);
      try {
        final rawStream = rawRecognizer.createStream();
        try {
          rawStream.acceptWaveform(
            samples: wave.samples,
            sampleRate: wave.sampleRate,
          );
          rawRecognizer.decode(rawStream);
          final raw = rawRecognizer.getResult(rawStream);
          // ignore: avoid_print
          print('host-inference diag raw decode: lang=${raw.lang} '
              'text="${raw.text}" tokens=${raw.tokens.length} '
              '${raw.tokens.take(12).toList()} '
              'timestamps=${raw.timestamps.length} '
              '${raw.timestamps.take(12).toList()}');
        } finally {
          rawStream.free();
        }
      } finally {
        rawRecognizer.free();
      }

      final result = await Transcriber().transcribe(
        wavPath: fixture,
        model: model,
      );
      // ignore: avoid_print
      print('host-inference ru: lang=${result.detectedLanguage} '
          'timingsValid=${result.timingsValid} words=${result.words}');
      expect(result.detectedLanguage, 'ru');
      expect(result.timingsValid, isTrue);
      final text = result.words.map((w) => w.text).join(' ');
      // Whisper normalizes spoken number words to digits: the fixture says
      // «один, два, три, четыре, пять» and the model correctly returns
      // "1 2 3 4 5" (lang=ru). The Cyrillic words themselves are proven by
      // the cyrillic_words.wav decode below.
      for (final word in ['1', '2', '3', '4', '5']) {
        expect(text, contains(word), reason: 'missing $word in "$text"');
      }
      // The fixture is 6.850s: five words separated by 0.4s silences.
      // Gating must keep every word inside speech: without it, the karaoke
      // end-extension would span the gaps.
      const gaps = [
        (1.097, 1.497),
        (2.437, 2.837),
        (3.701, 4.101),
        (5.250, 5.650),
      ];
      var previousStart = -1.0;
      for (final word in result.words) {
        expect(word.start, greaterThanOrEqualTo(0.0));
        expect(word.end, lessThanOrEqualTo(6.850 + 0.5));
        expect(word.start, greaterThanOrEqualTo(previousStart));
        previousStart = word.start;
        for (final (gapStart, gapEnd) in gaps) {
          final overlaps = word.start < gapEnd - 0.05 &&
              word.end > gapStart + 0.05;
          expect(overlaps, isFalse,
              reason:
                  '${word.text} [${word.start}, ${word.end}] overlaps silence gap [$gapStart, $gapEnd]');
        }
      }

      // The background (isolate) path must decode the same words.
      final background = await BackgroundTranscriber().transcribe(
        wavPath: fixture,
        model: model,
        onProgress: (_) {},
      );
      expect(background.detectedLanguage, 'ru');
      final backgroundText =
          background.words.map((w) => w.text).join(' ');
      for (final word in ['1', '2', '3', '4', '5']) {
        expect(backgroundText, contains(word),
            reason: 'background missing $word in "$backgroundText"');
      }

      // Cyrillic end-to-end: five non-number Russian words must come back
      // as Cyrillic text (not digits, not Latin), with lang=ru.
      const cyrillic = 'test/fixtures/cyrillic_words.wav';
      expect(File(cyrillic).existsSync(), isTrue,
          reason: 'missing $cyrillic');
      // Raw decode first, so a missing word is attributable to the
      // recognizer (not in the raw tokens) or the gate (in the raw tokens
      // but dropped).
      final cyrillicWave = sherpa.readWave(cyrillic);
      final cyrillicRecognizer = sherpa.OfflineRecognizer(rawConfig);
      try {
        final cyrillicStream = cyrillicRecognizer.createStream();
        try {
          cyrillicStream.acceptWaveform(
            samples: cyrillicWave.samples,
            sampleRate: cyrillicWave.sampleRate,
          );
          cyrillicRecognizer.decode(cyrillicStream);
          final cyrillicRaw = cyrillicRecognizer.getResult(cyrillicStream);
          // ignore: avoid_print
          print('host-inference diag raw cyrillic decode: '
              'lang=${cyrillicRaw.lang} text="${cyrillicRaw.text}" '
              'tokens=${cyrillicRaw.tokens.length} '
              '${cyrillicRaw.tokens.take(12).toList()} '
              'timestamps=${cyrillicRaw.timestamps.length} '
              '${cyrillicRaw.timestamps.take(12).toList()}');
        } finally {
          cyrillicStream.free();
        }
      } finally {
        cyrillicRecognizer.free();
      }
      final cyrillicResult = await Transcriber().transcribe(
        wavPath: cyrillic,
        model: model,
      );
      // ignore: avoid_print
      print('host-inference cyrillic: lang=${cyrillicResult.detectedLanguage} '
          'timingsValid=${cyrillicResult.timingsValid} '
          'words=${cyrillicResult.words}');
      expect(cyrillicResult.detectedLanguage, 'ru');
      expect(cyrillicResult.timingsValid, isTrue);
      final cyrillicText =
          cyrillicResult.words.map((w) => w.text).join(' ');
      for (final word in ['мама', 'дом', 'солнце', 'вода', 'спасибо']) {
        expect(cyrillicText, contains(word),
            reason: 'missing $word in "$cyrillicText"');
      }
      // 7.940 s fixture, 0.4 s gaps between words; no word may span a gap.
      const cyrillicGaps = [
        (1.097, 1.497),
        (2.397, 2.797),
        (3.947, 4.347),
        (6.390, 6.790),
      ];
      var cyrillicPreviousStart = -1.0;
      for (final word in cyrillicResult.words) {
        expect(word.start, greaterThanOrEqualTo(0.0));
        expect(word.end, lessThanOrEqualTo(7.940 + 0.5));
        expect(word.start, greaterThanOrEqualTo(cyrillicPreviousStart));
        cyrillicPreviousStart = word.start;
        for (final (gapStart, gapEnd) in cyrillicGaps) {
          final overlaps = word.start < gapEnd - 0.05 &&
              word.end > gapStart + 0.05;
          expect(overlaps, isFalse,
              reason:
                  '${word.text} [${word.start}, ${word.end}] overlaps silence gap [$gapStart, $gapEnd]');
        }
      }

      // Silence and pink noise must yield no words (VAD rejects them before
      // the recognizer ever runs).
      final silenceResult = await Transcriber().transcribe(
        wavPath: silence,
        model: model,
      );
      expect(silenceResult.words, isEmpty);
      final noiseResult = await Transcriber().transcribe(
        wavPath: noise,
        model: model,
      );
      expect(noiseResult.words, isEmpty);

      // Single-word diagnostic — repro for the v0.5.0 phone defect: Den
      // said «Привет» and the burned-in caption came back as English
      // "THERE YET.". Auto-detection on ~1 s of speech is the suspect.
      // These decodes only PRINT lang/text; they assert no language, so
      // the run stays green whatever the model does — the CI log is the
      // evidence. The raw decode (no VAD gate) separates "the recognizer
      // misdetected" from "VAD/the gate dropped the word".
      const oneWord = 'test/fixtures/russian_one_word.wav';
      expect(File(oneWord).existsSync(), isTrue, reason: 'missing $oneWord');
      final oneWordWave = sherpa.readWave(oneWord);
      final oneWordRecognizer = sherpa.OfflineRecognizer(rawConfig);
      try {
        final oneWordStream = oneWordRecognizer.createStream();
        try {
          oneWordStream.acceptWaveform(
            samples: oneWordWave.samples,
            sampleRate: oneWordWave.sampleRate,
          );
          oneWordRecognizer.decode(oneWordStream);
          final oneWordRaw = oneWordRecognizer.getResult(oneWordStream);
          // ignore: avoid_print
          print('host-inference diag raw one-word decode: '
              'lang=${oneWordRaw.lang} text="${oneWordRaw.text}" '
              'tokens=${oneWordRaw.tokens.length} '
              '${oneWordRaw.tokens.take(12).toList()} '
              'timestamps=${oneWordRaw.timestamps.length} '
              '${oneWordRaw.timestamps.take(12).toList()}');
        } finally {
          oneWordStream.free();
        }
      } finally {
        oneWordRecognizer.free();
      }
      for (final (label, path) in [
        ('one-word numbers', 'test/fixtures/russian_one_word.wav'),
        ('two-word numbers', 'test/fixtures/russian_two_words.wav'),
        ('one-word cyrillic', 'test/fixtures/cyrillic_one_word.wav'),
      ]) {
        expect(File(path).existsSync(), isTrue, reason: 'missing $path');
        final diag = await Transcriber().transcribe(
          wavPath: path,
          model: model,
        );
        // ignore: avoid_print
        print('host-inference single-word diag [$label]: '
            'lang=${diag.detectedLanguage} '
            'timingsValid=${diag.timingsValid} '
            'words=${diag.words.map((w) => w.text).join(' ')}');
      }

      // Forced-language assertions (the v0.5.1 fix): a picked language
      // must reach the recognizer and change what comes back. Auto stays
      // the default (every decode above used it); these prove the override.
      // The five-word fixture consistently comes back as digits ("один"
      // -> "1") — Whisper's number normalization. The SINGLE word flips
      // between runs ("1" in run 43027708614, "один" in run 43031353098,
      // same models, same fixture), so the one-word assertions accept
      // either form: with language forced to Russian both are the right
      // word, and the override is proven by lang=ru + one word.
      final forcedRu = await Transcriber().transcribe(
        wavPath: 'test/fixtures/russian_one_word.wav',
        model: model,
        language: 'ru',
      );
      // ignore: avoid_print
      print('host-inference forced ru one-word: '
          'lang=${forcedRu.detectedLanguage} '
          'words=${forcedRu.words.map((w) => w.text).join(' ')}');
      expect(forcedRu.detectedLanguage, 'ru');
      expect(forcedRu.words, hasLength(1));
      expect(['1', 'один'], contains(forcedRu.words.single.text));
      final forcedRuCyrillic = await Transcriber().transcribe(
        wavPath: 'test/fixtures/cyrillic_one_word.wav',
        model: model,
        language: 'ru',
      );
      expect(forcedRuCyrillic.detectedLanguage, 'ru');
      expect(forcedRuCyrillic.words.map((w) => w.text).join(' '),
          contains('мама'));
      final forcedEn = await Transcriber().transcribe(
        wavPath: 'test/fixtures/russian_one_word.wav',
        model: model,
        language: 'en',
      );
      // ignore: avoid_print
      print('host-inference forced en one-word: '
          'lang=${forcedEn.detectedLanguage} '
          'words=${forcedEn.words.map((w) => w.text).join(' ')}');
      expect(forcedEn.detectedLanguage, 'en');
      // The background (isolate) path must honor the override too.
      final forcedRuBackground = await BackgroundTranscriber().transcribe(
        wavPath: 'test/fixtures/russian_one_word.wav',
        model: model,
        language: 'ru',
        onProgress: (_) {},
      );
      expect(forcedRuBackground.detectedLanguage, 'ru');
      expect(forcedRuBackground.words, hasLength(1));
      expect(['1', 'один'], contains(forcedRuBackground.words.single.text));
    } finally {
      await temp.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
