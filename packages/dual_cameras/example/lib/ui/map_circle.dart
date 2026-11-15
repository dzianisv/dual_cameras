import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../map/camera_settings.dart';

/// Live map circle, top-left of the camera screen (issue #20, v5).
///
/// A Flutter overlay over the video Texture — preview-only, never burned
/// into the recording. The map rotates with the compass in heading-up mode
/// (default); the blue dot stays centered on the current location. Offline
/// or without a position yet, the circle is a plain disc with the N arrow
/// — never a crash, never a spinner.
///
/// Tiles are OpenStreetMap raster tiles via flutter_map (no key). The map
/// itself is rotated with a [Transform] so the whole tile layer turns;
/// the dot + heading cone stay centered on top, unrotated.
///
/// Zoom (issue #47): the map is a controlled widget — [zoom] is the single
/// source of truth owned by the parent (the persisted `mapZoom` setting).
/// Pinch and double-tap zoom change it and report the final zoom once per
/// gesture through [onZoomChanged]; the parent passes the new value back
/// and [didUpdateWidget] applies it. The dot is re-centered on the
/// position after every gesture and every position fix (a double-tap zoom
/// shifts the center toward the tap point, so the re-center is load-bearing
/// there). A position fix arriving mid-gesture never jumps the map: the
/// re-center waits for gesture end.
class MapCircle extends StatefulWidget {
  const MapCircle({
    super.key,
    required this.position,
    required this.headingDeg,
    required this.mode,
    required this.zoom,
    this.placeName,
    this.onZoomChanged,
    this.size = 120,
    this.showTiles = true,
  });

  /// Current location; null until the first fix (plain disc meanwhile).
  final LatLng? position;

  /// Compass heading in degrees, 0 = north, clockwise.
  final double headingDeg;

  final CompassMode mode;

  /// Live zoom, owned by the parent (issue #47, D1/D4). The map is first
  /// painted at this zoom and re-zooms when it changes.
  final double zoom;

  /// Place name for the shown location (issue #47, D7); null while
  /// unknown — no pill is shown then.
  final String? placeName;

  /// Called exactly once per pinch / double-tap gesture, at gesture end,
  /// with the final zoom (issue #47, D4). The parent persists it and
  /// passes it back as [zoom].
  final ValueChanged<double>? onZoomChanged;

  /// Circle diameter in logical px (wireframe v5: ~120).
  final double size;

  /// False in widget tests: no tile fetches, disc only (keeps tests
  /// hermetic — no network in `flutter test`).
  final bool showTiles;

  @override
  State<MapCircle> createState() => _MapCircleState();
}

class _MapCircleState extends State<MapCircle> {
  final MapController _controller = MapController();

  /// Last zoom applied to the controller (D4): initialized to the
  /// parent's zoom so a relaunch first paints at the stored zoom, and
  /// recorded on every report so the parent echo passes the same zoom
  /// back and [didUpdateWidget] sees no change.
  late double _lastAppliedZoom = widget.zoom;

  /// A pinch / double-tap zoom is in flight (D4): set on the Start
  /// events, cleared on the End events. While set, [didUpdateWidget]
  /// skips the re-center — a fix arriving mid-gesture must not overwrite
  /// the gesture's camera state (flutter_map still computes from the
  /// scale-start snapshot).
  bool _gestureInProgress = false;

  /// Re-center when the camera center is actually off the position by
  /// more than this (D4): a pinch with pinch-move off does not drift the
  /// center, so this is a safety net for the pinch and genuinely needed
  /// after a double-tap (which moves the center toward the tap point).
  static const _recenterEpsilonMeters = 5.0;

  /// Whether the previous build constructed a FlutterMap (D4): the
  /// controller is attached only then. `oldWidget.position != null` alone
  /// does not prove it — with showTiles == false no map is ever built
  /// and move() would throw on the unattached controller.
  bool _mapBuilt = false;

  @override
  void didUpdateWidget(MapCircle oldWidget) {
    super.didUpdateWidget(oldWidget);
    final position = widget.position;
    if (position == null) return;
    // Never move() before the map is attached (D4): on the first fix the
    // map is not attached yet, and the first fix is already the map's
    // initialCenter, so nothing is lost by skipping. The guard also
    // covers showTiles == false, where no FlutterMap is ever built.
    if (!_mapBuilt || oldWidget.position == null) return;
    if (_gestureInProgress) return;
    if (widget.zoom != _lastAppliedZoom) {
      // Parent zoom change (Settings slider drag / relaunch restore):
      // apply it and re-center at the new zoom in one move.
      _lastAppliedZoom = widget.zoom;
      _controller.move(position, widget.zoom);
      return;
    }
    if (position != oldWidget.position) {
      // New fix: re-center, keeping the current (live) zoom — a position
      // update after a pinch must NOT reset the zoom.
      _controller.move(position, _controller.camera.zoom);
    }
  }

  void _onMapEvent(MapEvent event) {
    if (event is MapEventMoveStart || event is MapEventDoubleTapZoomStart) {
      _gestureInProgress = true;
      return;
    }
    if (event is MapEventMoveEnd || event is MapEventDoubleTapZoomEnd) {
      _gestureInProgress = false;
      final finalZoom = event.camera.zoom;
      final position = widget.position;
      if (position != null) {
        // Re-center with the latest position (a fix may have arrived
        // mid-gesture and been deferred), but only when the center is
        // actually off the position.
        final offBy = const Distance().as(
          LengthUnit.Meter,
          event.camera.center,
          position,
        );
        if (offBy > _recenterEpsilonMeters) {
          _controller.move(position, finalZoom);
        }
      }
      // Record the reported zoom as last-applied, so the parent echo from
      // onZoomChanged passes the same zoom back and didUpdateWidget moves
      // nothing. Report exactly once per gesture: neither End event fires
      // continuously, and move() emits only MapEventMove (never an End
      // event), so the re-center cannot re-trigger this handler.
      _lastAppliedZoom = finalZoom;
      widget.onZoomChanged?.call(finalZoom);
    }
  }

  @override
  Widget build(BuildContext context) {
    final headingRad = widget.headingDeg * math.pi / 180;
    // Heading-up: the map turns under you (-heading); north-up: fixed.
    final mapRotation =
        widget.mode == CompassMode.headingUp ? -headingRad : 0.0;
    // The heading cone points where you face: up in heading-up, along the
    // heading in north-up.
    final coneRotation =
        widget.mode == CompassMode.headingUp ? 0.0 : headingRad;
    final position = widget.position;
    final tilesShown = position != null && widget.showTiles;
    _mapBuilt = tilesShown;
    return Semantics(
      label: position == null
          ? 'Map, waiting for location'
          : 'Map, current location',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            key: const Key('map-circle'),
            width: widget.size,
            height: widget.size,
            child: ClipOval(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Rotating layer: tiles (or the plain disc) + nothing else.
                  Transform.rotate(
                    angle: mapRotation,
                    child: tilesShown
                        ? FlutterMap(
                            mapController: _controller,
                            options: MapOptions(
                              initialCenter: position,
                              initialZoom: widget.zoom,
                              minZoom: CameraSettings.minMapZoom,
                              maxZoom: CameraSettings.maxMapZoom,
                              interactionOptions: const InteractionOptions(
                                flags: InteractiveFlag.pinchZoom |
                                    InteractiveFlag.doubleTapZoom,
                              ),
                              onMapEvent: _onMapEvent,
                            ),
                            children: [
                              TileLayer(
                                urlTemplate:
                                    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                userAgentPackageName: 'app.storycam',
                                maxNativeZoom: 19,
                              ),
                            ],
                          )
                        : Container(color: const Color(0xFFE8F0E4)),
                  ),
                  // N badge: travels around the circle edge to where north is
                  // (heading-up) and stays at the top in north-up; the letter
                  // itself is counter-rotated so it never reads upside-down.
                  Transform.rotate(
                    angle: mapRotation,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Transform.rotate(
                          angle: -mapRotation,
                          child: const Text('N',
                              style: TextStyle(
                                  color: Color(0xFFFF526D),
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13)),
                        ),
                      ),
                    ),
                  ),
                  // Heading cone + blue dot, centered, unrotated with the map.
                  if (position != null) ...[
                    Center(
                      child: Transform.rotate(
                        angle: coneRotation,
                        child: CustomPaint(
                          key: const Key('map-heading-cone'),
                          size: const Size(34, 40),
                          painter: _HeadingConePainter(),
                        ),
                      ),
                    ),
                    const Center(
                      child: DecoratedBox(
                        key: Key('map-dot'),
                        decoration: BoxDecoration(
                          color: Color(0xFF2F80ED),
                          shape: BoxShape.circle,
                          border: Border.fromBorderSide(
                              BorderSide(color: Colors.white, width: 2)),
                        ),
                        child: SizedBox(width: 12, height: 12),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          // Place pill (issue #47, D7): below the circle, never inside the
          // SizedBox/ClipOval above (there it would be clipped to the
          // circle / overflow 120 px). Preview-only, never burned into
          // the recording — same as the map itself.
          if (widget.placeName != null) ...[
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Container(
                key: const Key('map-place-name'),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  widget.placeName!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              ),
            ),
          ],
          // OSM attribution (issue #47, D6): the app's first — shown
          // whenever tiles are shown.
          if (tilesShown)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                '© OpenStreetMap contributors',
                key: Key('map-attribution'),
                style: TextStyle(fontSize: 9, color: Colors.white70),
              ),
            ),
        ],
      ),
    );
  }
}

/// Translucent white triangle pointing up (direction of travel), with a
/// soft outline so it reads over any map.
class _HeadingConePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..style = PaintingStyle.fill;
    final outline = Paint()
      ..color = const Color(0xFF2F80ED)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final path = ui.Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, paint);
    canvas.drawPath(path, outline);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
