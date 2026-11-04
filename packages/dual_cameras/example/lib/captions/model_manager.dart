import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'caption_models.dart';

/// Downloads the model once; inference runs locally after preparation.
/// Files become cache hits only after a complete, nonempty download.
class ModelManager {
  ModelManager({
    http.Client Function()? clientFactory,
    Future<Directory> Function()? documentsDirectory,
  })  : _clientFactory = clientFactory ?? http.Client.new,
        _documentsDirectory =
            documentsDirectory ?? getApplicationDocumentsDirectory;

  final http.Client Function() _clientFactory;
  final Future<Directory> Function() _documentsDirectory;
  Future<WhisperModelFiles>? _inFlight;
  final Set<void Function(double)> _listeners = {};
  double _progress = 0;

  static const _baseUrl =
      'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-base.en/resolve/main';
  static const _encoderFile = 'base.en-encoder.int8.onnx';
  static const _decoderFile = 'base.en-decoder.int8.onnx';
  static const _tokensFile = 'base.en-tokens.txt';
  static const _dirName = 'sherpa-whisper-base.en';
  static const _timeout = Duration(seconds: 60);

  /// Concurrent callers share one download, each receiving progress updates.
  /// A failed attempt clears the in-flight state so Retry starts a new attempt.
  Future<WhisperModelFiles> ensureModel({
    required void Function(double progress) onProgress,
  }) async {
    if (_inFlight == null) _progress = 0;
    _listeners.add(onProgress);
    onProgress(_progress);
    final future = _inFlight ??= _prepare();
    try {
      return await future;
    } finally {
      _listeners.remove(onProgress);
      if (identical(_inFlight, future)) _inFlight = null;
    }
  }

  void _report(double value) {
    _progress = value.clamp(0.0, 1.0).toDouble();
    for (final listener in List<void Function(double)>.of(_listeners)) {
      listener(_progress);
    }
  }

  Future<bool> _isComplete(File file) async {
    if (!await file.exists()) return false;
    final receipt = File('${file.path}.size');
    if (!await receipt.exists()) return false;
    final expected = int.tryParse(await receipt.readAsString());
    return expected != null && expected > 0 && await file.length() == expected;
  }

  Future<WhisperModelFiles> _prepare() async {
    final docs = await _documentsDirectory();
    final dir = Directory('${docs.path}/$_dirName');
    await dir.create(recursive: true);
    const names = [_encoderFile, _decoderFile, _tokensFile];
    final missing = <String>[];
    for (final name in names) {
      if (!await _isComplete(File('${dir.path}/$name'))) missing.add(name);
    }
    if (missing.isNotEmpty) {
      final client = _clientFactory();
      try {
        for (var i = 0; i < missing.length; i++) {
          final name = missing[i];
          await _download(client, '$_baseUrl/$name', File('${dir.path}/$name'),
              (p) => _report((i + p) / missing.length));
          _report((i + 1) / missing.length);
        }
      } finally {
        client.close();
      }
    }
    _report(1.0);
    return WhisperModelFiles(
      encoder: '${dir.path}/$_encoderFile',
      decoder: '${dir.path}/$_decoderFile',
      tokens: '${dir.path}/$_tokensFile',
    );
  }

  Future<void> _download(http.Client client, String url, File dest,
      void Function(double) onProgress) async {
    final partial = File('${dest.path}.part');
    final receipt = File('${dest.path}.size');
    final receiptPartial = File('${receipt.path}.part');
    // Old versions accepted any existing file, including interrupted downloads.
    // Require a completion receipt rather than trusting those legacy files.
    if (await receipt.exists()) await receipt.delete();
    try {
      final response = await client
          .send(http.Request('GET', Uri.parse(url)))
          .timeout(_timeout);
      if (response.statusCode != 200) {
        throw HttpException('Model download failed: HTTP ${response.statusCode}');
      }
      final total = response.contentLength;
      final sink = partial.openWrite();
      var received = 0;
      try {
        await sink.addStream(response.stream.timeout(_timeout).map((chunk) {
          received += chunk.length;
          if (total != null && total > 0) {
            onProgress((received / total).clamp(0.0, 1.0).toDouble());
          }
          return chunk;
        }));
      } catch (_) {
        // addStream can close the underlying file after a source error.
        // A second close may throw too; preserve the original network error
        // and stack rather than replacing it with a cleanup exception.
        try {
          await sink.close();
        } catch (_) {
          // Best-effort cleanup; the outer finally removes the partial file.
        }
        rethrow;
      }
      await sink.close();
      if (received == 0 || (total != null && received != total)) {
        throw const HttpException('Model download was incomplete. Please retry.');
      }
      await partial.rename(dest.path);
      await receiptPartial.writeAsString('$received', flush: true);
      await receiptPartial.rename(receipt.path);
    } finally {
      if (await partial.exists()) await partial.delete();
      if (await receiptPartial.exists()) await receiptPartial.delete();
    }
  }
}
