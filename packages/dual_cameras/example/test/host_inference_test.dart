import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dual_cameras_example/captions/background_transcriber.dart';
import 'package:dual_cameras_example/captions/model_manager.dart';
import 'package:dual_cameras_example/captions/transcriber.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Real-decode host check for the multilingual build.
///
/// Runs only on CI (or when STORYCAM_HOST_INFERENCE=1 locally). It downloads
/// the exact production model files, decodes the committed real-speech
/// Russian fixture, and asserts the five words, lang=ru, sane timestamps,
/// VAD gating across the inter-word silences, and no words on silence/noise.
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
  final config = File('.dart_tool/package_config.json');
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
  final libFile =
      File.fromUri(pkgDir.resolve('linux/$arch/libsherpa-onnx-c-api.so'));
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
      for (final word in ['один', 'два', 'три', 'четыре', 'пять']) {
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
      for (final word in ['один', 'два', 'три', 'четыре', 'пять']) {
        expect(backgroundText, contains(word),
            reason: 'background missing $word in "$backgroundText"');
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
    } finally {
      await temp.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
