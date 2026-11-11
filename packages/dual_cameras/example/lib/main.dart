import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:dual_cameras/dual_cameras.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:permission_handler/permission_handler.dart';

import 'captions/caption_models.dart';
import 'captions/caption_jobs.dart';
import 'captions/caption_job_runner.dart';
import 'captions/caption_pipeline.dart';
import 'captions/model_manager.dart';
import 'captions/transcriber.dart';
import 'ui/story_camera.dart';

void main() => runApp(const DemoApp());

@pragma('vm:entry-point')
Future<void> captionJobMain() => runCaptionJob();

class DemoApp extends StatelessWidget {
  const DemoApp(
      {super.key,
      this.modelManager,
      this.captionJobs,
      this.backgroundCaptions});

  final ModelManager? modelManager;
  final CaptionJobs? captionJobs;
  final bool? backgroundCaptions;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'StoryCam',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFFFF526D), brightness: Brightness.dark),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(48, 48),
            foregroundColor: Colors.white,
          ),
        ),
      ),
      home: DemoScreen(
          modelManager: modelManager,
          captionJobs: captionJobs,
          backgroundCaptions: backgroundCaptions),
    );
  }
}

class DemoScreen extends StatefulWidget {
  const DemoScreen(
      {super.key,
      this.modelManager,
      this.captionJobs,
      this.backgroundCaptions});

  final ModelManager? modelManager;
  final CaptionJobs? captionJobs;
  final bool? backgroundCaptions;

  @override
  State<DemoScreen> createState() => _DemoScreenState();
}

class _DemoScreenState extends State<DemoScreen> with WidgetsBindingObserver {
  final DualCameraController _controller = DualCameraController();
  CameraCapabilities? _caps;
  String _status = 'Checking camera support…';
  String? _error;
  bool _busy = false;
  Future<void>? _cameraOperation;
  late final bool _usesBackgroundJobs = widget.backgroundCaptions ??
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);
  late final CaptionJobs _jobs = widget.captionJobs ?? CaptionJobs();
  List<CaptionJob> _backgroundJobs = [];
  Timer? _jobPoll;
  bool _refreshingJobs = false;
  bool _notificationsEnabled = true;
  final Set<String> _pendingJobActions = {};
  String? _jobError;
  String? _jobLoadError;
  String? get _visibleJobError => _jobError ?? _jobLoadError;

  Future<void> _captionQueue = Future<void>.value();
  int _captionJobs = 0;
  String? _captionSourceFile;
  double? _pendingEv;
  final Map<bool, double> _pendingAspects = {};
  final ValueNotifier<int> _revision = ValueNotifier(0);

  void _update(VoidCallback change) {
    if (!mounted) return;
    setState(change);
    _revision.value++;
  }

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
  late final ModelManager _modelManager = widget.modelManager ?? ModelManager();
  Future<WhisperModelFiles>? _modelFuture;
  bool _modelReady = false;
  double? _modelProgress;
  String? _modelError;
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
    if (_usesBackgroundJobs) {
      WidgetsBinding.instance.addObserver(this);
      _startJobPolling();
    } else {
      _prepareModel();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_usesBackgroundJobs) return;
    if (state == AppLifecycleState.resumed) {
      _startJobPolling();
    } else {
      _jobPoll?.cancel();
      _jobPoll = null;
    }
  }

  void _startJobPolling() {
    _jobPoll?.cancel();
    _refreshJobs();
    _jobPoll =
        Timer.periodic(const Duration(seconds: 1), (_) => _refreshJobs());
  }

  Future<void> _refreshJobs() async {
    if (_refreshingJobs || !mounted) return;
    _refreshingJobs = true;
    try {
      final jobs = await _jobs.list();
      final enabled = await _jobs.notificationsEnabled();
      _update(() {
        _backgroundJobs = jobs;
        _notificationsEnabled = enabled;
        _jobLoadError = null;
      });
    } catch (_) {
      _update(() => _jobLoadError =
          'Could not load caption jobs. Reopen Captions to retry.');
    } finally {
      _refreshingJobs = false;
    }
  }

  Future<void> _toggleCaptions(bool value) async {
    _update(() => _captions = value);
    if (value && _usesBackgroundJobs) {
      try {
        await Permission.notification.request();
      } catch (_) {
        _update(() => _jobError =
            'Could not request notifications. Enable them in Android settings.');
      }
      await _refreshJobs();
    }
  }

  Future<void> _jobAction(String id, Future<void> Function() action) async {
    if (!_pendingJobActions.add(id)) return;
    _update(() {});
    try {
      await action();
      _update(() => _jobError = null);
      await _refreshJobs();
    } catch (_) {
      _update(() =>
          _jobError = 'Could not complete that action. Please try again.');
    } finally {
      _pendingJobActions.remove(id);
      _update(() {});
    }
  }

  Widget _backgroundPreparation() {
    final active = _backgroundJobs.where((job) => job.active).toList();
    final latest = active.isNotEmpty
        ? active.first
        : (_backgroundJobs.isEmpty ? null : _backgroundJobs.first);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(
              child: TextButton(
            style: TextButton.styleFrom(
                alignment: Alignment.centerLeft, padding: EdgeInsets.zero),
            onPressed: _captionsSheet,
            child: Text(latest?.label ?? 'Captions run in the background',
                maxLines: 2, overflow: TextOverflow.ellipsis),
          )),
          if (latest != null && latest.canStop)
            TextButton(
                onPressed: _pendingJobActions.contains(latest.id)
                    ? null
                    : () =>
                        _jobAction(latest.id, () => _jobs.cancel(latest.id)),
                child: const Text('Stop')),
        ]),
        if (active.isNotEmpty)
          LinearProgressIndicator(
              value: latest!.progress / 100,
              minHeight: 3,
              semanticsLabel: latest.label,
              semanticsValue: '${latest.progress}%'),
        if (!_notificationsEnabled && active.isNotEmpty)
          const Text('Notifications are off. Track progress and Stop here.',
              style: TextStyle(fontSize: 12)),
      ]),
    );
  }

  List<Widget> _backgroundJobCards() => [
        const Text('Android keeps captions running when you leave StoryCam. '
            'Notifications show progress and Stop, then Open and Share when ready. '
            'The speech model downloads on first use (about 100 MB). Originals are kept.'),
        if (!_notificationsEnabled) ...[
          const SizedBox(height: 12),
          const Text(
              'Notifications are off. Jobs still run, but Android hides their notifications. '
              'You can track progress, Stop, Open and Share here.'),
          TextButton(
              onPressed: openAppSettings,
              child: const Text('Enable notifications in settings')),
        ],
        if (_visibleJobError != null) Text(_visibleJobError!),
        if (_backgroundJobs.isEmpty)
          const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Text(
                  'No caption jobs yet. Turn on auto-captions and record a video.')),
        for (final job in _backgroundJobs)
          Card(
              child: Padding(
            padding: const EdgeInsets.all(12),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Semantics(liveRegion: job.active, child: Text(job.label)),
              if (job.active) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(
                    value: job.progress / 100,
                    semanticsValue: '${job.progress}%'),
              ],
              if (job.error != null && job.state == 'failed') Text(job.error!),
              Wrap(spacing: 8, children: [
                if (job.canStop)
                  TextButton(
                      onPressed: _pendingJobActions.contains(job.id)
                          ? null
                          : () =>
                              _jobAction(job.id, () => _jobs.cancel(job.id)),
                      child: const Text('Stop')),
                if (job.ready) ...[
                  TextButton(
                      onPressed: () =>
                          _jobAction(job.id, () => _jobs.open(job.id)),
                      child: const Text('Open')),
                  TextButton(
                      onPressed: () =>
                          _jobAction(job.id, () => _jobs.share(job.id)),
                      child: const Text('Share')),
                ],
                if (job.state == 'failed' || job.state == 'cancelled')
                  TextButton(
                      onPressed: _pendingJobActions.contains(job.id)
                          ? null
                          : () => _jobAction(job.id, () async {
                                await _jobs.retry(job.id);
                              }),
                      child: const Text('Retry')),
              ]),
            ]),
          )),
      ];

  // Startup and post-recording captions share one future: never download the
  // same model twice. This task is independent of the camera action lock.
  Future<WhisperModelFiles> _ensureModel() => _modelFuture ??= _loadModel();

  void _prepareModel() {
    _ensureModel()
        .then<void>((_) {}, onError: (Object error, StackTrace stack) {});
  }

  Future<WhisperModelFiles> _loadModel() async {
    _update(() {
      _modelError = null;
      _modelProgress = null;
    });
    try {
      final model = await _modelManager.ensureModel(onProgress: (progress) {
        final value = progress.clamp(0.0, 1.0).toDouble();
        // Announce and repaint at whole percentages, not every network chunk.
        if (_modelProgress == null ||
            (value * 100).floor() != (_modelProgress! * 100).floor()) {
          _update(() => _modelProgress = value);
        }
      });
      _update(() {
        _modelReady = true;
        _modelProgress = 1;
      });
      return model;
    } catch (e) {
      _modelFuture =
          null; // Allow an explicit retry or a later caption attempt.
      _update(() => _modelError = '$e');
      rethrow;
    }
  }

  Widget _modelPreparation() {
    if (_usesBackgroundJobs) return _backgroundPreparation();
    final label = _modelReady
        ? 'Captions ready · on device'
        : _modelError != null
            ? 'Caption model download failed'
            : 'Preparing captions${_modelProgress == null ? '' : ' · ${(_modelProgress! * 100).floor()}%'}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(
              child: Semantics(
            liveRegion: true,
            child: Text('$label${_modelReady ? '' : '\nFirst use: ~100 MB'}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Color(0xFFCAC6D5))),
          )),
          if (_modelError != null)
            TextButton(
              onPressed: _prepareModel,
              child: const Text('Retry'),
            ),
        ]),
        const SizedBox(height: 6),
        LinearProgressIndicator(
          value: _modelReady
              ? 1
              : _modelError != null
                  ? (_modelProgress ?? 0)
                  : _modelProgress,
          minHeight: 3,
          color: _modelError != null ? Colors.orange : null,
          semanticsLabel: label,
          semanticsValue: _modelProgress == null
              ? null
              : '${(_modelProgress! * 100).floor()}%',
        ),
      ]),
    );
  }

  Future<void> _bootstrap() async {
    try {
      final caps = await DualCameraController.probeSupport();
      _update(() {
        _caps = caps;
        _status = caps.isSupported
            ? 'Two perspectives. One story.'
            : 'Dual camera is unavailable on this device (${caps.reason?.name ?? 'unknown'}).';
      });
    } catch (e) {
      _update(() {
        _error = '$e';
        _status = 'Could not check camera support. Retry in settings.';
      });
    }
  }

  Future<T> _cameraCommand<T>(Future<T> Function() action) {
    final future = action();
    // Disposal can await this completion without inheriting the command's error;
    // the original future is still awaited and reported by its caller.
    _cameraOperation =
        future.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    return future;
  }

  Future<void> _start() => _guard(() async {
        final granted =
            await [Permission.camera, Permission.microphone].request();
        if (!mounted) return;
        if (granted.values.any((s) => !s.isGranted)) {
          _update(() => _status =
              'Camera and microphone access required. Allow access in device settings, then try again.');
          return;
        }
        await _cameraCommand(() => _controller.initialize(layout: _layout()));
        if (!mounted) return;
        final range =
            await _cameraCommand(_controller.getExposureCompensationRange);
        _update(() {
          _status = 'Ready to tell your story';
          _evSupported = range.minEv < range.maxEv && range.stepEv > 0;
          if (_evSupported) {
            _evMin = range.minEv;
            _evMax = range.maxEv;
            _evStep = range.stepEv;
            _ev = 0.0;
          }
        });
      }, 'Open camera');

  void _setEv(double value) {
    _update(() => _ev = value);
    _pendingEv = value;
    _flushTuning();
  }

  void _queueAspect(bool front, double value) {
    _update(() => front ? _frontAspect = value : _backAspect = value);
    _pendingAspects[front] = value;
    _flushTuning();
  }

  // Live slider updates are serialized with capture commands and coalesced:
  // while one value is in flight, only the latest requested value is retained.
  void _flushTuning() {
    if (_busy || !mounted) return;
    final ev = _pendingEv;
    if (ev != null) {
      _pendingEv = null;
      _guard(
          () => _cameraCommand(() => _controller.setExposureCompensation(ev)),
          'Exposure');
    } else if (_pendingAspects.isNotEmpty) {
      final front = _pendingAspects.keys.first;
      final value = _pendingAspects.remove(front)!;
      _guard(() => _setAspect(front, value), 'Aspect');
    }
  }

  String _evLabel(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)} EV';

  Future<void> _setFilter(VideoFilter f) => _guard(() async {
        await _cameraCommand(() => _controller.setFilter(f));
        _update(() => _filter = f);
      }, 'Filter updated');

  Widget _filterChips() {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      children: [
        ChoiceChip(
          label: const Text('Original'),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Exposure ${_evLabel(_ev)}'),
        Slider(
          semanticFormatterCallback: _evLabel,
          min: _evMin,
          max: _evMax,
          divisions: divisions,
          label: _evLabel(_ev),
          value: _ev.clamp(_evMin, _evMax).toDouble(),
          onChanged: _setEv,
        ),
      ],
    );
  }

  Future<void> _guard(Future<void> Function() action, String label) {
    if (_busy || !mounted) return Future<void>.value();
    _update(() {
      _busy = true;
      _error = null;
    });
    return _perform(action, label);
  }

  Future<void> _perform(Future<void> Function() action, String label) async {
    try {
      await action();
    } catch (e) {
      _update(() {
        _status = '$label failed. See settings for details.';
        _error = '$e';
      });
    } finally {
      _update(() => _busy = false);
      _flushTuning();
    }
  }

  /// Stop recording, save to gallery, then optionally run the auto-captions
  /// pipeline (extract audio -> on-device STT -> karaoke burn-in). The
  /// original uncaptioned mp4 is always kept; the captioned one is a second
  /// file. Any captions failure falls back to the plain video.
  Future<void> _stop() async {
    final captions = _captions;
    late final String file;
    try {
      file = await _cameraCommand(_controller.stopRecording);
      _lastFile = file;
      await Gal.putVideo(file);
      if (!mounted && !_usesBackgroundJobs) return;
      _update(() {
        _status = 'Video saved to gallery';
      });
    } catch (e) {
      _update(() {
        _status = 'Could not save video. See settings for details.';
        _error = '$e';
      });
      return;
    }
    if (captions) {
      if (_usesBackgroundJobs) {
        try {
          await _jobs.enqueue(file);
          _update(() => _jobError = null);
          await _refreshJobs();
        } catch (_) {
          _update(() => _jobError =
              'Could not queue captions. Your original video is saved in the gallery.');
        }
      } else if (mounted) {
        _queueCaptions(file);
      }
    }
  }

  void _queueCaptions(String mp4) {
    _update(() {
      _captionJobs++;
      if (_captionJobs == 1) _captionStatus = 'Preparing captions…';
    });
    _captionQueue = _captionQueue.then((_) async {
      if (!mounted) return;
      await _captionVideo(mp4);
      _update(() => _captionJobs--);
    });
  }

  Future<void> _captionVideo(String mp4) async {
    try {
      _update(() => _captionStatus = 'Extracting audio…');
      final wav = await _captionPipeline.extractAudio(mp4);
      if (!mounted) return;

      _update(() => _captionStatus = 'Preparing speech model…');
      final model = await _ensureModel();

      if (!mounted) return;
      _update(() => _captionStatus = 'Transcribing… (on-device)');
      // Let the progress state paint before the blocking decode.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (!mounted) return;
      final result = await _transcriber.transcribe(
        wavPath: wav,
        model: model,
      );
      final words = result.words;
      if (!mounted) return;
      if (words.isEmpty) {
        _update(
            () => _captionStatus = 'No speech detected — keeping plain video');
        return;
      }

      _update(
          () => _captionStatus = 'Burning captions… (${words.length} words)');
      final captioned = await _captionPipeline.burnCaptions(
        mp4Path: mp4,
        words: words,
      );
      if (!mounted) return;
      await Gal.putVideo(captioned);
      if (!mounted) return;
      _update(() {
        _captionedFile = captioned;
        _captionSourceFile = mp4;
        _captionStatus = 'Captions done — ${words.length} words' +
            (result.detectedLanguage.isEmpty
                ? ''
                : ' (${result.detectedLanguage})');
      });
    } catch (e) {
      if (!mounted) return;
      _update(() {
        _captionStatus =
            'Captions failed — plain video kept. See settings for details.';
        _error = '$e';
      });
    }
  }

  int _norm(int deg) => ((deg % 360) + 360) % 360;

  Future<void> _setRotation(bool front, int offset) async {
    final norm = _norm(offset);
    _update(() => front ? _frontOffset = norm : _backOffset = norm);
    await _cameraCommand(() => _debug.invokeMethod<void>(
        'setRotationOffset', {'front': front, 'offset': norm}));
  }

  Future<void> _setAspect(bool front, double aspect) async {
    await _cameraCommand(() => _debug.invokeMethod<void>(
        'setAspectOverride', {'front': front, 'aspect': aspect}));
  }

  Future<void> _setMirror(bool on) async {
    _update(() => _mirrorFront = on);
    await _cameraCommand(
        () => _debug.invokeMethod<void>('setMirrorFront', {'on': on}));
  }

  @override
  void dispose() {
    _jobPoll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    // Native camera commands cannot be cancelled. Wait for that command only;
    // gallery writes, model downloads and queued captions must not retain the
    // camera session after the screen is removed.
    final pending = _cameraOperation;
    if (pending == null) {
      _controller.dispose();
    } else {
      pending.whenComplete(_controller.dispose);
    }
    _revision.dispose();
    super.dispose();
  }

  Widget _rotationRow(String label, bool front, int offset) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      children: [
        Text(label),
        IconButton(
          tooltip: 'Rotate $label left',
          icon: const Icon(Icons.rotate_left),
          onPressed: () =>
              _guard(() => _setRotation(front, offset - 90), 'Rotation'),
        ),
        Text('$offset°'),
        IconButton(
          tooltip: 'Rotate $label right',
          icon: const Icon(Icons.rotate_right),
          onPressed: () =>
              _guard(() => _setRotation(front, offset + 90), 'Rotation'),
        ),
        for (final d in const [0, 90, 180, 270])
          ChoiceChip(
            label: Text('$d°'),
            selected: offset == d,
            onSelected: (_) => _guard(() => _setRotation(front, d), 'Rotation'),
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
            onChanged: (v) => _queueAspect(front, v),
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
            onChanged: (v) => _guard(() => _setMirror(v), 'Mirror'),
          ),
          _aspectRow('Front aspect', true, _frontAspect),
          _aspectRow('Back aspect', false, _backAspect),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => _guard(() async {
                _pendingAspects.clear();
                _update(() {
                  _frontAspect = 0;
                  _backAspect = 0;
                });
                await _setAspect(true, 0);
                if (!mounted) return;
                await _setAspect(false, 0);
              }, 'Reset aspect'),
              child: const Text('Reset aspect → auto'),
            ),
          ),
        ],
      ),
    );
  }

  void _sheet(String title, List<Widget> Function(DualCameraValue) contents) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF19181F),
      builder: (sheetContext) => SafeArea(
        top: false,
        child: FractionallySizedBox(
          heightFactor: .85,
          child: AnimatedBuilder(
            animation: Listenable.merge([_controller, _revision]),
            builder: (context, _) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
                  child: Row(children: [
                    Expanded(
                        child: Text(title,
                            style: Theme.of(context).textTheme.titleLarge)),
                    IconButton(
                        tooltip: 'Close $title',
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close)),
                  ]),
                ),
                Expanded(
                    child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  children: contents(_controller.value),
                )),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _filtersSheet() => _sheet(
      'Filters',
      (value) => [
            const Text('Your look, live in the preview and saved video.'),
            const SizedBox(height: 16),
            IgnorePointer(
                ignoring: _busy || !value.isInitialized, child: _filterChips()),
            if (_busy) const LinearProgressIndicator(),
          ]);

  void _captionsSheet() => _sheet(
      'Captions',
      (value) => [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto-captions'),
              subtitle: const Text(
                  'On-device speech recognition and karaoke subtitles (alpha).'),
              value: _captions,
              onChanged: _busy || value.isRecording ? null : _toggleCaptions,
            ),
            if (_usesBackgroundJobs) ..._backgroundJobCards(),
            if (!_usesBackgroundJobs)
              const Text(
                  'The speech model downloads at startup (about 100 MB on first use). Captions run on device once ready. Your original video is always kept.'),
            if (_captionStatus != null) ...[
              const SizedBox(height: 16),
              Semantics(liveRegion: true, child: Text(_captionStatus!)),
            ],
            if (_busy || _captionJobs > 0) const LinearProgressIndicator(),
            if (_captionJobs > 1) Text('Caption jobs queued: $_captionJobs'),
          ]);

  void _settingsSheet() => _sheet(
      'Camera settings',
      (value) => [
            if (!value.isInitialized)
              TextButton(
                  onPressed:
                      _busy ? null : () => _guard(_bootstrap, 'Check support'),
                  child: const Text('Check camera support again')),
            if (value.isInitialized) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Circular selfie'),
                subtitle:
                    const Text('Use a circle instead of a rounded square.'),
                value: _circle,
                onChanged: _busy
                    ? null
                    : (v) => _guard(() async {
                          final previous = _circle;
                          _update(() => _circle = v);
                          try {
                            await _cameraCommand(
                                () => _controller.setLayout(_layout()));
                          } catch (_) {
                            _update(() => _circle = previous);
                            rethrow;
                          }
                        }, 'Selfie layout'),
              ),
              if (_evSupported)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Exposure'),
                  subtitle: Text(_evLabel(_ev)),
                  children: [IgnorePointer(ignoring: _busy, child: _evRow())],
                ),
            ],
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Session details'),
              children: [
                Text(_status),
                if (_modelError != null) SelectableText(_modelError!),
                if (_error != null) SelectableText(_error!),
                if (value.errorMessage != null)
                  SelectableText(value.errorMessage!),
                if (_lastFile != null) SelectableText('Original: $_lastFile'),
                if (_captionedFile != null) ...[
                  SelectableText('Caption source: $_captionSourceFile'),
                  SelectableText('Captioned: $_captionedFile'),
                ],
                if (_captionStatus != null) Text(_captionStatus!),
                if (value.isInitialized)
                  FittedBox(
                      fit: BoxFit.scaleDown,
                      child: DualCameraStatsOverlay(_controller)),
              ],
            ),
            if (value.isInitialized)
              IgnorePointer(ignoring: _busy, child: _debugPanel()),
          ]);

  Future<void> _record() => _guard(() async {
        if (_controller.value.isRecording) {
          await _stop();
        } else {
          await _cameraCommand(_controller.startRecording);
          _update(() {
            _status = 'Recording your story';
          });
        }
      }, 'Recording');

  Future<void> _photo() => _guard(() async {
        final file = await _cameraCommand(_controller.takePhoto);
        _lastFile = file;
        await Gal.putImage(file);
        _update(() => _status = 'Photo saved to gallery');
      }, 'Photo');

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DualCameraValue>(
      valueListenable: _controller,
      builder: (context, value, _) {
        final ready = value.isInitialized && !_busy;
        final status = [
          if (value.errorMessage != null)
            'Camera error. See settings for details.'
          else
            _status,
          if (value.thermal != ThermalLevel.nominal)
            'Thermal: ${value.thermal.name}',
          if (_captionStatus != null) _captionStatus!,
          if (_visibleJobError != null) _visibleJobError!,
        ].join('\n');
        return StoryCamera(
          preparation: _modelPreparation(),
          preview: DualCameraPreview(
            _controller,
            placeholder: LayoutBuilder(builder: (context, constraints) {
              return Center(
                  child: SingleChildScrollView(
                primary: false,
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.camera_outlined,
                      size: 44, color: Colors.white54),
                  if (constraints.maxHeight > 240) ...[
                    const SizedBox(height: 12),
                    const Text('Every story has two sides',
                        textAlign: TextAlign.center),
                  ],
                ]),
              ));
            }),
          ),
          initialized: value.isInitialized,
          recording: value.isRecording,
          busy: _busy,
          captions: _captions,
          filterName: _filter == VideoFilter.none ? 'Original' : 'Moody',
          status: status,
          onCapture: _busy
              ? null
              : value.isInitialized
                  ? _record
                  : (_caps?.isSupported ?? false)
                      ? _start
                      : null,
          onPhoto: ready ? _photo : null,
          onSwap: ready
              ? () => _guard(
                  () => _cameraCommand(_controller.swapPrimary), 'Swap cameras')
              : null,
          onFilters: ready ? _filtersSheet : null,
          onCaptions: _captionsSheet,
          onSettings: _settingsSheet,
        );
      },
    );
  }
}
