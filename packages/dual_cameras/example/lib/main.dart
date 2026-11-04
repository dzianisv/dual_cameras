import 'package:dual_cameras/dual_cameras.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:permission_handler/permission_handler.dart';

import 'captions/caption_models.dart';
import 'captions/caption_pipeline.dart';
import 'captions/model_manager.dart';
import 'captions/transcriber.dart';

void main() => runApp(const DemoApp());

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'dual_cameras',
      theme: ThemeData.dark(useMaterial3: true),
      home: const DemoScreen(),
    );
  }
}

class DemoScreen extends StatefulWidget {
  const DemoScreen({super.key});

  @override
  State<DemoScreen> createState() => _DemoScreenState();
}

class _DemoScreenState extends State<DemoScreen> {
  final DualCameraController _controller = DualCameraController();
  CameraCapabilities? _caps;
  String _status = 'Probing…';
  String? _lastFile;
  bool _circle = true; // Telegram-style: circular selfie inset by default.

  // Exposure (EV) slider — the Sony-style dial, applied live to both cameras.
  double _ev = 0.0;
  double _evMin = -2.0;
  double _evMax = 2.0;
  double _evStep = 1 / 3;
  bool _evSupported = false;

  // Color-grade filter (v0.3.0): live in preview + recording.
  VideoFilter _filter = VideoFilter.none;

  // Auto-captions (v0.2.0): on-device STT + karaoke burn-in, OFF by default.
  bool _captions = false;
  String? _captionStatus;
  String? _captionedFile;
  final CaptionPipeline _captionPipeline = CaptionPipeline();
  final ModelManager _modelManager = ModelManager();
  final Transcriber _transcriber = Transcriber();

  // Live geometry tuning (debug channel) — to dial in the front/back
  // orientation and fix any stretch directly on the device.
  static const MethodChannel _debug = MethodChannel('dual_cameras/debug');
  int _frontOffset = 90; // matches FRONT_ROTATION_OFFSET default
  int _backOffset = -90; // matches BACK_ROTATION_OFFSET default
  bool _mirrorFront = true;
  double _frontAspect = 0; // 0 = auto (use camera-reported)
  double _backAspect = 0;

  LayoutConfig _layout() => DualLayout.pictureInPicture(
        insetScale: 0.32,
        margin: 16,
        circleInset: _circle,
      );

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final caps = await DualCameraController.probeSupport();
    if (!mounted) return;
    setState(() {
      _caps = caps;
      _status = caps.isSupported
          ? 'Supported (up to ${caps.maxWidth}×${caps.maxHeight}) — grant permissions to start'
          : 'Not supported on this device (${caps.reason?.name ?? 'unknown'})';
    });
  }

  Future<void> _start() async {
    final granted = await [Permission.camera, Permission.microphone].request();
    if (granted.values.any((s) => !s.isGranted)) {
      setState(() => _status = 'Camera/microphone permission denied');
      return;
    }
    try {
      await _controller.initialize(layout: _layout());
      final range = await _controller.getExposureCompensationRange();
      if (!mounted) return;
      setState(() {
        _status = 'Initialized';
        _evSupported = range.minEv < range.maxEv && range.stepEv > 0;
        if (_evSupported) {
          _evMin = range.minEv;
          _evMax = range.maxEv;
          _evStep = range.stepEv;
          _ev = 0.0;
        }
      });
    } catch (e) {
      setState(() => _status = 'initialize failed: $e');
    }
  }

  Future<void> _setEv(double v) async {
    setState(() => _ev = v);
    try {
      await _controller.setExposureCompensation(v);
    } catch (e) {
      setState(() => _status = 'EV failed: $e');
    }
  }

  String _evLabel(double v) =>
      '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)} EV';

  Future<void> _setFilter(VideoFilter f) async {
    setState(() => _filter = f);
    await _guard(() => _controller.setFilter(f), 'filter ${f.name}');
  }

  Widget _filterChips() {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      children: [
        ChoiceChip(
          label: const Text('None'),
          selected: _filter == VideoFilter.none,
          onSelected: (_) => _setFilter(VideoFilter.none),
        ),
        ChoiceChip(
          label: const Text('Moody'),
          selected: _filter == VideoFilter.moody,
          onSelected: (_) => _setFilter(VideoFilter.moody),
        ),
      ],
    );
  }

  Widget _evRow() {
    final divisions =
        _evStep > 0 ? ((_evMax - _evMin) / _evStep).round().clamp(1, 48) : null;
    return Row(
      children: [
        const SizedBox(width: 110, child: Text('Exposure')),
        Expanded(
          child: Slider(
            min: _evMin,
            max: _evMax,
            divisions: divisions,
            label: _evLabel(_ev),
            value: _ev.clamp(_evMin, _evMax).toDouble(),
            onChanged: _setEv,
          ),
        ),
        SizedBox(
          width: 64,
          child: Text(_evLabel(_ev), textAlign: TextAlign.right),
        ),
      ],
    );
  }

  Future<void> _guard(Future<void> Function() action, String label) async {
    try {
      await action();
      setState(() => _status = '$label ok');
    } catch (e) {
      setState(() => _status = '$label failed: $e');
    }
  }

  /// Stop recording, save to gallery, then optionally run the auto-captions
  /// pipeline (extract audio -> on-device STT -> karaoke burn-in). The
  /// original uncaptioned mp4 is always kept; the captioned one is a second
  /// file. Any captions failure falls back to the plain video.
  Future<void> _stop() async {
    try {
      _lastFile = await _controller.stopRecording();
      await Gal.putVideo(_lastFile!);
      setState(() {
        _status = 'stop → gallery ok';
        _captionStatus = null;
        _captionedFile = null;
      });
    } catch (e) {
      setState(() => _status = 'stop failed: $e');
      return;
    }
    if (!_captions) return;
    final mp4 = _lastFile;
    if (mp4 == null) return;
    try {
      setState(() => _captionStatus = 'Extracting audio…');
      final wav = await _captionPipeline.extractAudio(mp4);

      setState(() => _captionStatus = 'Preparing speech model…');
      final model = await _modelManager.ensureModel(
        onProgress: (p) => setState(() => _captionStatus =
            'Downloading speech model ${(p * 100).toStringAsFixed(0)}%'),
      );

      setState(() => _captionStatus = 'Transcribing… (on-device)');
      // Let the progress state paint before the blocking decode.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final List<CaptionWord> words = await _transcriber.transcribe(
        wavPath: wav,
        model: model,
      );
      if (words.isEmpty) {
        setState(() =>
            _captionStatus = 'No speech detected — keeping plain video');
        return;
      }

      setState(() =>
          _captionStatus = 'Burning captions… (${words.length} words)');
      final captioned = await _captionPipeline.burnCaptions(
        mp4Path: mp4,
        words: words,
      );
      await Gal.putVideo(captioned);
      if (!mounted) return;
      setState(() {
        _captionedFile = captioned;
        _captionStatus = 'Captions done — ${words.length} words';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() =>
          _captionStatus = 'Captions failed ($e) — plain video kept');
    }
  }

  int _norm(int deg) => ((deg % 360) + 360) % 360;

  Future<void> _setRotation(bool front, int offset) async {
    final norm = _norm(offset);
    setState(() => front ? _frontOffset = norm : _backOffset = norm);
    await _debug.invokeMethod('setRotationOffset', {'front': front, 'offset': norm});
  }

  Future<void> _setAspect(bool front, double aspect) async {
    setState(() => front ? _frontAspect = aspect : _backAspect = aspect);
    await _debug.invokeMethod('setAspectOverride', {'front': front, 'aspect': aspect});
  }

  Future<void> _setMirror(bool on) async {
    setState(() => _mirrorFront = on);
    await _debug.invokeMethod('setMirrorFront', {'on': on});
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _rotationRow(String label, bool front, int offset) {
    return Row(
      children: [
        SizedBox(width: 110, child: Text(label)),
        IconButton(
          icon: const Icon(Icons.rotate_left),
          onPressed: () => _setRotation(front, offset - 90),
        ),
        SizedBox(
          width: 44,
          child: Text('$offset°', textAlign: TextAlign.center),
        ),
        IconButton(
          icon: const Icon(Icons.rotate_right),
          onPressed: () => _setRotation(front, offset + 90),
        ),
        const SizedBox(width: 4),
        for (final d in const [0, 90, 180, 270])
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: ChoiceChip(
              label: Text('$d'),
              selected: offset == d,
              onSelected: (_) => _setRotation(front, d),
            ),
          ),
      ],
    );
  }

  Widget _aspectRow(String label, bool front, double aspect) {
    return Row(
      children: [
        SizedBox(width: 110, child: Text(label)),
        Expanded(
          child: Slider(
            min: 0,
            max: 2,
            divisions: 40,
            label: aspect == 0 ? 'auto' : aspect.toStringAsFixed(2),
            value: aspect,
            onChanged: (v) => _setAspect(front, v),
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(
            aspect == 0 ? 'auto' : aspect.toStringAsFixed(2),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }

  Widget _debugPanel() {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        title: const Text('Debug tuning'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        children: [
          _rotationRow('Front rot', true, _frontOffset),
          _rotationRow('Back rot', false, _backOffset),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Mirror front'),
            value: _mirrorFront,
            onChanged: _setMirror,
          ),
          _aspectRow('Front aspect', true, _frontAspect),
          _aspectRow('Back aspect', false, _backAspect),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () {
                _setAspect(true, 0);
                _setAspect(false, 0);
              },
              child: const Text('Reset aspect → auto'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('dual_cameras')),
      body: ValueListenableBuilder<DualCameraValue>(
        valueListenable: _controller,
        builder: (context, value, _) {
          return Column(
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(
                      color: Colors.black,
                      child: DualCameraPreview(
                        _controller,
                        placeholder: const Center(
                          child: Text('Live preview appears on a real device'),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 8,
                      left: 8,
                      child: DualCameraStatsOverlay(_controller),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(_status, textAlign: TextAlign.center),
                    if (value.thermal != ThermalLevel.nominal)
                      Text('Thermal: ${value.thermal.name}',
                          style: const TextStyle(color: Colors.orange)),
                    if (_lastFile != null) Text('Saved: $_lastFile'),
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton(
                          onPressed: (_caps?.isSupported ?? false) &&
                                  !value.isInitialized
                              ? _start
                              : null,
                          child: const Text('Initialize'),
                        ),
                        FilledButton(
                          onPressed: value.isInitialized && !value.isRecording
                              ? () =>
                                  _guard(_controller.startRecording, 'record')
                              : null,
                          child: const Text('Record'),
                        ),
                        FilledButton(
                          onPressed:
                              value.isRecording ? () => _guard(_stop, 'stop') : null,
                          child: const Text('Stop'),
                        ),
                        FilledButton(
                          onPressed: value.isInitialized
                              ? () => _guard(() async {
                                    _lastFile = await _controller.takePhoto();
                                    await Gal.putImage(_lastFile!);
                                  }, 'photo → gallery')
                              : null,
                          child: const Text('Photo'),
                        ),
                        FilledButton(
                          onPressed: value.isInitialized
                              ? () => _guard(_controller.swapPrimary, 'swap')
                              : null,
                          child: const Text('Swap'),
                        ),
                        FilledButton(
                          onPressed: value.isInitialized
                              ? () => _guard(() async {
                                    setState(() => _circle = !_circle);
                                    await _controller.setLayout(_layout());
                                  }, _circle ? 'circle off' : 'circle on')
                              : null,
                          child: Text(_circle ? 'Square' : 'Circle'),
                        ),
                      ],
                    ),
                    if (value.isInitialized && _evSupported) _evRow(),
                    if (value.isInitialized) _filterChips(),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Auto-captions'),
                      subtitle: const Text(
                          'On-device STT + karaoke subtitles (alpha)'),
                      value: _captions,
                      onChanged: (v) => setState(() => _captions = v),
                    ),
                    if (_captionStatus != null)
                      Text(_captionStatus!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.lightBlue)),
                    if (_captionedFile != null)
                      Text('Captioned: $_captionedFile',
                          textAlign: TextAlign.center),
                    if (value.isInitialized) _debugPanel(),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
