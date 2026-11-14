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
class MapCircle extends StatefulWidget {
  const MapCircle({
    super.key,
    required this.position,
    required this.headingDeg,
    required this.mode,
    this.size = 120,
    this.showTiles = true,
  });

  /// Current location; null until the first fix (plain disc meanwhile).
  final LatLng? position;

  /// Compass heading in degrees, 0 = north, clockwise.
  final double headingDeg;

  final CompassMode mode;

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

  @override
  void didUpdateWidget(MapCircle oldWidget) {
    super.didUpdateWidget(oldWidget);
    final position = widget.position;
    if (position != null && position != oldWidget.position) {
      // Re-center on the new fix; the dot stays in the middle of the
      // circle. move() is a no-op until the map is attached.
      _controller.move(position, 16);
    }
  }

  @override
  Widget build(BuildContext context) {
    final headingRad = widget.headingDeg * math.pi / 180;
    // Heading-up: the map turns under you (-heading); north-up: fixed.
    final mapRotation = widget.mode == CompassMode.headingUp ? -headingRad : 0.0;
    // The heading cone points where you face: up in heading-up, along the
    // heading in north-up.
    final coneRotation = widget.mode == CompassMode.headingUp ? 0.0 : headingRad;
    final position = widget.position;
    return Semantics(
      label: position == null
          ? 'Map, waiting for location'
          : 'Map, current location',
      child: SizedBox(
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
                child: position != null && widget.showTiles
                    ? IgnorePointer(
                        child: FlutterMap(
                          mapController: _controller,
                          options: MapOptions(
                            initialCenter: position,
                            initialZoom: 16,
                          ),
                          children: [
                            TileLayer(
                              urlTemplate:
                                  'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                              userAgentPackageName: 'app.storycam',
                              maxNativeZoom: 19,
                            ),
                          ],
                        ),
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
