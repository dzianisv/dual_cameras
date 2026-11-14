// Pigeon contract for dual_cameras.
//
// Regenerate with:
//   dart run pigeon --input pigeons/messages.dart
//
// Generated outputs are checked in (lib/src/messages.g.dart and the native
// files in the android/ios implementation packages).
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    dartPackageName: 'dual_cameras_platform_interface',
    kotlinOut:
        '../dual_cameras_android/android/src/main/kotlin/com/romanslack/dual_cameras_android/Messages.g.kt',
    kotlinOptions: KotlinOptions(
      package: 'com.romanslack.dual_cameras_android',
    ),
    swiftOut: '../dual_cameras_ios/ios/Classes/Messages.g.swift',
  ),
)

/// Which physical camera a feed comes from.
enum CameraLens { back, front }

/// Corner the picture-in-picture inset is anchored to.
enum InsetCorner { topLeft, topRight, bottomLeft, bottomRight }

/// Composition layout of the two feeds.
enum DualLayoutMode {
  /// Primary full-frame, secondary as a rounded inset.
  pictureInPicture,

  /// Two equal halves, stacked vertically.
  splitVertical,

  /// Two equal halves, side by side.
  splitHorizontal,
}

/// Target capture resolution (the hardware caps this; 720p is the safe ceiling
/// for Android concurrent cameras).
///
/// `ultraHd2160` (4K) is probe-gated: [DualCameraHostApi.supports4k] reports
/// whether this device can record it with both cameras at once. The UI must
/// offer 4K only when the probe passes — never assume it.
enum DualResolution { sd480, hd720, hd1080, ultraHd2160 }

/// Recorded video codec.
enum VideoCodec { h264, hevc }

/// Thermal pressure buckets, normalized across platforms.
enum ThermalLevel { nominal, fair, serious, critical }

/// Why a capability probe failed, when it did.
enum UnsupportedReason {
  /// The device hardware cannot run front+back concurrently.
  noConcurrentCamera,

  /// The OS version is too old for the multi-cam API.
  osTooOld,

  /// Camera permission has not been granted.
  permissionDenied,
}

/// Result of probing whether this device can run the dual-camera pipeline.
class CameraCapabilities {
  CameraCapabilities({
    required this.isSupported,
    this.maxWidth,
    this.maxHeight,
    this.reason,
  });

  bool isSupported;

  /// Max composite width the device can sustain concurrently (null if unknown).
  int? maxWidth;
  int? maxHeight;

  /// Populated only when [isSupported] is false.
  UnsupportedReason? reason;
}

/// The picture-in-picture / split geometry. Computed once in Dart and applied
/// identically to preview, recording, and stills so they can never drift.
class LayoutConfig {
  LayoutConfig({
    required this.mode,
    required this.primary,
    required this.insetCorner,
    required this.insetScale,
    required this.cornerRadius,
    required this.margin,
    required this.mirrorFront,
    required this.circleInset,
  });

  DualLayoutMode mode;

  /// Which lens is full-frame (PiP) / first half (split).
  CameraLens primary;

  InsetCorner insetCorner;

  /// Inset size as a fraction of the full frame's shorter side (PiP only).
  double insetScale;

  /// Inset corner radius in logical px (PiP only).
  double cornerRadius;

  /// Inset margin from the anchored corner in logical px (PiP only).
  double margin;

  /// Whether the front feed is horizontally mirrored (selfie convention).
  bool mirrorFront;

  /// PiP inset is a centered circle instead of a rounded rectangle (PiP only).
  bool circleInset;
}

/// Everything needed to bring the pipeline up.
class RecordingConfig {
  RecordingConfig({
    required this.layout,
    required this.resolution,
    required this.codec,
    required this.recordAudio,
    required this.maxDurationMs,
  });

  LayoutConfig layout;
  DualResolution resolution;
  VideoCodec codec;
  bool recordAudio;

  /// Hard cap on recording length; 0 = no cap (the ThermalGovernor may still
  /// stop earlier).
  int maxDurationMs;
}

/// Live performance telemetry for the debug HUD (ARCHITECTURE.md §10).
class FrameStats {
  FrameStats({
    required this.fps,
    required this.compositeMs,
    required this.droppedFrames,
    required this.thermal,
  });

  /// Composited frames per second over the last window.
  double fps;

  /// Mean GPU composite time in ms over the last window (target < 16).
  double compositeMs;

  /// Frames dropped at the encoder boundary since recording began.
  int droppedFrames;

  ThermalLevel thermal;
}

/// Returned by [initialize]; the texture id renders via Flutter's `Texture`.
class InitResult {
  InitResult({required this.textureId, required this.capabilities});

  int textureId;
  CameraCapabilities capabilities;
}

/// Supported exposure-compensation range in EV (the Sony-style EV dial).
class ExposureCompensationRange {
  ExposureCompensationRange({
    required this.minEv,
    required this.maxEv,
    required this.stepEv,
  });

  /// Most negative EV (darkest), e.g. -4.0.
  double minEv;

  /// Most positive EV (brightest), e.g. +4.0.
  double maxEv;

  /// EV step between compensation indices, e.g. 1/3.
  double stepEv;
}

/// Color-grade preset applied to the final composite (preview + recording).
/// Designed for extension: new presets are new enum values, never an API
/// break. The grade runs in the compositor's final pass, after exposure.
///
/// NOTE: declared after the data classes so the Pigeon codec type number
/// (142) matches the checked-in generated code; see
/// lib/src/messages.g.dart.
///
/// The 7 presets after [moody] must each map to a distinct [GradeParams]
/// tuple on both native sides — two names over identical params would be
/// two pills for one look. The game-look names (GTA, San Andreas, GTA 3)
/// are as heard from Den and unconfirmed (issue #20).
enum VideoFilter {
  /// No grade (identity).
  none,

  /// Dark moody grade: desaturated, low-key, teal shadows / warm highlights.
  moody,

  /// Hyper: punchy, over-saturated, lifted exposure (Instagram-style).
  hyper,

  /// Midnight: cold blue shadows, crushed blacks, low saturation.
  midnight,

  /// Simple: clean and near-neutral, slight warmth, no vignette.
  simple,

  /// Jakarta: warm golden-hour grade, amber highlights, soft contrast.
  jakarta,

  /// GTA: saturated warm game look, high contrast, orange-teal split tone.
  gta,

  /// San Andreas: dusty warm haze, lifted blacks, orange highlights.
  sanAndreas,

  /// GTA 3: cold desaturated grit, heavy vignette, crushed shadows.
  gta3,
}

/// One lens the camera API offers for a facing, as a zoom ratio.
///
/// The ratio is relative to the main (1x) lens: 0.5 is the ultrawide,
/// 1.0 the main lens, 1.5 the front zoom preset Den asked for. Only ratios
/// the API reports are listed — the UI shows exactly this list, nothing
/// hardcoded. [label] is the pill text ("0.5", "1", "1.5").
/// NOTE: declared after [VideoFilter], so the Pigeon codec type number is
/// 143; see lib/src/messages.g.dart.
class LensOption {
  LensOption({required this.ratio, required this.label});

  double ratio;
  String label;
}

/// Commands: Dart -> native.
@HostApi()
abstract class DualCameraHostApi {
  /// Probe hardware support without bringing the pipeline up.
  @async
  CameraCapabilities probeSupport();

  /// Bring up the session + compositor; returns the preview texture id.
  @async
  InitResult initialize(RecordingConfig config);

  @async
  void startRecording();

  /// Returns the path to the finished composited .mp4.
  @async
  String stopRecording();

  /// Returns the path to a composited still (JPEG/HEIC).
  @async
  String takePhoto();

  /// Flip which feed is full-frame, live.
  @async
  void swapPrimary();

  /// Update layout geometry live (e.g. user drags the inset).
  @async
  void setLayout(LayoutConfig layout);

  /// Set exposure compensation in EV on both cameras (the Sony-style EV dial).
  /// Negative values darken the image (fixes overexposed video), positive
  /// values brighten it. No-op when unsupported or the pipeline isn't up.
  @async
  void setExposureCompensation(double ev);

  /// Supported exposure-compensation range in EV. All zeros when unsupported
  /// or the pipeline isn't up.
  @async
  ExposureCompensationRange getExposureCompensationRange();

  /// Apply a color-grade [VideoFilter] preset to the final composite, live.
  /// Affects both preview and recording; the grade runs after exposure.
  @async
  void setFilter(VideoFilter filter);

  /// Lenses the camera API offers for one facing, as zoom ratios.
  /// Android: physical cameras (Camera2 focal lengths) + the CameraX zoom
  /// range; iOS: DiscoverySession device types intersected with what the
  /// bound device can actually reach. Only probed ratios are returned —
  /// never a hardcoded list. Empty when the camera reports nothing (or
  /// before the pipeline is up on a platform that needs it).
  @async
  List<LensOption> getLenses(bool front);

  /// Switch to the lens at [ratio] on the front ([front] true) or rear
  /// camera. Android switches the physical camera via the zoom ratio (no
  /// rebind); iOS sets the bound device's video zoom factor. Fails when
  /// the ratio is not in [getLenses] for that facing, or the pipeline
  /// is not up.
  @async
  void setLens(bool front, double ratio);

  /// Whether this device can record 4K ([DualResolution.ultraHd2160])
  /// with both cameras at once (encoder + per-camera 4K output sizes).
  /// A `true` answer is a capability probe, not a guarantee under thermal
  /// load — the thermal governor can still stop a recording.
  @async
  bool supports4k();

  @async
  void dispose();
}

/// State + telemetry: native -> Dart.
@FlutterApi()
abstract class DualCameraFlutterApi {
  void onReady(int textureId);
  void onError(String code, String message);
  void onRecordingStarted();
  void onRecordingStopped(String path);
  void onCapabilityChanged(CameraCapabilities capabilities);
  void onThermal(ThermalLevel level);
  void onFrameStats(FrameStats stats);
}
