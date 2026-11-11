import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'caption_models.dart';

class ModelDownloadException implements Exception {
  const ModelDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One model file to download, with its pinned size and content hash.
///
/// [size] and [sha256] are verified after download and on every cache hit.
/// A null [sha256] means the Hub API did not publish a content hash for the
/// file (only its size is pinned); the receipt still records the hash of the
/// bytes actually downloaded, so later corruption is detected and a pin can
/// be added without re-downloading. A null [size] skips the size check.
class ModelFileSpec {
  const ModelFileSpec({
    required this.key,
    required this.name,
    required this.url,
    this.size,
    this.sha256,
  });

  /// 'encoder' | 'decoder' | 'tokens' | 'vad'.
  final String key;
  final String name;
  final String url;
  final int? size;
  final String? sha256;
}

/// Downloads the model once. Interrupted transfers retry automatically and
/// resume only with a server validator, so bytes from different files cannot
/// be combined. Neither network exceptions nor signed CDN URLs reach the UI.
///
/// The multilingual Whisper base model (not base.en) plus the Silero VAD
/// model are downloaded into a fresh directory, so an old base.en cache can
/// never be reused. Every file is verified by size and SHA-256 after download
/// and on cache hit; a mismatch is discarded and re-downloaded, never trusted.
class ModelManager {
  ModelManager({
    http.Client Function()? clientFactory,
    Future<Directory> Function()? documentsDirectory,
    this.baseUrl = _defaultWhisperBaseUrl,
    this.vadBaseUrl = _defaultVadBaseUrl,
    this.maxAttempts = 4,
    this.retryDelay = const Duration(seconds: 1),
    List<ModelFileSpec>? files,
  })  : _clientFactory = clientFactory ?? http.Client.new,
        _documentsDirectory =
            documentsDirectory ?? getApplicationDocumentsDirectory,
        _files = files ?? _defaultFiles(baseUrl, vadBaseUrl);

  final http.Client Function() _clientFactory;
  final Future<Directory> Function() _documentsDirectory;

  /// Override only for controlled download integration tests.
  final String baseUrl;

  /// Override only for controlled download integration tests.
  final String vadBaseUrl;
  final int maxAttempts;
  final Duration retryDelay;
  final List<ModelFileSpec> _files;
  Future<WhisperModelFiles>? _inFlight;
  final Set<void Function(double)> _listeners = {};
  double _progress = 0;
  bool _cancelled = false;
  http.Client? _activeClient;

  static const _defaultWhisperBaseUrl =
      'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-base/resolve/main';
  static const _defaultVadBaseUrl =
      'https://huggingface.co/csukuangfj/vad/resolve/main';
  static const _dirName = 'sherpa-whisper-base';
  static const _timeout = Duration(seconds: 60);

  /// Production file list with sizes and hashes pinned from the HuggingFace
  /// Hub tree API (2026-11-11). The int8 encoder/decoder hashes are the
  /// files' LFS oids, which are the SHA-256 of the file content — the CI host
  /// check cross-checks this claim by hashing the downloaded bytes.
  /// base-tokens.txt and silero_vad.onnx have no content hash in the Hub API
  /// response (tokens only carries a git blob oid, which is not a content
  /// hash; the VAD LFS oid was truncated in the API read), so only their
  /// sizes are pinned here. Their SHA-256 must be taken from a CI download
  /// and pinned afterwards — see NOTES.md.
  static List<ModelFileSpec> _defaultFiles(
      String whisperBase, String vadBase) {
    return [
      ModelFileSpec(
        key: 'encoder',
        name: 'base-encoder.int8.onnx',
        url: '$whisperBase/base-encoder.int8.onnx',
        size: 29120534,
        sha256:
            '0b8fb1304b6109976038efff5ace81720e00386f3ff6b54ee8c75291ca0a1e11',
      ),
      ModelFileSpec(
        key: 'decoder',
        name: 'base-decoder.int8.onnx',
        url: '$whisperBase/base-decoder.int8.onnx',
        size: 130672026,
        sha256:
            '9759d217388a01b3a4c7c15533201067b48ae819c4daafc8624e64b9409dc02d',
      ),
      ModelFileSpec(
        key: 'tokens',
        name: 'base-tokens.txt',
        url: '$whisperBase/base-tokens.txt',
        size: 816730,
        // No content hash published by the Hub API; pin from CI download.
        sha256: null,
      ),
      ModelFileSpec(
        key: 'vad',
        name: 'silero_vad.onnx',
        url: '$vadBase/silero_vad.onnx',
        size: 1807522,
        // No content hash pinned yet; pin from CI download.
        sha256: null,
      ),
    ];
  }

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

  static Future<String> _sha256Hex(File file) async {
    final digest = await crypto.sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  /// A cached file is complete only if its receipt matches the pinned size
  /// and hash, and the bytes on disk still hash to the receipt's hash.
  /// Legacy plain-number receipts fail JSON parsing and are re-downloaded.
  Future<bool> _isComplete(File file, ModelFileSpec spec) async {
    if (!await file.exists()) return false;
    final receipt = File('${file.path}.size');
    if (!await receipt.exists()) return false;
    try {
      final data = jsonDecode(await receipt.readAsString()) as Map;
      final size = data['size'] as int?;
      final hash = data['sha256'] as String?;
      if (size == null || size <= 0) return false;
      if (await file.length() != size) return false;
      if (spec.size != null && size != spec.size) return false;
      if (spec.sha256 != null && hash != spec.sha256) return false;
      if (hash != null && await _sha256Hex(file) != hash) return false;
      return true;
    } on FormatException {
      return false;
    } on TypeError {
      return false;
    }
  }

  Future<WhisperModelFiles> _prepare() async {
    try {
      final docs = await _documentsDirectory();
      final dir = Directory('${docs.path}/$_dirName');
      await dir.create(recursive: true);
      final paths = <String, String>{};
      final missing = <ModelFileSpec>[];
      for (final spec in _files) {
        final file = File('${dir.path}/${spec.name}');
        paths[spec.key] = file.path;
        if (!await _isComplete(file, spec)) missing.add(spec);
      }
      for (var i = 0; i < missing.length; i++) {
        _checkCancelled();
        final spec = missing[i];
        await _downloadWithRetry(spec, File('${dir.path}/${spec.name}'),
            (p) => _report((i + p) / missing.length));
        _report((i + 1) / missing.length);
      }
      _checkCancelled();
      _report(1.0);
      return WhisperModelFiles(
        encoder: paths['encoder']!,
        decoder: paths['decoder']!,
        tokens: paths['tokens']!,
        vad: paths['vad']!,
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

  Future<void> _downloadWithRetry(ModelFileSpec spec, File dest,
      void Function(double) onProgress) async {
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      _checkCancelled();
      final client = _clientFactory();
      _activeClient = client;
      try {
        await _download(client, spec, dest, onProgress);
        return;
      } on FileSystemException {
        rethrow;
      } catch (error) {
        _checkCancelled();
        if (attempt + 1 >= maxAttempts) {
          // Preserve a specific failure cause (e.g. a hash mismatch) instead
          // of replacing it with the generic retry message.
          if (error is ModelDownloadException) rethrow;
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

  Future<void> _download(http.Client client, ModelFileSpec spec, File dest,
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
            offset >= expectedTotal ||
            (spec.size != null && expectedTotal != spec.size)) {
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
    final request = http.Request('GET', Uri.parse(spec.url));
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
    // The file on the server must be the pinned file; a different size means
    // it changed upstream and the pin no longer describes it.
    if (spec.size != null &&
        expectedTotal != null &&
        expectedTotal != spec.size) {
      await resetPartial();
      throw const ModelDownloadException(
          'Speech model changed on the server. Check for an app update.');
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
      // Verify the pinned size and hash before the file can become a cache
      // hit. A mismatch is discarded, never trusted.
      if (spec.size != null && received != spec.size) {
        await dest.delete();
        throw const ModelDownloadException(
            'Speech model failed verification. Check your connection and retry.');
      }
      final digest = await _sha256Hex(dest);
      if (spec.sha256 != null && digest != spec.sha256) {
        await dest.delete();
        throw const ModelDownloadException(
            'Speech model failed verification. Check your connection and retry.');
      }
      await receiptPartial.writeAsString(
          jsonEncode({'size': received, 'sha256': digest}),
          flush: true);
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
