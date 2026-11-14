import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Presentation only: the capture session remains owned by DemoScreen.
class StoryCamera extends StatelessWidget {
  const StoryCamera({
    super.key,
    required this.preview,
    required this.initialized,
    required this.recording,
    required this.busy,
    required this.captions,
    required this.filterName,
    required this.status,
    required this.onCapture,
    required this.onPhoto,
    required this.onSwap,
    required this.onFilters,
    required this.onCaptions,
    required this.onSettings,
    this.onShare,
  });

  final Widget preview;
  final bool initialized, recording, busy, captions;
  final String filterName, status;
  final VoidCallback? onCapture, onPhoto, onSwap, onFilters, onCaptions;
  final VoidCallback onSettings;
  // Share appears iff non-null (issue #14): the parent passes it only
  // after a recording has stopped and saved, so the button is hidden —
  // not disabled — before any recording and while recording.
  final VoidCallback? onShare;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF09090D),
      body: SafeArea(
        minimum: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
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
                  constraints:
                      const BoxConstraints(minWidth: 48, minHeight: 48),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: LayoutBuilder(builder: (context, constraints) {
                // A side rail gives the complete portrait canvas room on short
                // screens/landscape. Neither layout crops or stretches it.
                final compact = constraints.maxWidth >= 480 &&
                    constraints.maxWidth > constraints.maxHeight;
                final viewfinder = ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: ColoredBox(color: Colors.black, child: preview),
                );
                final controls = Scrollbar(
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: _controls(context),
                    ));
                if (compact) {
                  return Row(
                    children: [
                      Expanded(child: viewfinder),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: constraints.maxWidth * .48,
                        child: controls,
                      ),
                    ],
                  );
                }
                return Column(
                  children: [
                    Expanded(child: viewfinder),
                    SizedBox(
                      height: math.min(constraints.maxHeight,
                          math.max(112, constraints.maxHeight * .36)),
                      child: controls,
                    ),
                  ],
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controls(BuildContext context) {
    final captureLabel = recording
        ? 'Stop recording'
        : initialized
            ? 'Start recording'
            : 'Open camera';
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton.filledTonal(
              tooltip: 'Take photo',
              onPressed: onPhoto,
              icon: const Icon(Icons.photo_camera_outlined),
              constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
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
                          color:
                              onCapture == null ? Colors.white24 : Colors.white,
                          width: 3,
                        ),
                      ),
                      onPressed: onCapture,
                      child: busy
                          ? const CircularProgressIndicator(strokeWidth: 3)
                          : AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              width: recording ? 28 : 58,
                              height: recording ? 28 : 58,
                              decoration: BoxDecoration(
                                color: onCapture == null
                                    ? Colors.white24
                                    : const Color(0xFFFF526D),
                                borderRadius:
                                    BorderRadius.circular(recording ? 7 : 40),
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
              constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(busy ? 'Please wait…' : captureLabel,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        if (onShare != null) ...[
          SizedBox(
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
          const SizedBox(height: 8),
        ],
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            OutlinedButton.icon(
              onPressed: onFilters,
              icon: const Icon(Icons.auto_awesome_outlined, size: 19),
              label: Text('Filters · $filterName'),
            ),
            OutlinedButton.icon(
              onPressed: onCaptions,
              icon: Icon(
                  captions
                      ? Icons.closed_caption
                      : Icons.closed_caption_outlined,
                  size: 19),
              label: Text('Captions ${captions ? 'on' : 'off'}'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Semantics(
          liveRegion: true,
          child: Text(status,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: const Color(0xFFCAC6D5))),
        ),
      ],
    );
  }
}
