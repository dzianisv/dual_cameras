import 'package:dual_cameras/dual_cameras.dart';
import 'package:flutter/material.dart';

/// Lens switcher pills (issue #20, v5): a row directly above the filter
/// slider, over the video. Selected pill is white; the rest are dark.
/// Shows ONLY the lenses the camera API reports for the active camera —
/// the list comes from [lenses], never hardcoded. Empty list = no pills
/// (the API reported nothing for this camera). The pills stay enabled
/// while a camera command is in flight (issue #48): a tap that lands
/// mid-command is queued by the screen instead of vanishing silently,
/// so there is no disabled state here.
class LensPills extends StatelessWidget {
  const LensPills({
    super.key,
    required this.lenses,
    required this.selectedRatio,
    required this.onSelected,
  });

  final List<LensOption> lenses;

  /// Currently selected zoom ratio, or null when nothing is selected yet
  /// (the main lens is the default).
  final double? selectedRatio;
  final ValueChanged<double> onSelected;

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
                onTap: () => onSelected(lens.ratio),
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
