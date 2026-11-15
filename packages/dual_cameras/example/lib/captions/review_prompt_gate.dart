import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Persists the app version the in-app review prompt was last requested
/// for (issue #37).
///
/// One line of text (the version string, e.g. `0.5.11`) in a file under
/// the app documents directory — the same one-line-file shape as
/// [CaptionLanguageStore]. The prompt is requested at most once per app
/// version, on the first completed recording of that version.
class ReviewPromptGate {
  ReviewPromptGate({
    Future<Directory> Function()? documentsDirectory,
  }) : _documentsDirectory =
            documentsDirectory ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _documentsDirectory;

  static const _fileName = 'review_prompt_version.txt';

  Future<File> _file() async {
    final dir = await _documentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// The version last prompted for, or null when nothing is stored, the
  /// file is unreadable, or its content is empty.
  ///
  /// File IO is synchronous inside: real async dart:io never completes
  /// inside testWidgets' fake-async zone, which hung the caption-language
  /// widget tests for the full 10-minute timeout (see
  /// CaptionLanguageStore). The Future signatures stay so callers do not
  /// change.
  Future<String?> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return null;
      final stored = file.readAsStringSync().trim();
      return stored.isEmpty ? null : stored;
    } catch (_) {
      return null;
    }
  }

  /// True when [currentVersion] has never been prompted for. Loads the
  /// stored version internally; callers never call [load] first.
  Future<bool> shouldPrompt(String currentVersion) async {
    final stored = await load();
    return stored != currentVersion;
  }

  /// Record that the prompt was requested for [version]. Failures are
  /// swallowed: a missed save only means the next completed recording of
  /// the same version retries, never a crash.
  Future<void> markPrompted(String version) async {
    try {
      final file = await _file();
      file.writeAsStringSync(version, flush: true);
    } catch (_) {
      // Best effort only — see [load].
    }
  }
}
