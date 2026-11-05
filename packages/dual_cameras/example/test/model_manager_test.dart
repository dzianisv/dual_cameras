import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:dual_cameras_example/captions/model_manager.dart';

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
      clientFactory: () => MockClient.streaming((_, __) async {
        requests++;
        return ok();
      }),
    );
    final first = await manager.ensureModel(onProgress: (_) {});
    expect(requests, 3);
    expect(await File(first.encoder).readAsBytes(), [1, 2, 3]);
    final progress = <double>[];
    await manager.ensureModel(onProgress: progress.add);
    expect(requests, 3);
    expect(progress.last, 1.0);
  });

  test('interrupted stream is not cached and a later call retries', () async {
    var fail = true;
    var requests = 0;
    final manager = ModelManager(
      maxAttempts: 1,
      retryDelay: Duration.zero,
      documentsDirectory: () async => temp,
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
    expect(requests, 4);
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
    final dir = await Directory('${temp.path}/sherpa-whisper-base.en').create();
    await File('${dir.path}/base.en-encoder.int8.onnx').writeAsBytes([9]);
    var requests = 0;
    final manager = ModelManager(
      maxAttempts: 1,
      retryDelay: Duration.zero,
      documentsDirectory: () async => temp,
      clientFactory: () => MockClient.streaming((_, __) async {
        requests++;
        return ok();
      }),
    );
    final files = await manager.ensureModel(onProgress: (_) {});
    expect(requests, 3);
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
    expect(requests, 3);
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
      clientFactory: () => MockClient.streaming((_, __) async {
        requests++;
        return ok();
      }),
    );
    final files = await manager.ensureModel(onProgress: (_) {});
    await File(files.encoder).writeAsBytes([]);
    await manager.ensureModel(onProgress: (_) {});
    expect(requests, 4);
  });
  test('connection closed retries and resumes only the validated partial',
      () async {
    var requests = 0;
    final manager = ModelManager(
      documentsDirectory: () async => temp,
      retryDelay: Duration.zero,
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
    expect(requests, 4);
    expect(await File('${model.encoder}.part').exists(), isFalse);
  });

  test('a server ignoring Range replaces partial data instead of appending',
      () async {
    var requests = 0;
    final manager = ModelManager(
      documentsDirectory: () async => temp,
      retryDelay: Duration.zero,
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
    expect(requests, 4);
  });

  test('partial survives a new manager and invalid Content-Range restarts',
      () async {
    final first = ModelManager(
        maxAttempts: 1,
        documentsDirectory: () async => temp,
        clientFactory: () => MockClient.streaming((_, __) async =>
            http.StreamedResponse(Stream.value([1]), 200,
                contentLength: 3, headers: {'etag': '"v1"'})));
    await expectLater(first.ensureModel(onProgress: (_) {}),
        throwsA(isA<ModelDownloadException>()));
    var requests = 0;
    final next = ModelManager(
        documentsDirectory: () async => temp,
        retryDelay: Duration.zero,
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
    expect(requests, 4);
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
      expect(requests, 5);
    });
  }

  test('network errors never expose signed URLs or raw exceptions', () async {
    final manager = ModelManager(
        maxAttempts: 1,
        documentsDirectory: () async => temp,
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
}
