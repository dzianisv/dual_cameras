import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'caption_models.dart';

/// Downloads the sherpa-onnx Whisper model on first use and caches it in the
/// app documents directory. The model is NOT bundled in the APK (size).
///
/// Model: `sherpa-onnx-whisper-base.en` (int8), ~100 MB total.
class ModelManager {
  static const _baseUrl =
      'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-base.en/resolve/main';
  static const _encoderFile = 'base.en-encoder.int8.onnx';
  static const _decoderFile = 'base.en-decoder.int8.onnx';
  static const _tokensFile = 'base.en-tokens.txt';
  static const _dirName = 'sherpa-whisper-base.en';

  /// Returns the model files, downloading any missing ones first.
  /// [onProgress] receives overall 0.0–1.0 download progress.
  Future<WhisperModelFiles> ensureModel({
    required void Function(double progress) onProgress,
  }) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_dirName');
    await dir.create(recursive: true);

    final files = [_encoderFile, _decoderFile, _tokensFile];
    final missing = files
        .where((f) => !File('${dir.path}/$f').existsSync())
        .toList();
    if (missing.isEmpty) {
      onProgress(1.0);
    } else {
      final client = http.Client();
      try {
        var done = 0;
        for (final name in missing) {
          await _download(client, '$_baseUrl/$name',
              File('${dir.path}/$name'), (p) {
            onProgress((done + p) / missing.length);
          });
          done++;
          onProgress(done / missing.length);
        }
      } finally {
        client.close();
      }
    }
    return WhisperModelFiles(
      encoder: '${dir.path}/$_encoderFile',
      decoder: '${dir.path}/$_decoderFile',
      tokens: '${dir.path}/$_tokensFile',
    );
  }

  Future<void> _download(
    http.Client client,
    String url,
    File dest,
    void Function(double progress) onProgress,
  ) async {
    final request = http.Request('GET', Uri.parse(url));
    final response = await client.send(request);
    if (response.statusCode != 200) {
      throw HttpException(
          'model download failed: HTTP ${response.statusCode} for $url');
    }
    final total = response.contentLength ?? -1;
    final sink = dest.openWrite();
    try {
      var received = 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress(received / total);
      }
    } finally {
      await sink.close();
    }
  }
}
