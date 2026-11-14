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
    return GestureDetector(
      key: Key(key),
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Text(
          label,
          style: TextStyle(
            color: on ? Colors.white : Colors.white38,
            fontWeight: on ? FontWeight.w800 : FontWeight.w400,
            fontSize: 16,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const Key('bottom-menu'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _item('Map', mapOn, onMap, 'menu-map'),
        _item('Front', frontPrimary, onFront, 'menu-front'),
        _item('Rear', !frontPrimary, onRear, 'menu-rear'),
        _item('Captions', captionsOn, onCaptions, 'menu-captions'),
        _item('Settings', true, onSettings, 'menu-settings'),
      ],
    );
  }
}
