import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Which failure the stored error belongs to. The model download and the
/// caption/map-burn job fail independently and are reported in different
/// places, so each kind gets its own file — a later caption failure must
/// never overwrite the model error (or vice versa).
enum LastFailureKind { model, caption }

/// Persists the last failure error per kind across sessions, so the NEXT
/// failure of the two 0.5.15 phone failures is diagnosable without Den:
/// both errors used to live in-memory only (`_modelError` / `_error` in
/// main.dart) and were lost on restart. The stored text is exactly what
/// Settings shows for that slot.
///
/// Follows the CaptionLanguageStore pattern exactly: one file per kind
/// under the app documents dir via path_provider, injectable directory
/// for tests, synchronous dart:io calls inside Future signatures (async
/// dart:io never completes inside testWidgets' fake-async zone — see
/// that file's comment; do not repeat that bug).
class LastFailureStore {
  LastFailureStore({
    Future<Directory> Function()? documentsDirectory,
  }) : _documentsDirectory =
            documentsDirectory ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _documentsDirectory;

  static const _fileNames = <LastFailureKind, String>{
    LastFailureKind.model: 'last_model_error.txt',
    LastFailureKind.caption: 'last_caption_error.txt',
  };

  Future<File> _file(LastFailureKind kind) async {
    final dir = await _documentsDirectory();
    return File('${dir.path}/${_fileNames[kind]}');
  }

  /// The stored error for [kind], or null when nothing is stored, the
  /// file is unreadable, or it is empty.
  Future<String?> load(LastFailureKind kind) async {
    try {
      final file = await _file(kind);
      if (!file.existsSync()) return null;
      final text = file.readAsStringSync().trim();
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  /// Store the error for [kind]. Failures are swallowed: a missed save
  /// only means the next session has no error to show, never a crash.
  Future<void> save(LastFailureKind kind, String message) async {
    try {
      final file = await _file(kind);
      file.writeAsStringSync(message, flush: true);
    } catch (_) {
      // Best effort only — see [load].
    }
  }

  /// Drop the stored error for [kind] (called on success, so a stale
  /// failure does not survive past the run that fixed it). Failures are
  /// swallowed, like [save].
  Future<void> clear(LastFailureKind kind) async {
    try {
      final file = await _file(kind);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // Best effort only — see [load].
    }
  }
}
