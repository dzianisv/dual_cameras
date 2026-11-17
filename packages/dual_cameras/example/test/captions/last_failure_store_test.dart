import 'dart:io';

import 'package:dual_cameras_example/captions/last_failure_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('LastFailureStore round-trips each kind to its own file', () async {
    final dir = await Directory.systemTemp.createTemp('last-failure-');
    addTearDown(() => dir.delete(recursive: true));
    final store = LastFailureStore(documentsDirectory: () async => dir);
    expect(await store.load(LastFailureKind.model), isNull);
    expect(await store.load(LastFailureKind.caption), isNull);

    const modelError = 'Caption model download failed: boom';
    await store.save(LastFailureKind.model, modelError);
    await store.save(LastFailureKind.caption, 'burn boom');
    expect(await store.load(LastFailureKind.model), modelError);
    expect(await store.load(LastFailureKind.caption), 'burn boom');
    expect(await File('${dir.path}/last_model_error.txt').readAsString(),
        'Caption model download failed: boom');
    expect(await File('${dir.path}/last_caption_error.txt').readAsString(),
        'burn boom');
  });

  test('LastFailureStore survives a restart (fresh instance, same dir)',
      () async {
    final dir = await Directory.systemTemp.createTemp('last-failure-');
    addTearDown(() => dir.delete(recursive: true));
    final writer = LastFailureStore(documentsDirectory: () async => dir);
    const modelError = 'Caption model download failed: boom';
    await writer.save(LastFailureKind.model, modelError);
    // A new store instance over the same directory is the restart: the
    // file is the only thing carried over.
    final reader = LastFailureStore(documentsDirectory: () async => dir);
    expect(await reader.load(LastFailureKind.model), modelError);
  });

  test('LastFailureStore clear drops the error and load is null again',
      () async {
    final dir = await Directory.systemTemp.createTemp('last-failure-');
    addTearDown(() => dir.delete(recursive: true));
    final store = LastFailureStore(documentsDirectory: () async => dir);
    await store.save(LastFailureKind.caption, 'burn boom');
    expect(await store.load(LastFailureKind.caption), 'burn boom');
    await store.clear(LastFailureKind.caption);
    expect(await store.load(LastFailureKind.caption), isNull);
    // Clearing one kind leaves the other untouched.
    await store.save(LastFailureKind.model, 'model boom');
    await store.clear(LastFailureKind.caption);
    expect(await store.load(LastFailureKind.model), 'model boom');
  });

  test('LastFailureStore load tolerates a missing directory', () async {
    final dir = await Directory.systemTemp.createTemp('last-failure-');
    await dir.delete(recursive: true);
    final store = LastFailureStore(documentsDirectory: () async => dir);
    expect(await store.load(LastFailureKind.model), isNull);
    // Best effort: saving into a missing directory must not throw.
    await store.save(LastFailureKind.model, 'boom');
    await store.clear(LastFailureKind.model);
  });
}
