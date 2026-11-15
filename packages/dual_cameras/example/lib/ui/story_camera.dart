import 'dart:typed_data';

import 'package:flutter/material.dart';

/// The thumbnail tile's rect in the overlay, for showMenu anchoring
/// (issue #50): the menu opens at the thumbnail. Computed at the tile —
/// the tile's own BuildContext is the only place its RenderBox is
/// reachable — and carried to the parent through onLastVideoTap.
RelativeRect _anchorRect(BuildContext tileContext) {
  final box = tileContext.findRenderObject() as RenderBox;
  final overlay =
      Overlay.of(tileContext).context.findRenderObject() as RenderBox;
  return RelativeRect.fromRect(
    Rect.fromPoints(
      box.localToGlobal(Offset.zero, ancestor: overlay),
      box.localToGlobal(box.size.bottomRight(Offset.zero),
          ancestor: overlay),
    ),
    Offset.zero & overlay.size,
  );
}

/// Presentation only: the capture session remains owned by DemoScreen.
///
/// Instagram-story style (issue #20, v5): the video fills the whole screen
/// and everything else is an overlay on top of it — the map circle, the
/// lens pills, the filter slider, the record button, the bottom menu.
/// The map is a Flutter overlay over the Texture, never composited into
/// the video, so it is preview-only by construction.
class StoryCamera extends StatelessWidget {
  const StoryCamera({
    super.key,
    required this.preview,
    required this.initialized,
    required this.recording,
    required this.busy,
    required this.status,
    required this.onCapture,
    required this.onPhoto,
    required this.onSwap,
    required this.onSettings,
    this.mapCircle,
    this.lensPills,
    this.filterSlider,
    this.bottomMenu,
    this.lastVideoThumb,
    this.onLastVideoTap,
  });

  final Widget preview;
  final bool initialized, recording, busy;
  final String status;
  final VoidCallback? onCapture, onPhoto, onSwap;
  final VoidCallback onSettings;

  /// Map circle overlay (top-left); null when the circle is off or the
  /// location permission was denied.
  final Widget? mapCircle;

  /// Lens switcher pills, directly above the filter slider; null when the
  /// API reported no lenses.
  final Widget? lensPills;

  /// iOS-style filter slider, directly above the record button.
  final Widget? filterSlider;

  /// Bottom text menu (Map / Front / Rear / Captions / Settings).
  final Widget? bottomMenu;

  // Last-video thumbnail (issue #50): the tile renders if and only if
  // onLastVideoTap != null — the parent passes it only after a recording
  // has stopped and saved, so the tile is hidden — not disabled — before
  // any recording and while recording. lastVideoThumb is the real frame
  // (null while generating or when generation failed: the tile falls
  // back to a video icon, and the menu still opens).
  //
  // Deviation from the design's §3 type (recorded in the PR): the
  // callback carries the thumbnail's RelativeRect instead of being a
  // plain VoidCallback. A VoidCallback cannot carry the anchor, and the
  // state cannot look a descendant up by key — the tile's own
  // BuildContext (see _anchorRect) is the only place its RenderBox is
  // reachable. The alternative (a GlobalKey) would break the literal
  // Key('last-video-thumbnail') the design and the CI gate rely on.
  final Uint8List? lastVideoThumb;
  final void Function(RelativeRect anchor)? onLastVideoTap;

  @override
  Widget build(BuildContext context) {
    final captureLabel = recording
        ? 'Stop recording'
        : initialized
            ? 'Start recording'
            : 'Open camera';
    return Scaffold(
      backgroundColor: const Color(0xFF09090D),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // The video fills the whole screen, no empty space.
          ColoredBox(color: Colors.black, child: preview),
          // Title + map circle, top-left over the video.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text('StoryCam',
                              style: TextStyle(
                                  fontSize: 25,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -1)),
                        ),
                        if (recording)
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Icon(Icons.fiber_manual_record,
                                color: Color(0xFFFF526D), size: 16),
                          ),
                        IconButton(
                          tooltip: 'Camera settings',
                          onPressed: onSettings,
                          icon: const Icon(Icons.tune_rounded),
                          constraints: const BoxConstraints(
                              minWidth: 48, minHeight: 48),
                        ),
                      ],
                    ),
                  ),
                  if (mapCircle != null) ...[
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: mapCircle!,
                    ),
                  ],
                ],
              ),
            ),
          ),
          // Lens pills, filter slider, record button, status, bottom menu.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (lensPills != null) lensPills!,
                  if (filterSlider != null) filterSlider!,
                  const SizedBox(height: 2),
                  // Record row (issue #50): a Stack wrapped in a
                  // full-width SizedBox — the full-width constraint the
                  // placement arithmetic depends on. A bare Stack sizes
                  // itself to its non-positioned children (default fit
                  // loose) and Positioned children do not contribute to
                  // its size, so without the wrap the Stack would be
                  // 80x80 and the clusters would land on top of the
                  // capture. Inside: capture 80x80 centred (pixel-
                  // centred on the screen centreline by construction),
                  // left cluster Positioned(left: 0) — thumbnail 56 +
                  // 12dp gap + photo button 48, = 116dp — right cluster
                  // Positioned(right: 0) — swap 48x48. At 320dp the
                  // capture spans 120-200dp, the left cluster ends at
                  // 116dp (4dp clear) and the right cluster starts at
                  // 272dp; the binding bound is W >= 312dp, not 244dp.
                  // N13: the Stack alignment centres the partially
                  // positioned clusters vertically in the 80dp-high row,
                  // so the 56dp thumbnail / 48dp photo sit level with
                  // the capture instead of top-aligned (a Stack
                  // defaults to top-start alignment).
                  SizedBox(
                    width: double.infinity,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Center(
                          child: Semantics(
                            key: const Key('capture-control'),
                            onTap: onCapture,
                            button: true,
                            enabled: onCapture != null,
                            label: busy ? 'Please wait' : captureLabel,
                            child: Tooltip(
                              message: captureLabel,
                              child: ExcludeSemantics(
                                child: SizedBox(
                                  width: 80,
                                  height: 80,
                                  child: OutlinedButton(
                                    style: OutlinedButton.styleFrom(
                                      padding: const EdgeInsets.all(7),
                                      shape: const CircleBorder(),
                                      side: BorderSide(
                                        color: onCapture == null
                                            ? Colors.white24
                                            : Colors.white,
                                        width: 3,
                                      ),
                                    ),
                                    onPressed: onCapture,
                                    child: busy
                                        ? const CircularProgressIndicator(
                                            strokeWidth: 3)
                                        : AnimatedContainer(
                                            duration: const Duration(
                                                milliseconds: 180),
                                            width: recording ? 28 : 58,
                                            height: recording ? 28 : 58,
                                            decoration: BoxDecoration(
                                              color: onCapture == null
                                                  ? Colors.white24
                                                  : const Color(0xFFFF526D),
                                              borderRadius:
                                                  BorderRadius.circular(
                                                      recording ? 7 : 40),
                                            ),
                                          ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 0,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (onLastVideoTap != null) ...[
                                Builder(
                                  builder: (tileContext) => Semantics(
                                    label: 'Last video',
                                    button: true,
                                    child: Tooltip(
                                      message: 'Last video',
                                      child: GestureDetector(
                                        key: const Key(
                                            'last-video-thumbnail'),
                                        onTap: () => onLastVideoTap!(
                                            _anchorRect(tileContext)),
                                        child: ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          child: Container(
                                            width: 56,
                                            height: 56,
                                            decoration: BoxDecoration(
                                              border: Border.all(
                                                  color: Colors.white,
                                                  width: 2),
                                            ),
                                            child: lastVideoThumb != null
                                                ? Image.memory(
                                                    lastVideoThumb!,
                                                    width: 56,
                                                    height: 56,
                                                    fit: BoxFit.cover)
                                                : const Icon(
                                                    Icons.video_library,
                                                    size: 28,
                                                    color: Colors.white70),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                              ],
                              IconButton.filledTonal(
                                tooltip: 'Take photo',
                                onPressed: onPhoto,
                                icon: const Icon(
                                    Icons.photo_camera_outlined),
                                constraints: const BoxConstraints(
                                    minHeight: 48, minWidth: 48),
                              ),
                            ],
                          ),
                        ),
                        Positioned(
                          right: 0,
                          child: IconButton.filledTonal(
                            tooltip: 'Swap cameras',
                            onPressed: onSwap,
                            icon: const Icon(Icons.cameraswitch_outlined),
                            constraints: const BoxConstraints(
                                minHeight: 48, minWidth: 48),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Semantics(
                    liveRegion: true,
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(status,
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: const Color(0xFFCAC6D5))),
                    ),
                  ),
                  const SizedBox(height: 2),
                  if (bottomMenu != null) bottomMenu!,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
