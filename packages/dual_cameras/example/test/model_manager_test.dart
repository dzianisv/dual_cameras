import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:dual_cameras_example/captions/model_manager.dart';

void main() {
  late Directory temp;
  setUp(() async => temp = await Directory.systemTemp.createTemp('model-test-'));
  tearDown(() async => temp.delete(recursive: true));

  http.StreamedResponse ok() =>
      http.StreamedResponse(Stream.value([1, 2, 3]), 200, contentLength: 3);

  test('complete files are cached and offline reuse reports ready', () async {
    var requests = 0;
    final manager = ModelManager(
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
      documentsDirectory: () async => temp,
      clientFactory: () => MockClient.streaming((_, __) async {
        requests++;
        if (fail) {
          return http.StreamedResponse(
            Stream<List<int>>.fromIterable([[1]])
                .asyncExpand((chunk) async* {
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
        throwsA(isA<SocketException>()));
    expect(await temp.list(recursive: true).where((f) => f is File).toList(),
        isEmpty);
    fail = false;
    await manager.ensureModel(onProgress: (_) {});
    expect(requests, 4);
  });

  test('empty and truncated responses do not become cache hits', () async {
    for (final bytes in [<int>[], [1, 2]]) {
      final manager = ModelManager(
        documentsDirectory: () async => temp,
        clientFactory: () => MockClient.streaming((_, __) async =>
            http.StreamedResponse(Stream.value(bytes), 200, contentLength: 3)),
      );
      await expectLater(manager.ensureModel(onProgress: (_) {}),
          throwsA(isA<HttpException>()));
      expect(await temp.list(recursive: true).where((f) => f is File).toList(),
          isEmpty);
    }
  });

  test('legacy files without completion receipts are downloaded again', () async {
    final dir = await Directory('${temp.path}/sherpa-whisper-base.en').create();
    await File('${dir.path}/base.en-encoder.int8.onnx').writeAsBytes([9]);
    var requests = 0;
    final manager = ModelManager(
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

  test('startup and captions share an in-flight download and progress', () async {
    final gate = Completer<void>();
    var requests = 0;
    final manager = ModelManager(
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
}
