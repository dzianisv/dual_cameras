import 'package:dual_cameras/dual_cameras.dart';
import 'package:flutter/material.dart';

/// iOS-style text filter slider (issue #20, v3): the filter names in a
/// horizontal row directly above the record button, over the video.
/// Selected filter is big and white with a dot under it, the rest dimmed;
/// the row scrolls sideways. Tap a name to switch.
///
/// The grade applies to the live preview and the recording together (one
/// final blit pass on both native sides), so switching here is the whole
/// story — no separate recording path.
class FilterSlider extends StatelessWidget {
  const FilterSlider({
    super.key,
    required this.selected,
    required this.onSelected,
    this.enabled = true,
  });

  static const List<VideoFilter> filters = [
    VideoFilter.none,
    VideoFilter.moody,
    VideoFilter.hyper,
    VideoFilter.midnight,
    VideoFilter.simple,
    VideoFilter.jakarta,
    VideoFilter.gta,
    VideoFilter.sanAndreas,
    VideoFilter.gta3,
  ];

  /// Display name per filter. The game-look names (GTA, San Andreas,
  /// GTA 3) are as heard from Den and unconfirmed (issue #20).
  static String label(VideoFilter filter) => switch (filter) {
        VideoFilter.none => 'Original',
        VideoFilter.moody => 'Moody',
        VideoFilter.hyper => 'Hyper',
        VideoFilter.midnight => 'Midnight',
        VideoFilter.simple => 'Simple',
        VideoFilter.jakarta => 'Jakarta',
        VideoFilter.gta => 'GTA',
        VideoFilter.sanAndreas => 'San Andreas',
        VideoFilter.gta3 => 'GTA 3',
      };

  final VideoFilter selected;
  final ValueChanged<VideoFilter> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('filter-slider'),
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: filters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 18),
        itemBuilder: (context, index) {
          final filter = filters[index];
          final isSelected = filter == selected;
          return GestureDetector(
            key: ValueKey('filter-${filter.name}'),
            onTap: enabled ? () => onSelected(filter) : null,
            behavior: HitTestBehavior.opaque,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label(filter),
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.white54,
                    fontSize: isSelected ? 19 : 15,
                    fontWeight:
                        isSelected ? FontWeight.w800 : FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 3),
                Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: isSelected ? Colors.white : Colors.transparent,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
