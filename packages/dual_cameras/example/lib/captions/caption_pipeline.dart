import 'dart:convert';

import 'package:flutter/services.dart';

import 'caption_models.dart';

/// Platform-channel bridge to the example app's native captions post-processing
/// (audio extraction + caption burn-in). Everything runs on-device.
class CaptionPipeline {
  static const MethodChannel _channel =
      MethodChannel('dual_cameras_example/captions');

  /// Extract the mp4's audio track to a 16 kHz mono WAV for the transcriber.
  /// Returns the WAV path.
  Future<String> extractAudio(String mp4Path) async {
    final wav = await _channel.invokeMethod<String>(
      'extractAudio',
      {'mp4': mp4Path},
    );
    if (wav == null || wav.isEmpty) {
      throw StateError('extractAudio returned no path');
    }
    return wav;
  }

  /// Burn karaoke word-highlight captions into a copy of the mp4 — and,
  /// when [mapManifest] is present, the map circle too (issue #49, one
  /// pass: map first, then captions). Returns the burned mp4 path. The
  /// original file is left untouched.
  Future<String> burnCaptions({
    required String mp4Path,
    required List<CaptionWord> words,
    MapBurnManifest? mapManifest,
  }) async {
    final wordsJson = jsonEncode(words.map((w) => w.toJson()).toList());
    final out = await _channel.invokeMethod<String>(
      'burnCaptions',
      {
        'mp4': mp4Path,
        'words': wordsJson,
        'mapManifest':
            mapManifest == null ? null : jsonEncode(mapManifest.toJson()),
      },
    );
    if (out == null || out.isEmpty) {
      throw StateError('burnCaptions returned no path');
    }
    return out;
  }
}

/// One map-burn entry (issue #49): a snapshot PNG in the take's frames
/// dir ([file] is the bare name, e.g. `map_1234.png`), its take-relative
/// capture time, and whether the map was visible then. [file] is null for
/// a visibility-only sample (a map toggle, or a tick while the map was
/// off) — the burner draws nothing (off) or the fallback disc (on, no
/// snapshot yet) for those.
class MapBurnFrame {
  const MapBurnFrame({
    required this.file,
    required this.tMs,
    required this.mapVisible,
  });

  final String? file;
  final int tMs;
  final bool mapVisible;

  Map<String, Object?> toJson() =>
      {'file': file, 'tMs': tMs, 'mapVisible': mapVisible};
}

/// The map manifest for one take (issue #49): the snapshot dir + the
/// time-ordered entries the burner draws from. Null on the channel means
/// the map was off — the existing captions-only path, unchanged.
class MapBurnManifest {
  const MapBurnManifest({required this.framesDir, required this.frames});

  final String framesDir;
  final List<MapBurnFrame> frames;

  Map<String, Object?> toJson() => {
        'dir': framesDir,
        'frames': frames.map((f) => f.toJson()).toList(),
      };
}
