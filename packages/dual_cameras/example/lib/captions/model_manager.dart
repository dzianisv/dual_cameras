import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'caption_models.dart';

class ModelDownloadException implements Exception {
  const ModelDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Downloads the model once. Interrupted transfers retry automatically and
/// resume only with a server validator, so bytes from different files cannot
/// be combined. Neither network exceptions nor signed CDN URLs reach the UI.
class ModelManager {
  ModelManager({
    http.Client Function()? clientFactory,
    Future<Directory> Function()? documentsDirectory,
    this.maxAttempts = 4,
    this.retryDelay = const Duration(seconds: 1),
  })  : _clientFactory = clientFactory ?? http.Client.new,
        _documentsDirectory =
            documentsDirectory ?? getApplicationDocumentsDirectory;

  final http.Client Function() _clientFactory;
  final Future<Directory> Function() _documentsDirectory;
  final int maxAttempts;
  final Duration retryDelay;
  Future<WhisperModelFiles>? _inFlight;
  final Set<void Function(double)> _listeners = {};
  double _progress = 0;
  bool _cancelled = false;
  http.Client? _activeClient;

  static const _baseUrl =
      'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-base.en/resolve/main';
  static const _encoderFile = 'base.en-encoder.int8.onnx';
  static const _decoderFile = 'base.en-decoder.int8.onnx';
  static const _tokensFile = 'base.en-tokens.txt';
  static const _dirName = 'sherpa-whisper-base.en';
  static const _timeout = Duration(seconds: 60);

  void cancel() {
    _cancelled = true;
    _activeClient?.close();
  }

  void _checkCancelled() {
    if (_cancelled) throw const ModelDownloadException('Caption job stopped');
  }

  Future<WhisperModelFiles> ensureModel({
    required void Function(double progress) onProgress,
  }) async {
    _checkCancelled();
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
    try {
      final docs = await _documentsDirectory();
      final dir = Directory('${docs.path}/$_dirName');
      await dir.create(recursive: true);
      const names = [_encoderFile, _decoderFile, _tokensFile];
      final missing = <String>[];
      for (final name in names) {
        if (!await _isComplete(File('${dir.path}/$name'))) missing.add(name);
      }
      for (var i = 0; i < missing.length; i++) {
        _checkCancelled();
        final name = missing[i];
        await _downloadWithRetry('$_baseUrl/$name', File('${dir.path}/$name'),
            (p) => _report((i + p) / missing.length));
        _report((i + 1) / missing.length);
      }
      _checkCancelled();
      _report(1.0);
      return WhisperModelFiles(
        encoder: '${dir.path}/$_encoderFile',
        decoder: '${dir.path}/$_decoderFile',
        tokens: '${dir.path}/$_tokensFile',
      );
    } on ModelDownloadException {
      rethrow;
    } on FileSystemException {
      throw const ModelDownloadException(
          'Could not store the speech model. Check free storage and retry.');
    } catch (_) {
      throw const ModelDownloadException(
          'Speech model unavailable. Check your connection and retry.');
    }
  }

  Future<void> _downloadWithRetry(
      String url, File dest, void Function(double) onProgress) async {
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      _checkCancelled();
      final client = _clientFactory();
      _activeClient = client;
      try {
        await _download(client, url, dest, onProgress);
        return;
      } on FileSystemException {
        rethrow;
      } catch (_) {
        _checkCancelled();
        if (attempt + 1 >= maxAttempts) {
          throw const ModelDownloadException(
              'Speech model download interrupted after automatic retries. '
              'Check your connection and tap Retry. Saved download progress is kept.');
        }
      } finally {
        client.close();
        _activeClient = null;
      }
      await Future<void>.delayed(retryDelay * (1 << attempt));
    }
    throw const ModelDownloadException(
        'Speech model download could not start.');
  }

  Future<void> _download(http.Client client, String url, File dest,
      void Function(double) onProgress) async {
    final partial = File('${dest.path}.part');
    final resume = File('${dest.path}.part.json');
    final receipt = File('${dest.path}.size');
    final receiptPartial = File('${receipt.path}.part');
    Future<void> resetPartial() async {
      if (await partial.exists()) await partial.delete();
      if (await resume.exists()) await resume.delete();
    }

    var offset = 0;
    String? validator;
    int? expectedTotal;
    try {
      if (await partial.exists() && await resume.exists()) {
        final metadata = jsonDecode(await resume.readAsString()) as Map;
        validator = metadata['validator'] as String?;
        expectedTotal = metadata['total'] as int?;
        offset = await partial.length();
        if (validator == null ||
            validator.isEmpty ||
            expectedTotal == null ||
            offset <= 0 ||
            offset >= expectedTotal) {
          offset = 0;
        }
      }
    } on FormatException {
      offset = 0;
    } on TypeError {
      offset = 0;
    }
    if (offset == 0) {
      await resetPartial();
      validator = null;
      expectedTotal = null;
    }
    if (await receipt.exists()) await receipt.delete();
    final request = http.Request('GET', Uri.parse(url));
    request.headers['Accept-Encoding'] = 'identity';
    if (offset > 0) {
      request.headers['Range'] = 'bytes=$offset-';
      request.headers['If-Range'] = validator!;
    }
    final response = await client.send(request).timeout(_timeout);
    _checkCancelled();
    if (response.statusCode == 416) {
      await resetPartial();
      throw const ModelDownloadException('Restarting speech model download.');
    }
    if (response.statusCode == 206) {
      final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
          .firstMatch(response.headers['content-range'] ?? '');
      final returnedValidator = validator?.startsWith('"') == true
          ? response.headers['etag']
          : response.headers['last-modified'];
      if ((returnedValidator != null && returnedValidator != validator) ||
          offset == 0 ||
          range == null ||
          int.parse(range[1]!) != offset ||
          int.parse(range[3]!) != expectedTotal ||
          int.parse(range[2]!) != expectedTotal! - 1) {
        await resetPartial();
        throw const ModelDownloadException('Restarting speech model download.');
      }
    } else if (response.statusCode == 200) {
      offset =
          0; // Range ignored or file changed: never append a full response.
      expectedTotal = response.contentLength;
      final etag = response.headers['etag'];
      validator = etag != null && !etag.startsWith('W/')
          ? etag
          : response.headers['last-modified'];
      await resetPartial();
    } else {
      throw const ModelDownloadException('Speech model server unavailable.');
    }
    final canResume =
        validator != null && expectedTotal != null && expectedTotal > 0;
    if (canResume) {
      await resume.writeAsString(
          jsonEncode({'validator': validator, 'total': expectedTotal}),
          flush: true);
    }
    var received = offset;
    final sink =
        partial.openWrite(mode: offset > 0 ? FileMode.append : FileMode.write);
    var complete = false;
    try {
      try {
        await sink.addStream(response.stream.timeout(_timeout).map((chunk) {
          _checkCancelled();
          received += chunk.length;
          if (expectedTotal != null && expectedTotal > 0) {
            onProgress((received / expectedTotal).clamp(0.0, 1.0).toDouble());
          }
          return chunk;
        }));
      } catch (_) {
        // Preserve the transfer error if addStream already closed its sink.
        try {
          await sink.close();
        } catch (_) {}
        rethrow;
      }
      await sink.close();
      _checkCancelled();
      if (received == 0 ||
          (expectedTotal != null && received != expectedTotal)) {
        throw const ModelDownloadException(
            'Speech model download was incomplete.');
      }
      await partial.rename(dest.path);
      await receiptPartial.writeAsString('$received', flush: true);
      await receiptPartial.rename(receipt.path);
      complete = true;
    } finally {
      if (complete || !canResume || received >= expectedTotal) {
        await resetPartial();
      }
      if (await receiptPartial.exists()) await receiptPartial.delete();
    }
  }
}
