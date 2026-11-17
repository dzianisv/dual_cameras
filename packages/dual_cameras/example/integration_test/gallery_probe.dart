import 'package:flutter/services.dart';

/// Test-only Dart wrapper for the native `GalleryProbeChannel`
/// (`app.storycam/gallery_probe`, issue #79 Track B step 2). Used only
/// by `integration_test/camera_flow_test.dart`; no product code imports
/// this file.
class GalleryProbe {
  GalleryProbe();

  static const MethodChannel _channel =
      MethodChannel('app.storycam/gallery_probe');

  /// The newest MediaStore video row, or null when no video row exists.
  /// Keys: `durationMs`, `size`, `dateAdded` (epoch seconds). A row
  /// with `durationMs == 0` means the MediaStore scanner has not filled
  /// DURATION yet — the caller polls until `durationMs > 0`.
  Future<Map<String, int>?> queryLatest() async {
    final Map<Object?, Object?>? row =
        await _channel.invokeMapMethod<Object?, Object?>('queryLatest');
    if (row == null) {
      return null;
    }
    return <String, int>{
      'durationMs': (row['durationMs'] as num).toInt(),
      'size': (row['size'] as num).toInt(),
      'dateAdded': (row['dateAdded'] as num).toInt(),
    };
  }

  /// Writes [bytes] as a PNG under [name] in TWO places (best-effort:
  /// the call succeeds when at least one write lands, and throws only
  /// when both fail — the mid-recording call site guards the throw so
  /// a save failure never fails the test):
  /// 1. MediaStore.Downloads, so the file lands at
  ///    `/sdcard/Download/<name>` (the CI emulator `adb pull` path).
  ///    No storage permission is needed for the app's own files there
  ///    on API 29+.
  /// 2. A plain file in the app's external-files dir, so the file
  ///    lands at
  ///    `/sdcard/Android/data/app.storycam/files/<name>`.
  /// Firebase Test Lab pulls neither path by default — the proof-gate
  /// gcloud run must pass `--directories-to-pull
  /// /sdcard/Download,/sdcard/Android/data/app.storycam/files`; either
  /// copy then lands in the results bucket under `artifacts/sdcard/...`.
  /// The plain-file copy exists because a MediaStore-managed path was
  /// never verified pullable (the 2026-11-17 Test Lab run's bucket had
  /// no PNG at all, and no record shows the flag was passed); a plain
  /// `File` write in the app's own dir is the most vanilla pullable
  /// path there is.
  Future<void> saveScreenshot(String name, List<int> bytes) async {
    await _channel.invokeMethod<void>('saveScreenshot', <String, Object>{
      'name': name,
      'bytes': Uint8List.fromList(bytes),
    });
  }
}
