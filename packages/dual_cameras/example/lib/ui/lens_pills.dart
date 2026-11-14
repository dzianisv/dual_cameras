import 'package:dual_cameras/dual_cameras.dart';
import 'package:flutter/material.dart';

/// Lens switcher pills (issue #20, v5): a row directly above the filter
/// slider, over the video. Selected pill is white; the rest are dark.
/// Shows ONLY the lenses the camera API reports for the active camera —
/// the list comes from [lenses], never hardcoded. Empty list = no pills
/// (the API reported nothing for this camera).
class LensPills extends StatelessWidget {
  const LensPills({
    super.key,
    required this.lenses,
    required this.selectedRatio,
    required this.onSelected,
    this.enabled = true,
  });

  final List<LensOption> lenses;

  /// Currently selected zoom ratio, or null when nothing is selected yet
  /// (the main lens is the default).
  final double? selectedRatio;
  final ValueChanged<double> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (lenses.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      key: const Key('lens-pills'),
      height: 40,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final lens in lenses)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: GestureDetector(
                key: ValueKey('lens-${lens.label}'),
                onTap: enabled ? () => onSelected(lens.ratio) : null,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: selectedRatio == lens.ratio
                        ? Colors.white
                        : Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Text(
                    lens.label,
                    style: TextStyle(
                      color: selectedRatio == lens.ratio
                          ? Colors.black
                          : Colors.white,
                      fontWeight: selectedRatio == lens.ratio
                          ? FontWeight.w800
                          : FontWeight.w500,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
