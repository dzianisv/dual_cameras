import 'dart:io';

import 'package:dual_cameras_example/captions/caption_language.dart';
import 'package:dual_cameras_example/captions/caption_language_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CaptionLanguage codes are the sherpa-onnx language values', () {
    expect(CaptionLanguage.auto.code, '');
    expect(CaptionLanguage.russian.code, 'ru');
    expect(CaptionLanguage.english.code, 'en');
    expect(CaptionLanguage.values.map((value) => value.label).toList(),
        ['Auto', 'Русский', 'English']);
  });

  test('CaptionLanguage.fromCode falls back to Auto', () {
    expect(CaptionLanguage.fromCode(''), CaptionLanguage.auto);
    expect(CaptionLanguage.fromCode('ru'), CaptionLanguage.russian);
    expect(CaptionLanguage.fromCode('en'), CaptionLanguage.english);
    expect(CaptionLanguage.fromCode(null), CaptionLanguage.auto);
    expect(CaptionLanguage.fromCode('xx'), CaptionLanguage.auto);
    expect(CaptionLanguage.fromCode('RU'), CaptionLanguage.auto);
  });

  test('CaptionLanguageStore round-trips the chosen language', () async {
    final dir = await Directory.systemTemp.createTemp('caption-lang-');
    addTearDown(() => dir.delete(recursive: true));
    final store =
        CaptionLanguageStore(documentsDirectory: () async => dir);
    expect(await store.load(), CaptionLanguage.auto);
    await store.save(CaptionLanguage.russian);
    expect(await store.load(), CaptionLanguage.russian);
    expect(await File('${dir.path}/caption_language.txt').readAsString(),
        'ru');
    await store.save(CaptionLanguage.english);
    expect(await store.load(), CaptionLanguage.english);
    await store.save(CaptionLanguage.auto);
    expect(await store.load(), CaptionLanguage.auto);
  });

  test('CaptionLanguageStore load tolerates a corrupt file', () async {
    final dir = await Directory.systemTemp.createTemp('caption-lang-');
    addTearDown(() => dir.delete(recursive: true));
    await File('${dir.path}/caption_language.txt')
        .writeAsString('nonsense\n');
    final store =
        CaptionLanguageStore(documentsDirectory: () async => dir);
    expect(await store.load(), CaptionLanguage.auto);
  });
}
