import 'dart:async';

import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';

/// Position + heading for the map circle (issue #20).
///
/// The screen never touches a location plugin directly: every failure (no
/// permission, location off, no sensor, no plugin in widget tests) degrades
/// to "no data" instead of a crash, and the circle falls back to a plain
/// disc with the N arrow. Nothing is uploaded: the position only feeds the
/// on-screen map and the OSM tile requests for the visible area (tile
/// fetches inherently send coarse tile coordinates to OSM — that is the
/// only thing that leaves the device).
///
/// The stream factories are injectable so widget tests can feed a fixed
/// position + heading without a plugin.
class MapLocationService {
  MapLocationService({
    Future<bool> Function()? requestLocationPermission,
    Future<bool> Function()? checkLocationPermission,
    Stream<LatLng> Function()? positionStream,
    Stream<double> Function()? headingStream,
  })  : _requestLocationPermission =
            requestLocationPermission ?? _defaultRequestPermission,
        _checkLocationPermission =
            checkLocationPermission ?? _defaultCheckPermission,
        _headingStream = headingStream ?? _defaultHeadingStream {
    // The default position stream is the instance method (it records the
    // fix accuracy on `this`); an injected stream replaces it wholesale.
    _positionStream = positionStream ?? _defaultPositionStreamWithAccuracy;
  }

  final Future<bool> Function() _requestLocationPermission;
  final Future<bool> Function() _checkLocationPermission;
  late final Stream<LatLng> Function() _positionStream;
  final Stream<double> Function() _headingStream;

  /// Accuracy of the last position fix in meters (Geolocator
  /// `Position.accuracy`), or null before the first fix / when the
  /// position source does not report one (issue #47, D6: place lookups
  /// are skipped while the fix is worse than 50 m, so GPS jitter cannot
  /// random-walk the app past the 100 m lookup gate). Updated inside the
  /// default position-stream mapping — the stream type stays LatLng.
  double? _lastAccuracyMeters;
  double? get lastAccuracyMeters => _lastAccuracyMeters;

  final StreamController<LatLng> _positions =
      StreamController<LatLng>.broadcast();
  final StreamController<double> _headings =
      StreamController<double>.broadcast();
  StreamSubscription<LatLng>? _positionSub;
  StreamSubscription<double>? _headingSub;

  /// Live position (dot on the map) and heading in degrees, 0 = north,
  /// clockwise.
  Stream<LatLng> get positions => _positions.stream;
  Stream<double> get headings => _headings.stream;

  bool get running => _positionSub != null || _headingSub != null;

  static Future<bool> _defaultRequestPermission() async {
    try {
      return (await Permission.location.request()).isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Read the current permission state WITHOUT prompting.
  static Future<bool> _defaultCheckPermission() async {
    try {
      return (await Permission.location.status).isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Default position stream that also records the fix accuracy. The
  /// stream type stays `Stream<LatLng>` — accuracy is captured inside
  /// the mapping, so no caller changes.
  Stream<LatLng> _defaultPositionStreamWithAccuracy() {
    try {
      return Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      ).map((p) {
        _lastAccuracyMeters = p.accuracy;
        return LatLng(p.latitude, p.longitude);
      });
    } catch (_) {
      return const Stream<LatLng>.empty();
    }
  }

  static Stream<double> _defaultHeadingStream() {
    try {
      final events = FlutterCompass.events;
      if (events == null) return const Stream<double>.empty();
      return events
          .map((e) => e.heading)
          .where((h) => h != null)
          .map((h) => h!);
    } catch (_) {
      return const Stream<double>.empty();
    }
  }

  /// Ask for location permission once. `false` on denial or any error —
  /// the caller remembers that and never re-prompts in a loop.
  Future<bool> ensurePermission() => _requestLocationPermission();

  /// Current permission state, without prompting.
  Future<bool> isGranted() => _checkLocationPermission();

  /// Subscribe to the position + heading streams. Safe to call repeatedly;
  /// stream errors are swallowed (no data, not a crash).
  void start() {
    if (running) return;
    try {
      _positionSub = _positionStream().listen(
        _positions.add,
        onError: (_) {},
      );
    } catch (_) {
      // No position source — the circle shows a plain disc.
    }
    try {
      _headingSub = _headingStream().listen(
        _headings.add,
        onError: (_) {},
      );
    } catch (_) {
      // No compass — the map stays north-up.
    }
  }

  /// Stop the platform streams (e.g. the user hid the circle). The
  /// broadcast controllers stay open — [start] can resume later.
  void stop() {
    unawaited(_positionSub?.cancel());
    unawaited(_headingSub?.cancel());
    _positionSub = null;
    _headingSub = null;
  }

  void dispose() {
    stop();
    unawaited(_positions.close());
    unawaited(_headings.close());
  }
}
