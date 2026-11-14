import 'package:flutter/material.dart';

/// Bottom text menu (issue #20, v2/v4): Map / Front / Rear / Captions /
/// Settings, over the video at the bottom of the screen.
///
/// The word shows the state at a glance — bold white = on, transparent
/// and not bold = off. Settings is a button, so it stays bold white.
/// Tapping an item opens the Settings dialog at that section; it never
/// toggles the feature directly (Den, 2026-11-14).
///
/// What "on" means per item: Map = the location circle is shown; Front /
/// Rear = that camera is the full-frame (primary) one; Captions =
/// auto-captions are on.
class CameraBottomMenu extends StatelessWidget {
  const CameraBottomMenu({
    super.key,
    required this.mapOn,
    required this.frontPrimary,
    required this.captionsOn,
    required this.onMap,
    required this.onFront,
    required this.onRear,
    required this.onCaptions,
    required this.onSettings,
  });

  final bool mapOn;
  final bool frontPrimary;
  final bool captionsOn;
  final VoidCallback onMap;
  final VoidCallback onFront;
  final VoidCallback onRear;
  final VoidCallback onCaptions;
  final VoidCallback onSettings;

  Widget _item(String label, bool on, VoidCallback onTap, String key) {
    // FittedBox (issue #20 fix round 2 / I3, second pass): each item
    // flexes to an equal share AND its label shrinks to fit on one
    // line. Wrapping the labels instead grew the menu to 3-4 lines at
    // large text scales and pushed the record button off-screen on
    // short screens (320x480 text 2.0) — the menu must stay one line
    // tall at any scale. The full word stays visible and the whole
    // item stays tappable.
    return GestureDetector(
      key: Key(key),
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: on ? Colors.white : Colors.white38,
              fontWeight: on ? FontWeight.w800 : FontWeight.w400,
              fontSize: 16,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Each item flexes to an equal share of the width (issue #20 fix
    // round 2 / I3): five fixed-width items overflowed 165-683px on
    // narrow screens and at large text scales. Each label also shrinks
    // to fit its share on one line (FittedBox, second pass) so the
    // menu stays one line tall at any scale — wrapping the labels
    // instead pushed the record button off-screen on short screens.
    return Row(
      key: const Key('bottom-menu'),
      children: [
        Expanded(child: _item('Map', mapOn, onMap, 'menu-map')),
        Expanded(child: _item('Front', frontPrimary, onFront, 'menu-front')),
        Expanded(child: _item('Rear', !frontPrimary, onRear, 'menu-rear')),
        Expanded(
            child: _item('Captions', captionsOn, onCaptions, 'menu-captions')),
        Expanded(child: _item('Settings', true, onSettings, 'menu-settings')),
      ],
    );
  }
}
