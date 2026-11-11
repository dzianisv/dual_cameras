import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'caption_language.dart';

/// Persists the caption language across sessions.
///
/// One line of text (`auto`, `ru` or `en`) in a file under the app
/// documents directory — `path_provider` is already a dependency, so this
/// adds no new package. The headless caption runner does not read this
/// file: the language travels with the job (`enqueue` args → native job
/// store → `ready` args), so the UI is the only reader/writer.
class CaptionLanguageStore {
  CaptionLanguageStore({
    Future<Directory> Function()? documentsDirectory,
  }) : _documentsDirectory =
            documentsDirectory ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _documentsDirectory;

  static const _fileName = 'caption_language.txt';

  Future<File> _file() async {
    final dir = await _documentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// The stored language, or Auto when nothing is stored, the file is
  /// unreadable, or the content is not a known code.
  Future<CaptionLanguage> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return CaptionLanguage.auto;
      return CaptionLanguage.fromCode((await file.readAsString()).trim());
    } catch (_) {
      return CaptionLanguage.auto;
    }
  }

  /// Store the language. Failures are swallowed: a missed save only
  /// means the next session starts on Auto again, never a crash.
  Future<void> save(CaptionLanguage language) async {
    try {
      final file = await _file();
      await file.writeAsString(language.code, flush: true);
    } catch (_) {
      // Best effort only — see [load].
    }
  }
}
