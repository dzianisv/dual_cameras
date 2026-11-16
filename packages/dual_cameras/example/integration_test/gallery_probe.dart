import 'dart:typed_data';

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

  /// Writes [bytes] as a PNG into MediaStore.Downloads under [name], so
  /// the file lands at `/sdcard/Download/<name>`. No storage permission
  /// is needed for the app's own files there on API 29+.
  Future<void> saveScreenshot(String name, List<int> bytes) async {
    await _channel.invokeMethod<void>('saveScreenshot', <String, Object>{
      'name': name,
      'bytes': Uint8List.fromList(bytes),
    });
  }
}
