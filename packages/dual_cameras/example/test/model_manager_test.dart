import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:dual_cameras_example/captions/model_manager.dart';

/// SHA-256 of the three bytes [1, 2, 3] every mock download serves.
const _testSha256 =
    '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81';

/// Test specs with the production file names and cache layout, served by the
/// mocks with [size] bytes hashing to [sha256].
List<ModelFileSpec> _testFiles({int size = 3, String? sha256 = _testSha256}) => [
      ModelFileSpec(
          key: 'encoder',
          name: 'base-encoder.int8.onnx',
          url: 'https://example.test/base-encoder.int8.onnx',
          size: size,
          sha256: sha256),
      ModelFileSpec(
          key: 'decoder',
          name: 'base-decoder.int8.onnx',
          url: 'https://example.test/base-decoder.int8.onnx',
          size: size,
          sha256: sha256),
      ModelFileSpec(
          key: 'tokens',
          name: 'base-tokens.txt',
          url: 'https://example.test/base-tokens.txt',
          size: size,
          sha256: sha256),
      ModelFileSpec(
          key: 'vad',
          name: 'silero_vad.onnx',
          url: 'https://example.test/silero_vad.onnx',
          size: size,
          sha256: sha256),
    ];

void main() {
  late Directory temp;
  setUp(
      () async => temp = await Directory.systemTemp.createTemp('model-test-'));
  tearDown(() async => temp.delete(recursive: true));

  http.StreamedResponse ok() =>
      http.StreamedResponse(Stream.value([1, 2, 3]), 200, contentLength: 3);

  test('complete files are cached and offline reuse reports ready', () async {
    var requests = 0;
    final manager = ModelManager(
      maxAttempts: 1,
      retryDelay: Duration.zero,
      documentsDirectory: () async => temp,
      files: _testFiles(),
      clientFactory: () => MockClient.streaming((_, __) async {
        requests++;
        return ok();
      }),
    );
    final first = await manager.ensureModel(onProgress: (_) {});
    expect(requests, 4);
    expect(await File(first.encoder).readAsBytes(), [1, 2, 3]);
    final progress = <double>[];
    await manager.ensureModel(onProgress: progress.add);
    expect(requests, 4);
    expect(progress.last, 1.0);
  });

  test('interrupted stream is not cached and a later call retries', () async {
    var fail = true;
    var requests = 0;
    final manager = ModelManager(
      maxAttempts: 1,
      retryDelay: Duration.zero,
      documentsDirectory: () async => temp,
      files: _testFiles(),
      clientFactory: () => MockClient.streaming((_, __) async {
        requests++;
        if (fail) {
          return http.StreamedResponse(
            Stream<List<int>>.fromIterable([
              [1]
            ]).asyncExpand((chunk) async* {
              yield chunk;
              throw const SocketException('interrupted');
            }),
            200,
            contentLength: 3,
          );
        }
        return ok();
      }),
    );
    await expectLater(manager.ensureModel(onProgress: (_) {}),
        throwsA(isA<ModelDownloadException>()));
    expect(await temp.list(recursive: true).where((f) => f is File).toList(),
        isEmpty);
    fail = false;
    await manager.ensureModel(onProgress: (_) {});
    expect(requests, 5);
  });

  test('empty and truncated responses do not become cache hits', () async {
    for (final bytes in [
      <int>[],
      [1, 2]
    ]) {
      final manager = ModelManager(
        maxAttempts: 1,
        retryDelay: Duration.zero,
        documentsDirectory: () async => temp,
        files: _testFiles(),
        clientFactory: () => MockClient.streaming((_, __) async =>
            http.StreamedResponse(Stream.value(bytes), 200, contentLength: 3)),
      );
      await expectLater(manager.ensureModel(onProgress: (_) {}),
          throwsA(isA<ModelDownloadException>()));
      expect(await temp.list(recursive: true).where((f) => f is File).toList(),
          isEmpty);
    }
  });

  test('legacy files without completion receipts are downloaded again',
      () async {
    final dir = await Directory('${temp.path}/sherpa-whisper-base').create();
    await File('${dir.path}/base-encoder.int8.onnx').writeAsBytes([9]);
    var requests = 0;
    final manager = ModelManager(
      maxAttempts: 1,
      retryDelay: Duration.zero,
      documentsDirectory: () async => temp,
      files: _testFiles(),
      clientFactory: () => MockClient.streaming((_, __) async {
        requests++;
        return ok();
      }),
    );
    final files = await manager.ensureModel(onProgress: (_) {});
    expect(requests, 4);
    expect(await File(files.encoder).readAsBytes(), [1, 2, 3]);
  });

  test('startup and captions share an in-flight download and progress',
      () async {
    final gate = Completer<void>();
    var requests = 0;
    final manager = ModelManager(
      maxAttempts: 1,
      retryDelay: Duration.zero,
      documentsDirectory: () async => temp,
      files: _testFiles(),
      clientFactory: () => MockClient.streaming((_, __) async {
        requests++;
        await gate.future;
        return ok();
      }),
    );
    final firstProgress = <double>[];
    final secondProgress = <double>[];
    final a = manager.ensureModel(onProgress: firstProgress.add);
    final b = manager.ensureModel(onProgress: secondProgress.add);
    gate.complete();
    final files = await Future.wait([a, b]);
    expect(requests, 4);
    expect(files.first.encoder, files.last.encoder);
    expect(firstProgress.last, 1.0);
    expect(secondProgress.last, 1.0);
  });

  test('modified cached length invalidates only the affected file', () async {
    var requests = 0;
    final manager = ModelManager(
      maxAttempts: 1,
      retryDelay: Duration.zero,
      documentsDirectory: () async => temp,
      files: _testFiles(),
      clientFactory: () => MockClient.streaming((_, __) async {
        requests++;
        return ok();
      }),
    );
    final files = await manager.ensureModel(onProgress: (_) {});
    await File(files.encoder).writeAsBytes([]);
    await manager.ensureModel(onProgress: (_) {});
    expect(requests, 5);
  });
  test('connection closed retries and resumes only the validated partial',
      () async {
    var requests = 0;
    final manager = ModelManager(
      documentsDirectory: () async => temp,
      retryDelay: Duration.zero,
      files: _testFiles(),
      clientFactory: () => MockClient.streaming((request, _) async {
        requests++;
        if (requests == 1) {
          return http.StreamedResponse(() async* {
            yield [1];
            throw http.ClientException('Connection closed',
                Uri.parse('https://cdn.example/model?Signature=private'));
          }(), 200, contentLength: 3, headers: {'etag': '"version1"'});
        }
        if (requests == 2) {
          expect(request.headers['range'], 'bytes=1-');
          expect(request.headers['if-range'], '"version1"');
          return http.StreamedResponse(Stream.value([2, 3]), 206,
              contentLength: 2,
              headers: {'content-range': 'bytes 1-2/3', 'etag': '"version1"'});
        }
        return ok();
      }),
    );
    final model = await manager.ensureModel(onProgress: (_) {});
    expect(await File(model.encoder).readAsBytes(), [1, 2, 3]);
    expect(requests, 5);
    expect(await File('${model.encoder}.part').exists(), isFalse);
  });

  test('a server ignoring Range replaces partial data instead of appending',
      () async {
    var requests = 0;
    final manager = ModelManager(
      documentsDirectory: () async => temp,
      retryDelay: Duration.zero,
      files: _testFiles(),
      clientFactory: () => MockClient.streaming((request, _) async {
        requests++;
        if (requests == 1) {
          return http.StreamedResponse(() async* {
            yield [9];
            throw const SocketException('Connection closed');
          }(), 200, contentLength: 3, headers: {'etag': '"old"'});
        }
        return ok();
      }),
    );
    final model = await manager.ensureModel(onProgress: (_) {});
    expect(await File(model.encoder).readAsBytes(), [1, 2, 3]);
    expect(requests, 5);
  });

  test('partial survives a new manager and invalid Content-Range restarts',
      () async {
    final first = ModelManager(
        maxAttempts: 1,
        documentsDirectory: () async => temp,
        files: _testFiles(),
        clientFactory: () => MockClient.streaming((_, __) async =>
            http.StreamedResponse(Stream.value([1]), 200,
                contentLength: 3, headers: {'etag': '"v1"'})));
    await expectLater(first.ensureModel(onProgress: (_) {}),
        throwsA(isA<ModelDownloadException>()));
    var requests = 0;
    final next = ModelManager(
        documentsDirectory: () async => temp,
        retryDelay: Duration.zero,
        files: _testFiles(),
        clientFactory: () => MockClient.streaming((request, _) async {
              requests++;
              if (requests == 1) {
                expect(request.headers['range'], 'bytes=1-');
                return http.StreamedResponse(Stream.value([8, 9]), 206,
                    contentLength: 2,
                    headers: {'content-range': 'bytes 0-1/3'});
              }
              expect(request.headers['range'], isNull);
              return ok();
            }));
    final model = await next.ensureModel(onProgress: (_) {});
    expect(await File(model.encoder).readAsBytes(), [1, 2, 3]);
    expect(requests, 5);
  });

  for (final header in ['etag', 'last-modified']) {
    test('changed $header on resumed response discards partial bytes',
        () async {
      final original =
          header == 'etag' ? '"v1"' : 'Mon, 01 Jun 2026 00:00:00 GMT';
      final changed =
          header == 'etag' ? '"v2"' : 'Tue, 02 Jun 2026 00:00:00 GMT';
      var requests = 0;
      final manager = ModelManager(
        documentsDirectory: () async => temp,
        retryDelay: Duration.zero,
        files: _testFiles(),
        clientFactory: () => MockClient.streaming((request, _) async {
          requests++;
          if (requests == 1) {
            return http.StreamedResponse(Stream.value([9]), 200,
                contentLength: 3, headers: {header: original});
          }
          if (requests == 2) {
            expect(request.headers['range'], 'bytes=1-');
            expect(request.headers['if-range'], original);
            return http.StreamedResponse(Stream.value([8, 7]), 206,
                contentLength: 2,
                headers: {'content-range': 'bytes 1-2/3', header: changed});
          }
          expect(request.headers['range'], isNull);
          return ok();
        }),
      );
      final model = await manager.ensureModel(onProgress: (_) {});
      expect(await File(model.encoder).readAsBytes(), [1, 2, 3]);
      expect(requests, 6);
    });
  }

  test('network errors never expose signed URLs or raw exceptions', () async {
    final manager = ModelManager(
        maxAttempts: 1,
        documentsDirectory: () async => temp,
        files: _testFiles(),
        clientFactory: () => MockClient.streaming((_, __) async {
              throw http.ClientException('connection closed',
                  Uri.parse('https://cdn.example/?Signature=secret'));
            }));
    try {
      await manager.ensureModel(onProgress: (_) {});
      fail('must fail');
    } catch (error) {
      expect('$error', contains('automatic retries'));
      expect('$error', isNot(contains('Signature')));
      expect('$error', isNot(contains('https://')));
      expect('$error', isNot(contains('ClientException')));
    }
  });

  test('Stop prevents receipts and subsequent download requests', () async {
    var requests = 0;
    late ModelManager manager;
    manager = ModelManager(
        documentsDirectory: () async => temp,
        retryDelay: Duration.zero,
        files: _testFiles(),
        clientFactory: () => MockClient.streaming((_, __) async {
              requests++;
              return http.StreamedResponse(() async* {
                yield [1];
                manager.cancel();
                yield [2, 3];
              }(), 200, contentLength: 3, headers: {'etag': '"v1"'});
            }));
    await expectLater(manager.ensureModel(onProgress: (_) {}),
        throwsA(isA<ModelDownloadException>()));
    expect(requests, 1);
    expect(
        await temp
            .list(recursive: true)
            .where((f) => f.path.endsWith('.size'))
            .toList(),
        isEmpty);
  });

  test('multilingual files land in the new cache dir, never the base.en one',
      () async {
    final manager = ModelManager(
      maxAttempts: 1,
      retryDelay: Duration.zero,
      documentsDirectory: () async => temp,
      files: _testFiles(),
      clientFactory: () => MockClient.streaming((_, __) async => ok()),
    );
    final files = await manager.ensureModel(onProgress: (_) {});
    expect(files.encoder, contains('sherpa-whisper-base/base-encoder.int8.onnx'));
    expect(files.decoder, contains('sherpa-whisper-base/base-decoder.int8.onnx'));
    expect(files.tokens, contains('sherpa-whisper-base/base-tokens.txt'));
    expect(files.vad, contains('sherpa-whisper-base/silero_vad.onnx'));
    expect(await Directory('${temp.path}/sherpa-whisper-base.en').exists(),
        isFalse);
  });

  test('hash mismatch on download is rejected and leaves no receipt',
      () async {
    final manager = ModelManager(
      maxAttempts: 1,
      retryDelay: Duration.zero,
      documentsDirectory: () async => temp,
      files: _testFiles(),
      // Same 3-byte length the pin expects, different bytes: the size check
      // passes, so only the hash check can reject this.
      clientFactory: () => MockClient.streaming((_, __) async =>
          http.StreamedResponse(Stream.value([4, 5, 6]), 200,
              contentLength: 3)),
    );
    await expectLater(manager.ensureModel(onProgress: (_) {}),
        throwsA(isA<ModelDownloadException>()));
    expect(await temp.list(recursive: true).where((f) => f is File).toList(),
        isEmpty);
  });

  test('hash mismatch on cache hit re-downloads the affected file', () async {
    var requests = 0;
    final manager = ModelManager(
      maxAttempts: 1,
      retryDelay: Duration.zero,
      documentsDirectory: () async => temp,
      files: _testFiles(),
      clientFactory: () => MockClient.streaming((_, __) async {
        requests++;
        return ok();
      }),
    );
    final files = await manager.ensureModel(onProgress: (_) {});
    expect(requests, 4);
    // Corrupt the cached bytes without touching the receipt: the receipt
    // still claims the pinned hash, so the cache hit must fail verification.
    await File(files.encoder).writeAsBytes([4, 5, 6]);
    await manager.ensureModel(onProgress: (_) {});
    expect(requests, 5);
    expect(await File(files.encoder).readAsBytes(), [1, 2, 3]);
  });

  test('a stopped download can be retried', () async {
    // The latch reset in ensureModel: a stop must abort the in-flight
    // attempt (the stop exception) without poisoning the next one.
    var requests = 0;
    final gate = Completer<void>();
    final sendCalled = Completer<void>();
    late ModelManager manager;
    manager = ModelManager(
        documentsDirectory: () async => temp,
        retryDelay: Duration.zero,
        files: _testFiles(),
        clientFactory: () => MockClient.streaming((_, __) async {
              requests++;
              if (requests == 1) {
                if (!sendCalled.isCompleted) sendCalled.complete();
                // Hang in the stream until the test releases it.
                return http.StreamedResponse(
                    Stream<List<int>>.fromFuture(
                        gate.future.then((_) => [1, 2, 3])),
                    200,
                    contentLength: 3);
              }
              return ok();
            }));
    final first = manager.ensureModel(onProgress: (_) {});
    await sendCalled.future;
    manager.cancel();
    expect(manager.isCancelled, isTrue);
    // The chunk arrives after the stop: the stream's per-chunk check
    // throws the stop exception instead of completing the file.
    gate.complete();
    await expectLater(
        first,
        throwsA(isA<ModelDownloadException>().having(
            (e) => e.message, 'message', 'Caption job stopped')));
    expect(requests, 1);
    // Retry: the stop must not poison the fresh attempt.
    final files = await manager.ensureModel(onProgress: (_) {});
    expect(manager.isCancelled, isFalse);
    expect(await File(files.encoder).readAsBytes(), [1, 2, 3]);
    expect(requests, 5);
  });

  test('legacy plain-number receipt is re-downloaded', () async {
    final dir = await Directory('${temp.path}/sherpa-whisper-base').create();
    await File('${dir.path}/base-encoder.int8.onnx').writeAsBytes([1, 2, 3]);
    await File('${dir.path}/base-encoder.int8.onnx.size')
        .writeAsString('3');
    var requests = 0;
    final manager = ModelManager(
      maxAttempts: 1,
      retryDelay: Duration.zero,
      documentsDirectory: () async => temp,
      files: _testFiles(),
      clientFactory: () => MockClient.streaming((_, __) async {
        requests++;
        return ok();
      }),
    );
    final files = await manager.ensureModel(onProgress: (_) {});
    expect(requests, 4);
    expect(await File(files.encoder).readAsBytes(), [1, 2, 3]);
    final receipt =
        await File('${files.encoder}.size').readAsString();
    expect(receipt, contains('sha256'));
  });
}
