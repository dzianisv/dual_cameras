import 'dart:convert';
import 'dart:io';

import 'package:dual_cameras/dual_cameras.dart';
import 'package:path_provider/path_provider.dart';

/// Which way the map turns (issue #20, wireframe v1 proposal — Den to
/// confirm). Heading-up is the default: the map rotates with the compass
/// and the direction of travel stays pointing up.
enum CompassMode {
  /// Map rotates with the heading; you stay pointing up.
  headingUp('heading-up', 'Heading-up'),

  /// Map fixed north-up; the needle (heading cone) turns.
  northUp('north-up', 'North-up');

  const CompassMode(this.code, this.label);

  final String code;
  final String label;

  static CompassMode fromCode(String? code) =>
      values.firstWhere((value) => value.code == code,
          orElse: () => CompassMode.headingUp);
}

/// Which section of the Settings dialog a bottom-menu tap opens.
/// Tapping a menu item opens the dialog at that section — it never toggles
/// the feature directly (Den, 2026-11-14).
enum SettingsSection {
  map('Map & compass'),
  front('Front camera'),
  rear('Rear camera'),
  captions('Captions');

  const SettingsSection(this.title);

  final String title;
}

/// The camera-screen settings (issue #20): map & compass, front/rear
/// camera, captions language lives with the captions code. One JSON file,
/// same file-based precedent as [CaptionLanguageStore] — no
/// shared_preferences.
class CameraSettings {
  const CameraSettings({
    this.compassMode = CompassMode.headingUp,
    this.mapVisible = true,
    this.mirrorFront = true,
    this.videoQuality = DualResolution.hd1080,
    this.filter = VideoFilter.none,
    this.frontLens,
    this.rearLens,
    this.locationPermissionRequested = false,
  });

  final CompassMode compassMode;

  /// Location circle on/off (the Map menu word shows this state).
  final bool mapVisible;

  /// Mirror selfie (Front camera section; wires the existing debug-channel
  /// capability — same default as the in-memory value it replaces).
  final bool mirrorFront;

  /// Recording resolution. 4K ([DualResolution.ultraHd2160]) only when the
  /// device probe passes; the UI never offers it otherwise.
  final DualResolution videoQuality;

  /// Last picked filter, restored on launch.
  final VideoFilter filter;

  /// Last picked lens ratio per facing, re-applied when the API still
  /// offers it (null = main lens).
  final double? frontLens;
  final double? rearLens;

  /// Location permission has been requested once. A denial is remembered:
  /// the app never re-prompts in a loop — the Settings dialog points at
  /// the system settings instead.
  final bool locationPermissionRequested;

  CameraSettings copyWith({
    CompassMode? compassMode,
    bool? mapVisible,
    bool? mirrorFront,
    DualResolution? videoQuality,
    VideoFilter? filter,
    double? frontLens,
    double? rearLens,
    bool? locationPermissionRequested,
  }) {
    return CameraSettings(
      compassMode: compassMode ?? this.compassMode,
      mapVisible: mapVisible ?? this.mapVisible,
      mirrorFront: mirrorFront ?? this.mirrorFront,
      videoQuality: videoQuality ?? this.videoQuality,
      filter: filter ?? this.filter,
      frontLens: frontLens ?? this.frontLens,
      rearLens: rearLens ?? this.rearLens,
      locationPermissionRequested:
          locationPermissionRequested ?? this.locationPermissionRequested,
    );
  }

  Map<String, Object?> toJson() => {
        'compassMode': compassMode.code,
        'mapVisible': mapVisible,
        'mirrorFront': mirrorFront,
        'videoQuality': videoQuality.name,
        'filter': filter.name,
        'frontLens': frontLens,
        'rearLens': rearLens,
        'locationPermissionRequested': locationPermissionRequested,
      };

  static CameraSettings fromJson(Map<String, Object?> json) {
    DualResolution qualityFrom(String? name) =>
        DualResolution.values.firstWhere((v) => v.name == name,
            orElse: () => DualResolution.hd1080);
    VideoFilter filterFrom(String? name) => VideoFilter.values
        .firstWhere((v) => v.name == name, orElse: () => VideoFilter.none);
    double? lensFrom(Object? value) =>
        value is num ? value.toDouble() : null;
    return CameraSettings(
      compassMode: CompassMode.fromCode(json['compassMode'] as String?),
      mapVisible: json['mapVisible'] as bool? ?? true,
      mirrorFront: json['mirrorFront'] as bool? ?? true,
      videoQuality: qualityFrom(json['videoQuality'] as String?),
      filter: filterFrom(json['filter'] as String?),
      frontLens: lensFrom(json['frontLens']),
      rearLens: lensFrom(json['rearLens']),
      locationPermissionRequested:
          json['locationPermissionRequested'] as bool? ?? false,
    );
  }
}

/// Persists [CameraSettings] across sessions.
///
/// One JSON file in the app documents directory — the same precedent as
/// `CaptionLanguageStore` (one text file via `path_provider`, sync IO
/// inside so widget tests never hang in the fake-async zone). A missing,
/// unreadable, or corrupt file means defaults; a failed save only means
/// the next session starts on defaults again, never a crash.
class CameraSettingsStore {
  CameraSettingsStore({
    Future<Directory> Function()? documentsDirectory,
  }) : _documentsDirectory =
            documentsDirectory ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _documentsDirectory;

  static const _fileName = 'camera_settings.json';

  Future<File> _file() async {
    final dir = await _documentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<CameraSettings> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return const CameraSettings();
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, Object?>) return const CameraSettings();
      return CameraSettings.fromJson(decoded);
    } catch (_) {
      return const CameraSettings();
    }
  }

  Future<void> save(CameraSettings settings) async {
    try {
      final file = await _file();
      file.writeAsStringSync(jsonEncode(settings.toJson()), flush: true);
    } catch (_) {
      // Best effort only — see [load].
    }
  }
}
