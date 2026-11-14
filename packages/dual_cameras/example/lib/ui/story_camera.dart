import 'package:flutter/material.dart';

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
    this.onShare,
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

  // Share appears iff non-null (issue #14): the parent passes it only
  // after a recording has stopped and saved, so the button is hidden —
  // not disabled — before any recording and while recording.
  final VoidCallback? onShare;

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
                  if (onShare != null) ...[
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 16),
                      child: SizedBox(
                        width: double.infinity,
                        child: Semantics(
                          label: 'Share video',
                          button: true,
                          child: FilledButton.icon(
                            key: const Key('share-button'),
                            onPressed: onShare,
                            icon: const Icon(Icons.share),
                            label: const Text('Share'),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(48, 48),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (lensPills != null) lensPills!,
                  if (filterSlider != null) filterSlider!,
                  const SizedBox(height: 2),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton.filledTonal(
                        tooltip: 'Take photo',
                        onPressed: onPhoto,
                        icon: const Icon(Icons.photo_camera_outlined),
                        constraints: const BoxConstraints(
                            minHeight: 48, minWidth: 48),
                      ),
                      Semantics(
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
                                          borderRadius: BorderRadius.circular(
                                              recording ? 7 : 40),
                                        ),
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      IconButton.filledTonal(
                        tooltip: 'Swap cameras',
                        onPressed: onSwap,
                        icon: const Icon(Icons.cameraswitch_outlined),
                        constraints: const BoxConstraints(
                            minHeight: 48, minWidth: 48),
                      ),
                    ],
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
