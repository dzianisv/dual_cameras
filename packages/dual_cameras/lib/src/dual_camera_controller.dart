import 'dart:async';

import 'package:dual_cameras_platform_interface/dual_cameras_platform_interface.dart';
import 'package:flutter/foundation.dart';

import 'dual_layout.dart';

/// Immutable snapshot of the controller's state, exposed via [ValueListenable].
@immutable
class DualCameraValue {
  const DualCameraValue({
    required this.isInitialized,
    required this.isRecording,
    required this.textureId,
    required this.capabilities,
    required this.thermal,
    required this.stats,
    required this.errorMessage,
  });

  const DualCameraValue.uninitialized()
      : isInitialized = false,
        isRecording = false,
        textureId = null,
        capabilities = null,
        thermal = ThermalLevel.nominal,
        stats = null,
        errorMessage = null;

  final bool isInitialized;
  final bool isRecording;

  /// The preview texture id; null until the pipeline is ready.
  final int? textureId;

  final CameraCapabilities? capabilities;
  final ThermalLevel thermal;

  /// Latest performance telemetry for the debug HUD; null until frames flow.
  final FrameStats? stats;
  final String? errorMessage;

  DualCameraValue copyWith({
    bool? isInitialized,
    bool? isRecording,
    int? textureId,
    CameraCapabilities? capabilities,
    ThermalLevel? thermal,
    FrameStats? stats,
    String? errorMessage,
  }) {
    return DualCameraValue(
      isInitialized: isInitialized ?? this.isInitialized,
      isRecording: isRecording ?? this.isRecording,
      textureId: textureId ?? this.textureId,
      capabilities: capabilities ?? this.capabilities,
      thermal: thermal ?? this.thermal,
      stats: stats ?? this.stats,
      errorMessage: errorMessage,
    );
  }
}

/// Controls a dual-camera (front+back simultaneous) capture session.
///
/// ```dart
/// final cam = DualCameraController();
/// if (!await DualCameraController.isSupported()) { /* single-cam fallback */ }
/// await cam.initialize(layout: DualLayout.pictureInPicture());
/// // DualCameraPreview(cam) renders the live composite
/// await cam.startRecording();
/// final clip = await cam.stopRecording();
/// await cam.dispose();
/// ```
class DualCameraController extends ValueNotifier<DualCameraValue> {
  DualCameraController() : super(const DualCameraValue.uninitialized());

  DualCamerasPlatform get _platform =>
      DualCamerasPlatform.instance;
  StreamSubscription<DualCameraEvent>? _eventSub;
  bool _disposed = false;

  /// Params of the last successful [initialize], kept so [reinitialize] can
  /// bring the same session back up after the OS tore it down (issue #13).
  RecordingConfig? _lastConfig;

  /// True once [initialize] has succeeded at least once. [reinitialize] is
  /// a no-op until then — the camera was never opened.
  bool _everInitialized = false;

  /// Probe whether this device can run front+back concurrently without bringing
  /// the pipeline up. Cheap; safe to call before [initialize].
  static Future<CameraCapabilities> probeSupport() =>
      DualCamerasPlatform.instance.probeSupport();

  /// Convenience wrapper over [probeSupport].
  static Future<bool> isSupported() async =>
      (await probeSupport()).isSupported;

  /// Bring up the session + compositor and start the live preview.
  Future<void> initialize({
    LayoutConfig? layout,
    DualResolution resolution = DualResolution.hd720,
    VideoCodec codec = VideoCodec.h264,
    bool recordAudio = true,
    Duration maxDuration = Duration.zero,
  }) async {
    _eventSub ??= _platform.events.listen(_onEvent);
    final config = RecordingConfig(
      layout: layout ?? DualLayout.pictureInPicture(),
      resolution: resolution,
      codec: codec,
      recordAudio: recordAudio,
      maxDurationMs: maxDuration.inMilliseconds,
    );
    final result = await _platform.initialize(config);
    _lastConfig = config;
    _everInitialized = true;
    value = value.copyWith(
      isInitialized: true,
      textureId: result.textureId,
      capabilities: result.capabilities,
    );
  }

  /// Re-establish the camera session after the OS tore it down while the
  /// app was backgrounded (issue #13: Android disconnects the camera and
  /// destroys the preview surface; on resume nothing rebinds it).
  ///
  /// Returns `false` (no-op) if the camera was never opened. Otherwise the
  /// native session is disposed and re-initialized with the last init
  /// params; the event subscription stays alive across the swap, so
  /// ready/thermal/stats events keep flowing. A recording cannot survive a
  /// torn-down session, so [DualCameraValue.isRecording] is cleared — the
  /// caller reads it before calling and surfaces the interruption.
  ///
  /// [resolution] overrides the stored resolution for this re-init (the
  /// video-quality row uses it) and becomes the stored resolution for
  /// later re-inits.
  ///
  /// On failure the value is marked uninitialized with the error instead of
  /// keeping the stale texture id, so the UI shows a retry instead of a
  /// frozen preview.
  Future<bool> reinitialize({DualResolution? resolution}) async {
    if (_disposed || !_everInitialized) return false;
    var config = _lastConfig;
    if (config == null) return false;
    if (resolution != null && resolution != config.resolution) {
      config = RecordingConfig(
        layout: config.layout,
        resolution: resolution,
        codec: config.codec,
        recordAudio: config.recordAudio,
        maxDurationMs: config.maxDurationMs,
      );
      _lastConfig = config;
    }
    try {
      // Best effort: the torn-down session may already be gone. Native
      // initialize() releases whatever is left first in any case.
      await _platform.dispose();
    } catch (_) {
      // Fall through to re-initialize.
    }
    try {
      final result = await _platform.initialize(config);
      value = DualCameraValue(
        isInitialized: true,
        isRecording: false,
        textureId: result.textureId,
        capabilities: result.capabilities,
        thermal: value.thermal,
        stats: null,
        errorMessage: null,
      );
      return true;
    } catch (e) {
      value = DualCameraValue(
        isInitialized: false,
        isRecording: false,
        textureId: null,
        capabilities: value.capabilities,
        thermal: value.thermal,
        stats: null,
        errorMessage: '$e',
      );
      return false;
    }
  }

  Future<void> startRecording() async {
    await _platform.startRecording();
    value = value.copyWith(isRecording: true);
  }

  /// Stop recording; returns the composited `.mp4` path.
  Future<String> stopRecording() async {
    final path = await _platform.stopRecording();
    value = value.copyWith(isRecording: false);
    return path;
  }

  /// Capture a composited still; returns the image path.
  Future<String> takePhoto() => _platform.takePhoto();

  /// Flip which feed is full-frame, live. Also flips the stored
  /// [_lastConfig] primary, so a resume re-init ([reinitialize]) brings
  /// the same primary back instead of silently resetting to back.
  Future<void> swapPrimary() async {
    await _platform.swapPrimary();
    final config = _lastConfig;
    if (config != null) {
      final layout = config.layout;
      _lastConfig = RecordingConfig(
        layout: LayoutConfig(
          mode: layout.mode,
          primary: layout.primary == CameraLens.back
              ? CameraLens.front
              : CameraLens.back,
          insetCorner: layout.insetCorner,
          insetScale: layout.insetScale,
          cornerRadius: layout.cornerRadius,
          margin: layout.margin,
          mirrorFront: layout.mirrorFront,
          circleInset: layout.circleInset,
        ),
        resolution: config.resolution,
        codec: config.codec,
        recordAudio: config.recordAudio,
        maxDurationMs: config.maxDurationMs,
      );
    }
  }

  /// Update the layout geometry live.
  Future<void> setLayout(LayoutConfig layout) => _platform.setLayout(layout);

  /// Set exposure compensation in EV on both cameras — the Sony-style EV dial.
  /// Negative values darken (fixes overexposed video); `0.0` is neutral.
  /// Safe to call any time after [initialize]; a no-op when unsupported.
  Future<void> setExposureCompensation(double ev) =>
      _platform.setExposureCompensation(ev);

  /// The device's supported exposure-compensation range in EV
  /// (all zeros when unsupported or before [initialize]).
  Future<ExposureCompensationRange> getExposureCompensationRange() =>
      _platform.getExposureCompensationRange();

  /// Apply a color-grade [VideoFilter] preset to the final composite, live.
  /// Affects both preview and recording; the grade runs after exposure, so
  /// it composes with [setExposureCompensation]. Safe to call any time after
  /// [initialize].
  Future<void> setFilter(VideoFilter filter) => _platform.setFilter(filter);

  /// Lenses the camera API offers for one facing, as zoom ratios
  /// ([LensOption]). Only probed ratios are returned.
  Future<List<LensOption>> getLenses(bool front) =>
      _platform.getLenses(front);

  /// Switch to the lens at [ratio] on the front ([front] true) or rear
  /// camera. No rebind on Android (zoom-ratio switch); safe to call while
  /// recording. Fails when the ratio is not offered.
  Future<void> setLens(bool front, double ratio) =>
      _platform.setLens(front, ratio);

  /// Whether this device can record 4K with both cameras at once.
  Future<bool> supports4k() => _platform.supports4k();

  void _onEvent(DualCameraEvent event) {
    switch (event) {
      case DualCameraReady(:final textureId):
        value = value.copyWith(isInitialized: true, textureId: textureId);
      case DualCameraRecordingStarted():
        value = value.copyWith(isRecording: true);
      case DualCameraRecordingStopped():
        value = value.copyWith(isRecording: false);
      case DualCameraCapabilityChanged(:final capabilities):
        value = value.copyWith(capabilities: capabilities);
      case DualCameraThermalEvent(:final level):
        value = value.copyWith(thermal: level);
      case DualCameraStatsEvent(:final stats):
        value = value.copyWith(stats: stats);
      case DualCameraErrorEvent(:final message):
        value = value.copyWith(errorMessage: message);
    }
  }

  @override
  Future<void> dispose() async {
    // Idempotent: the screen defers disposal to a pending camera command
    // (whenComplete), and dispose must never release the native session
    // twice if it is reached again.
    if (_disposed) return;
    _disposed = true;
    await _eventSub?.cancel();
    _eventSub = null;
    try {
      await _platform.dispose();
    } finally {
      super.dispose();
    }
  }
}
