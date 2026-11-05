import 'dart:io';

import 'package:dual_cameras_example/captions/model_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real HTTP interruption resumes safely after manager restart',
      (tester) async {
    final directory = await Directory.systemTemp.createTemp('caption-http-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <String>[];
    final serverErrors = <Object>[];
    var interrupted = false;
    var resumed = false;
    final serving = server.listen((request) async {
      try {
        requests.add(request.uri.path);
        final response = request.response;
        response.headers.set(HttpHeaders.etagHeader, '"fixture-v1"');
        if (!interrupted) {
          interrupted = true;
          response.contentLength = 6;
          response.add([1, 2]);
          await response.flush();
          final socket = await response.detachSocket();
          socket.destroy();
          return;
        }
        if (request.headers.value(HttpHeaders.rangeHeader) != null) {
          expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=2-');
          expect(
              request.headers.value(HttpHeaders.ifRangeHeader), '"fixture-v1"');
          resumed = true;
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes 2-5/6');
          response.contentLength = 4;
          response.add([3, 4, 5, 6]);
        } else {
          response.contentLength = 6;
          response.add([1, 2, 3, 4, 5, 6]);
        }
        await response.close();
      } catch (error) {
        serverErrors.add(error);
      }
    });
    addTearDown(() async {
      await server.close(force: true);
      await serving.cancel();
      await directory.delete(recursive: true);
    });
    ModelManager manager(int attempts) => ModelManager(
          baseUrl: 'http://127.0.0.1:${server.port}',
          documentsDirectory: () async => directory,
          maxAttempts: attempts,
          retryDelay: Duration.zero,
        );

    await expectLater(
      manager(1).ensureModel(onProgress: (_) {}),
      throwsA(isA<ModelDownloadException>()),
    );
    final partial = File('${directory.path}/sherpa-whisper-base.en/'
        'base.en-encoder.int8.onnx.part');
    expect(await partial.readAsBytes(), [1, 2]);
    expect(await File('${partial.path}.json').exists(), isTrue);
    expect(await File(partial.path.replaceFirst('.part', '.size')).exists(),
        isFalse);

    final progress = <double>[];
    final files = await manager(4).ensureModel(onProgress: progress.add);
    expect(resumed, isTrue);
    expect(requests, hasLength(4));
    for (final path in [files.encoder, files.decoder, files.tokens]) {
      expect(await File(path).readAsBytes(), [1, 2, 3, 4, 5, 6]);
      expect(await File('$path.size').readAsString(), '6');
      expect(await File('$path.part').exists(), isFalse);
    }
    expect(progress.last, 1.0);
    await manager(4).ensureModel(onProgress: (_) {});
    expect(requests, hasLength(4), reason: 'completed model is reused offline');
    expect(serverErrors, isEmpty);
  });
}
