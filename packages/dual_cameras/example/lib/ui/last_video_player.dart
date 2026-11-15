import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Full-screen player for the last recorded video (issue #50).
///
/// The controller arrives already initialized (created by DemoScreen in
/// _openLastVideo, so an initialize() failure surfaces as status + _error
/// there and no route opens). This page owns playback and disposal: it
/// autoplays on open, a tap toggles play/pause, and the controller is
/// disposed on pop. Plays the original uncaptioned file — the same file
/// Share attaches.
class LastVideoPlayerPage extends StatefulWidget {
  const LastVideoPlayerPage({super.key, required this.controller});

  final VideoPlayerController controller;

  @override
  State<LastVideoPlayerPage> createState() => _LastVideoPlayerPageState();
}

class _LastVideoPlayerPageState extends State<LastVideoPlayerPage> {
  @override
  void initState() {
    super.initState();
    widget.controller.play();
  }

  @override
  void dispose() {
    unawaited(widget.controller.dispose());
    super.dispose();
  }

  String _timeText(Duration position, Duration duration) {
    String two(int n) => n.toString().padLeft(2, '0');
    String fmt(Duration d) =>
        '${two(d.inMinutes)}:${two(d.inSeconds.remainder(60))}';
    return '${fmt(position)} / ${fmt(duration)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: widget.controller.value.aspectRatio,
              child: GestureDetector(
                onTap: () {
                  if (widget.controller.value.isPlaying) {
                    widget.controller.pause();
                  } else {
                    widget.controller.play();
                  }
                  setState(() {});
                },
                child: VideoPlayer(widget.controller),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            child: SafeArea(
              child: IconButton(
                key: const Key('player-close'),
                tooltip: 'Close player',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding:
                    const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: widget.controller,
                  builder: (context, value, _) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      VideoProgressIndicator(
                        widget.controller,
                        allowScrubbing: true,
                        colors: const VideoProgressColors(
                          playedColor: Color(0xFFFF526D),
                          backgroundColor: Colors.white24,
                          bufferedColor: Colors.white38,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            value.isPlaying
                                ? Icons.pause
                                : Icons.play_arrow,
                            color: Colors.white,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _timeText(value.position, value.duration),
                            style: const TextStyle(color: Colors.white),
                          ),
                        ],
                      ),
                    ],
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
