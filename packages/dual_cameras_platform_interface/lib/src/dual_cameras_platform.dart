import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'events.dart';
import 'messages.g.dart';
import 'pigeon_dual_cameras.dart';

/// The interface that platform implementations of dual_cameras must
/// implement.
///
/// Platform implementations should extend this class rather than implement it
/// as `dual_cameras` does not consider newly added methods to be
/// breaking changes. Extending this class (using `extends`) ensures that the
/// subclass will get the default implementation, while platform implementations
/// that `implements` this interface will be broken by newly added
/// [DualCamerasPlatform] methods.
abstract class DualCamerasPlatform extends PlatformInterface {
  DualCamerasPlatform() : super(token: _token);

  static final Object _token = Object();

  static DualCamerasPlatform _instance = PigeonDualCameras();

  /// The default instance to use.
  ///
  /// Defaults to the Pigeon-backed implementation, which works identically on
  /// every platform that registers the native side. Both the Android and iOS
  /// implementation packages re-affirm this instance via their `registerWith`.
  static DualCamerasPlatform get instance => _instance;

  static set instance(DualCamerasPlatform value) {
    PlatformInterface.verify(value, _token);
    _instance = value;
  }

  /// Broadcast stream of native events (ready / error / recording / thermal).
  Stream<DualCameraEvent> get events =>
      throw UnimplementedError('events has not been implemented.');

  /// Probe whether this device can run front+back concurrently, without
  /// bringing the pipeline up.
  Future<CameraCapabilities> probeSupport() =>
      throw UnimplementedError('probeSupport() has not been implemented.');

  /// Bring up the session + compositor. Returns the init result whose
  /// [InitResult.textureId] feeds a Flutter `Texture` widget.
  Future<InitResult> initialize(RecordingConfig config) =>
      throw UnimplementedError('initialize() has not been implemented.');

  Future<void> startRecording() =>
      throw UnimplementedError('startRecording() has not been implemented.');

  /// Stop recording; resolves to the composited .mp4 path.
  Future<String> stopRecording() =>
      throw UnimplementedError('stopRecording() has not been implemented.');

  /// Capture a composited still; resolves to the image path.
  Future<String> takePhoto() =>
      throw UnimplementedError('takePhoto() has not been implemented.');

  Future<void> swapPrimary() =>
      throw UnimplementedError('swapPrimary() has not been implemented.');

  Future<void> setLayout(LayoutConfig layout) =>
      throw UnimplementedError('setLayout() has not been implemented.');

  /// Set exposure compensation in EV on both cameras (Sony-style EV dial).
  /// Negative darkens (fixes overexposed video), positive brightens.
  /// No-op on devices without support.
  Future<void> setExposureCompensation(double ev) => throw UnimplementedError(
      'setExposureCompensation() has not been implemented.');

  /// Supported exposure-compensation range in EV; all zeros when unsupported
  /// or the pipeline isn't up.
  Future<ExposureCompensationRange> getExposureCompensationRange() =>
      throw UnimplementedError(
          'getExposureCompensationRange() has not been implemented.');

  /// Apply a color-grade [VideoFilter] preset to the final composite, live.
  /// Affects both preview and recording; the grade runs after exposure.
  Future<void> setFilter(VideoFilter filter) =>
      throw UnimplementedError('setFilter() has not been implemented.');

  /// Lenses the camera API offers for one facing, as zoom ratios.
  /// Only probed ratios are returned — never a hardcoded list.
  Future<List<LensOption>> getLenses(bool front) =>
      throw UnimplementedError('getLenses() has not been implemented.');

  /// Switch to the lens at [ratio] on the front ([front] true) or rear
  /// camera. Fails when the ratio is not offered, or the pipeline is
  /// not up.
  Future<void> setLens(bool front, double ratio) =>
      throw UnimplementedError('setLens() has not been implemented.');

  /// Whether this device can record 4K with both cameras at once.
  Future<bool> supports4k() =>
      throw UnimplementedError('supports4k() has not been implemented.');

  Future<void> dispose() =>
      throw UnimplementedError('dispose() has not been implemented.');
}
