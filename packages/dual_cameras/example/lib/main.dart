import 'dart:async';
import 'dart:io';

import 'package:dual_cameras/dual_cameras.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';

import 'captions/caption_job_notifier.dart';
import 'captions/caption_jobs.dart';
import 'captions/caption_job_runner.dart';
import 'captions/caption_language.dart';
import 'captions/caption_language_store.dart';
import 'captions/caption_models.dart';
import 'captions/caption_pipeline.dart';
import 'captions/model_download_notifier.dart';
import 'captions/model_manager.dart';
import 'captions/notification_center.dart';
import 'captions/transcriber.dart';
import 'crash_reporting.dart';
import 'map/camera_settings.dart';
import 'map/map_location.dart';
import 'ui/bottom_menu.dart';
import 'ui/filter_slider.dart';
import 'ui/lens_pills.dart';
import 'ui/map_circle.dart';
import 'ui/story_camera.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // No-op when built without --dart-define SENTRY_DSN: Sentry is never
  // initialized and the app boots exactly as before.
  await CrashReporting.init();
  runApp(const DemoApp());
}

@pragma('vm:entry-point')
Future<void> captionJobMain() => runCaptionJob();

class DemoApp extends StatelessWidget {
  const DemoApp(
      {super.key,
      this.modelManager,
      this.captionJobs,
      this.backgroundCaptions,
      this.captionLanguageStore,
      this.modelDownloadNotifier,
      this.captionJobNotifier,
      this.cameraCommandTimeout,
      this.cameraSettingsStore,
      this.mapLocationService});

  final ModelManager? modelManager;
  final CaptionJobs? captionJobs;
  final bool? backgroundCaptions;
  final CaptionLanguageStore? captionLanguageStore;
  final ModelDownloadNotifier? modelDownloadNotifier;
  final CaptionJobNotifier? captionJobNotifier;
  final Duration? cameraCommandTimeout;
  final CameraSettingsStore? cameraSettingsStore;
  final MapLocationService? mapLocationService;

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
          backgroundCaptions: backgroundCaptions,
          captionLanguageStore: captionLanguageStore,
          modelDownloadNotifier: modelDownloadNotifier,
          captionJobNotifier: captionJobNotifier,
          cameraCommandTimeout: cameraCommandTimeout,
          cameraSettingsStore: cameraSettingsStore,
          mapLocationService: mapLocationService),
    );
  }
}

class DemoScreen extends StatefulWidget {
  const DemoScreen(
      {super.key,
      this.modelManager,
      this.captionJobs,
      this.backgroundCaptions,
      this.captionLanguageStore,
      this.modelDownloadNotifier,
      this.captionJobNotifier,
      this.cameraCommandTimeout,
      this.cameraSettingsStore,
      this.mapLocationService});

  final ModelManager? modelManager;
  final CaptionJobs? captionJobs;
  final bool? backgroundCaptions;
  final CaptionLanguageStore? captionLanguageStore;
  final ModelDownloadNotifier? modelDownloadNotifier;
  final CaptionJobNotifier? captionJobNotifier;
  final Duration? cameraCommandTimeout;
  final CameraSettingsStore? cameraSettingsStore;
  final MapLocationService? mapLocationService;

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
  // A shutter tap that lands while a camera command is in flight is queued,
  // not dropped (v0.5.2: a tap during a transient busy window used to vanish
  // with no trace — the v0.5.1 phone defect. The button stays enabled while
  // busy; the tap shows 'Please wait…' at once and fires when the lock frees).
  // Fired only if the screen is still up, the camera is initialized, and
  // nothing is recording by then; otherwise it is dropped.
  bool _pendingRecord = false;
  // Watchdog (v0.5.2): a camera command that never returns used to leave
  // `_busy` true forever — a dead screen until the app was killed. Every
  // platform call is now bounded; on timeout the error surfaces like any
  // other command failure and `_busy` clears. The underlying native call is
  // not cancelled (platform calls cannot be), so a very late completion can
  // still flip the controller state afterwards.
  static const _cameraCommandTimeout = Duration(seconds: 20);
  Duration get _cameraTimeout =>
      widget.cameraCommandTimeout ?? _cameraCommandTimeout;
  // Background caption jobs have no native side yet (no WorkManager worker
  // or `caption_jobs` channel handler exists in the repo or the shipped APK),
  // so on a real phone `enqueue` always fails with MissingPluginException
  // and captions never run. Run captions in the foreground until the native
  // worker lands; the background-job code stays in place (still tested via
  // the injected `backgroundCaptions` flag) so the default can flip back
  // when the worker exists. See NOTES.md, "Diagnosis — v0.5.0 phone defect".
  late final bool _usesBackgroundJobs = widget.backgroundCaptions ?? false;
  late final CaptionJobs _jobs = widget.captionJobs ?? CaptionJobs();
  List<CaptionJob> _backgroundJobs = [];
  Timer? _jobPoll;
  // Resume guard (issue #13): `resumed` also fires when a system dialog
  // closes, with no backgrounding in between — re-initing there would tear
  // down a healthy session and kill a live recording. Only a real
  // backgrounding (`paused`/`hidden`) arms the resume re-init.
  bool _wasBackgrounded = false;
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
  // Last successfully saved VIDEO (issue #14) — the file Share attaches.
  // Set only in _stop() after Gal.putVideo succeeds; _photo() also writes
  // _lastFile, so _lastFile means "last capture", not "last video". Never
  // the captioned file: Share always attaches the original uncaptioned
  // video. In-memory only, gone on app restart, same as _lastFile.
  String? _lastVideo;
  bool _circle = true; // Telegram-style: circular selfie inset by default.

  // Exposure (EV) slider — the Sony-style dial, applied live to both cameras.
  double _ev = 0.0;
  double _evMin = -2.0;
  double _evMax = 2.0;
  double _evStep = 1 / 3;
  bool _evSupported = false;

  // Camera-screen settings (issue #20): map & compass, front/rear camera,
  // filter, lens picks. File-based, loaded in initState; every change is
  // saved through [_updateSettings]. The filter lives here now (was the
  // in-memory `_filter`); the mirror flag lives here too (was `_mirrorFront`).
  late final CameraSettingsStore _settingsStore =
      widget.cameraSettingsStore ?? CameraSettingsStore();
  CameraSettings _settings = const CameraSettings();

  // Map & compass (issue #20): position + heading streams, started once
  // the camera is open and the location permission is granted.
  MapLocationService? _mapService;
  MapLocationService get _location =>
      _mapService ??= widget.mapLocationService ?? MapLocationService();
  bool get _ownsMapService => widget.mapLocationService == null;
  LatLng? _position;
  double _heading = 0;
  bool _locationGranted = false;
  StreamSubscription<LatLng>? _positionSub;
  StreamSubscription<double>? _headingSub;

  // Lenses (issue #20): probed from the camera API after init, per facing.
  // Empty until the probe returns — the pills stay hidden meanwhile.
  List<LensOption> _lensesFront = [];
  List<LensOption> _lensesRear = [];

  /// Which camera is full-frame (primary). Drives the lens pills, the
  /// bottom-menu Front/Rear state, and the layout primary (so a resume
  /// re-init keeps it — see DualCameraController.swapPrimary).
  bool _primaryFront = false;

  /// 4K offer: true only when the device probe passes (see _start).
  bool _supports4k = false;

  // Auto-captions (v0.2.0): on-device STT + karaoke burn-in, OFF by default.
  // Caption processing state lives in a system notification (v0.5.3), never
  // as in-app text: there is no _captionStatus anymore.
  bool _captions = false;
  String? _captionedFile;
  final CaptionPipeline _captionPipeline = CaptionPipeline();
  late final ModelManager _modelManager = widget.modelManager ?? ModelManager();
  Future<WhisperModelFiles>? _modelFuture;
  String? _modelError;
  final Transcriber _transcriber = Transcriber();
  // Generation counter for foreground caption jobs (v0.5.3): every stop
  // request bumps it; a job whose captured generation is stale aborts at
  // the next stage boundary, and jobs queued behind it are dropped. A new
  // recording captures the current generation, so a stop never cancels a
  // later clip.
  int _captionGeneration = 0;
  // One notification center shared by both notifiers (v0.5.3): a single
  // plugin instance and a single `initialize` call, so the two Stop actions
  // cannot steal each other's taps. Lazily created so tests that inject
  // fakes never touch the plugin.
  NotificationCenter? _notificationCenter;
  NotificationCenter get _center =>
      _notificationCenter ??= NotificationCenter();
  // Model-download progress lives in a system notification (v0.5.2), never
  // as a banner on the camera screen. Lazily created so tests that inject a
  // fake never touch the plugin.
  ModelDownloadNotifier? _modelDownloadNotifier;
  ModelDownloadNotifier get _notifier {
    final notifier = _modelDownloadNotifier ??=
        widget.modelDownloadNotifier ??
            SystemModelDownloadNotifier(center: _center);
    notifier.onStop = () => _modelManager.cancel();
    return notifier;
  }

  // Caption-processing progress lives in a system notification (v0.5.3),
  // never as in-app status text. Same lazy pattern as the download
  // notifier.
  CaptionJobNotifier? _captionJobNotifier;
  CaptionJobNotifier get _captionNotifier {
    final notifier = _captionJobNotifier ??= widget.captionJobNotifier ??
        SystemCaptionJobNotifier(center: _center);
    notifier.onStop = _stopCaptionJob;
    return notifier;
  }

  // Caption language (v0.5.1): Auto by default; a picked language is
  // forced on the recognizer and persisted across sessions. Auto can
  // misdetect very short utterances (v0.5.0 phone defect: «Привет» came
  // back as English "THERE YET."), so the user can pin the language.
  late final CaptionLanguageStore _languageStore =
      widget.captionLanguageStore ?? CaptionLanguageStore();
  CaptionLanguage _captionLanguage = CaptionLanguage.auto;

  // Live geometry tuning (debug channel) — to dial in the front/back
  // orientation and fix any stretch directly on the device.
  static const MethodChannel _debug = MethodChannel('dual_cameras/debug');
  // Share sheet (issue #14): `shareVideo {path}` fires ACTION_SEND via
  // the native ShareChannel + FileProvider. Separate channel from the
  // dead `caption_jobs` share path — that channel has no native handler.
  static const MethodChannel _shareChannel =
      MethodChannel('dual_cameras_example/share');
  int _frontOffset = 90; // matches FRONT_ROTATION_OFFSET default
  int _backOffset = -90; // matches BACK_ROTATION_OFFSET default
  double _frontAspect = 0; // 0 = auto (use camera-reported)
  double _backAspect = 0;

  LayoutConfig _layout() => DualLayout.pictureInPicture(
        primary: _primaryFront ? CameraLens.front : CameraLens.back,
        insetScale: 0.32,
        margin: 16,
        circleInset: _circle,
      );

  @override
  void initState() {
    super.initState();
    _bootstrap();
    // A caption notification left over from a previous run (the app died
    // mid-captioning) must not linger: no job exists for it anymore.
    unawaited(_captionNotifier.clear());
    _languageStore.load().then((stored) {
      if (mounted) _update(() => _captionLanguage = stored);
    });
    _settingsStore.load().then((stored) {
      if (mounted) _update(() => _settings = stored);
    });
    if (_usesBackgroundJobs) {
      _startJobPolling();
    } else {
      _prepareModel();
    }
    // The lifecycle observer is registered ALWAYS (issue #13): the resume
    // re-init below must run in the default foreground-captions build too —
    // previously it was only registered with background caption jobs, so in
    // Den's build it was not even registered.
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // Real backgrounding: arm the resume re-init and stop job polling.
        _wasBackgrounded = true;
        _jobPoll?.cancel();
        _jobPoll = null;
        break;
      case AppLifecycleState.resumed:
        if (_usesBackgroundJobs) {
          _startJobPolling();
        }
        if (_wasBackgrounded) {
          _wasBackgrounded = false;
          unawaited(_resumeCamera());
        }
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        // No backgrounding: no resume re-init. Job polling still stops,
        // as before — it restarts on `resumed`.
        _jobPoll?.cancel();
        _jobPoll = null;
        break;
    }
  }

  /// Bring the camera session back after a real backgrounding (issue #13).
  /// The OS tears the native session down on background; on resume the
  /// preview would otherwise stay frozen on the stale texture forever.
  /// Runs through the existing `_guard` / `_cameraCommand` 20s watchdog.
  /// No-op when the camera was never opened.
  Future<void> _resumeCamera() => _guard(() async {
        if (!_controller.value.isInitialized) return;
        final wasRecording = _controller.value.isRecording;
        final restored =
            await _cameraCommand(() => _controller.reinitialize());
        if (!mounted) return;
        if (!restored) {
          _update(() {
            _status = 'Camera could not resume. Tap Open camera to retry.';
            _error = _controller.value.errorMessage;
          });
          return;
        }
        // The torn-down session took every tuning value with it.
        await _reapplyTuning();
        if (!mounted) return;
        if (wasRecording) {
          _update(() => _status =
              'Camera resumed — the recording was interrupted when the app was backgrounded.');
        }
      }, 'Resume camera');

  /// Re-apply the EV / filter / debug tuning after a resume re-init: the
  /// native session (and with it every tuning value) was torn down on
  /// background. Raw channel calls, not the slider setters — no state churn.
  Future<void> _reapplyTuning() async {
    if (_evSupported) {
      await _cameraCommand(() => _controller.setExposureCompensation(_ev));
    }
    await _cameraCommand(() => _controller.setFilter(_settings.filter));
    await _cameraCommand(() => _debug.invokeMethod<void>(
        'setRotationOffset', {'front': true, 'offset': _frontOffset}));
    await _cameraCommand(() => _debug.invokeMethod<void>(
        'setRotationOffset', {'front': false, 'offset': _backOffset}));
    await _cameraCommand(() => _debug.invokeMethod<void>(
        'setAspectOverride', {'front': true, 'aspect': _frontAspect}));
    await _cameraCommand(() => _debug.invokeMethod<void>(
        'setAspectOverride', {'front': false, 'aspect': _backAspect}));
    await _cameraCommand(() => _debug.invokeMethod<void>(
        'setMirrorFront', {'on': _settings.mirrorFront}));
    // The stored lens, best effort: a lens the API no longer offers must
    // not break the resume — the pills simply show the main lens.
    try {
      await _applyStoredLens();
    } catch (_) {
      // Best effort only.
    }
  }

  /// Apply the stored lens for the primary camera when the API still
  /// offers it. No-op when nothing was stored or the ratio is not offered.
  Future<void> _applyStoredLens() async {
    final stored = _primaryFront ? _settings.frontLens : _settings.rearLens;
    if (stored == null) return;
    final offered = _primaryFront ? _lensesFront : _lensesRear;
    if (!offered.any((lens) => lens.ratio == stored)) return;
    await _cameraCommand(() => _controller.setLens(_primaryFront, stored));
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

  /// Pick the caption language. Applies to the next recording immediately
  /// and is saved for later sessions; a job already queued keeps the
  /// language it was enqueued with.
  void _setCaptionLanguage(CaptionLanguage value) {
    if (value == _captionLanguage) return;
    _update(() => _captionLanguage = value);
    // Best effort: a failed save only means the next session starts on
    // Auto again (see CaptionLanguageStore).
    unawaited(_languageStore.save(value));
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

  List<Widget> _backgroundJobCards() => [
        const Text('Android keeps captions running when you leave StoryCam. '
            'Notifications show progress and Stop, then Open and Share when ready. '
            'The speech model downloads on first use (about 160 MB). Originals are kept.'),
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
    _update(() => _modelError = null);
    // Whole-percent throttle for the notification, as the banner used to do
    // for repaints. A cached model reports 0 then 1 with nothing between,
    // so no notification ever appears for it.
    double? lastReported;
    try {
      final model = await _modelManager.ensureModel(onProgress: (progress) {
        final value = progress.clamp(0.0, 1.0).toDouble();
        if (lastReported == null ||
            (value * 100).floor() != (lastReported! * 100).floor()) {
          lastReported = value;
          if (value > 0 && value < 1) {
            unawaited(_notifier.showProgress(value));
          }
        }
      });
      unawaited(_notifier.showReady());
      return model;
    } catch (e) {
      _modelFuture =
          null; // Allow an explicit retry or a later caption attempt.
      if (_modelManager.isCancelled) {
        // The user stopped the download: no failure UI, just the retry in
        // the Captions sheet. The message is self-contained (the sheet
        // shows it as-is).
        _update(() =>
            _modelError = 'Download stopped — tap Retry to start it again.');
        unawaited(_notifier.showStopped());
      } else {
        _update(
            () => _modelError = 'Caption model download failed: $e');
        unawaited(_notifier.showFailed('$e'));
      }
      rethrow;
    }
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
    // Watchdog: bound every platform call so a hung one surfaces as an
    // error instead of leaving `_busy` true forever. The raw call keeps
    // running underneath (platform calls cannot be cancelled); only the
    // wait is bounded, and disposal waits on this bounded future too.
    final future = action().timeout(_cameraTimeout, onTimeout: () {
      throw TimeoutException('Camera command timed out', _cameraTimeout);
    });
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
        await _cameraCommand(() => _controller.initialize(
            layout: _layout(), resolution: _settings.videoQuality));
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
        // Issue #20: probe the lenses + 4K support, re-apply the stored
        // filter/lens, and start the map — all best effort, none of it may
        // fail the camera open.
        await _loadLensesAndQuality();
        await _ensureMapLocation();
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

  /// Save a settings change (state + file, best effort on the file).
  void _updateSettings(CameraSettings next) {
    _update(() => _settings = next);
    unawaited(_settingsStore.save(next));
  }

  Future<void> _setFilter(VideoFilter f) => _guard(() async {
        await _cameraCommand(() => _controller.setFilter(f));
        _updateSettings(_settings.copyWith(filter: f));
      }, 'Filter updated');

  /// Probe the lenses for both facings + 4K support, then re-apply the
  /// stored filter and lens. Best effort throughout: a failed probe only
  /// hides the pills / the 4K row, never the camera.
  Future<void> _loadLensesAndQuality() async {
    try {
      final front = await _cameraCommand(() => _controller.getLenses(true));
      final rear = await _cameraCommand(() => _controller.getLenses(false));
      if (!mounted) return;
      _update(() {
        _lensesFront = front;
        _lensesRear = rear;
      });
    } catch (_) {
      // No lenses — the pills stay hidden.
    }
    try {
      final supports4k = await _cameraCommand(_controller.supports4k);
      if (mounted) _update(() => _supports4k = supports4k);
    } catch (_) {
      // 4K stays unoffered.
    }
    try {
      await _cameraCommand(() => _controller.setFilter(_settings.filter));
      await _applyStoredLens();
    } catch (_) {
      // Stored tuning is best effort on open.
    }
  }

  /// Switch to the lens at [ratio] on the primary camera. The switch needs
  /// no rebind (zoom-ratio switch), so the pills stay enabled while
  /// recording; the _busy lock only covers the in-flight command itself.
  Future<void> _setLens(double ratio) => _guard(() async {
        await _cameraCommand(
            () => _controller.setLens(_primaryFront, ratio));
        _updateSettings(_primaryFront
            ? _settings.copyWith(frontLens: ratio)
            : _settings.copyWith(rearLens: ratio));
      }, 'Lens switch');

  /// Switch the recording resolution. Resolution is fixed at initialize,
  /// so a live camera re-inits (not while recording — the row is disabled
  /// then); a camera that was never opened just stores the choice.
  Future<void> _setVideoQuality(DualResolution quality) => _guard(() async {
        if (quality == _settings.videoQuality) return;
        _updateSettings(_settings.copyWith(videoQuality: quality));
        if (!_controller.value.isInitialized ||
            _controller.value.isRecording) {
          return;
        }
        final restored = await _cameraCommand(
            () => _controller.reinitialize(resolution: quality));
        if (!mounted) return;
        if (!restored) {
          _update(() => _status =
              'Camera could not restart at the new quality. Tap Open camera to retry.');
          return;
        }
        await _reapplyTuning();
      }, 'Video quality');

  /// Flip which feed is full-frame, live, and re-apply the stored lens for
  /// the newly primary camera.
  Future<void> _swapPrimary() => _guard(() async {
        await _cameraCommand(_controller.swapPrimary);
        _update(() => _primaryFront = !_primaryFront);
        try {
          await _applyStoredLens();
        } catch (_) {
          // Stored lens is best effort on swap.
        }
      }, 'Swap cameras');

  /// Start the map location streams when the circle is on and the
  /// permission allows it. The permission is requested at most once per
  /// install (remembered in settings); a denial hides the circle and never
  /// re-prompts — the Settings dialog points at the system settings.
  Future<void> _ensureMapLocation() async {
    if (!_settings.mapVisible) return;
    if (_locationGranted) {
      _location.start();
      _subscribeMapStreams();
      return;
    }
    bool granted;
    if (_settings.locationPermissionRequested) {
      granted = await _location.isGranted();
    } else {
      granted = await _location.ensurePermission();
      _updateSettings(
          _settings.copyWith(locationPermissionRequested: true));
      if (!mounted) return;
    }
    if (!granted) return;
    _update(() => _locationGranted = true);
    _location.start();
    _subscribeMapStreams();
  }

  void _subscribeMapStreams() {
    _positionSub ??= _location.positions.listen((p) {
      if (mounted) _update(() => _position = p);
    });
    _headingSub ??= _location.headings.listen((h) {
      if (!mounted) return;
      // Compass events fire rapidly; repaint only on a real turn.
      if ((h - _heading).abs() >= 2) _update(() => _heading = h);
    });
  }

  /// Stop the map streams (the user hid the circle). The permission
  /// decision stays remembered; re-enabling the circle restarts them.
  void _stopMapLocation() {
    unawaited(_positionSub?.cancel());
    unawaited(_headingSub?.cancel());
    _positionSub = null;
    _headingSub = null;
    _location.stop();
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
      _firePendingRecord();
    }
  }

  /// Fire a shutter tap that was queued while a command was in flight.
  /// Runs only once the lock is free (a tuning flush in the same `finally`
  /// re-locks first; its own `finally` retries this). Dropped when the
  /// screen is gone, the camera is not initialized, or a recording has
  /// started meanwhile (the tap predates it).
  void _firePendingRecord() {
    if (!_pendingRecord || _busy || !mounted) return;
    _pendingRecord = false;
    final value = _controller.value;
    if (!value.isInitialized || value.isRecording) return;
    unawaited(_record());
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
      // Only after a successful save: on a Gal failure _lastVideo stays
      // null, so no Share button appears next to a save-failed status.
      _lastVideo = file;
      if (!mounted && !_usesBackgroundJobs) return;
      _update(() {
        _status = 'Video saved to gallery';
      });
    } catch (e) {
      _update(() {
        _lastVideo = null;
        _status = 'Could not save video. See settings for details.';
        _error = '$e';
      });
      return;
    }
    if (captions) {
      if (_usesBackgroundJobs) {
        try {
          await _jobs.enqueue(file, language: _captionLanguage.code);
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

  /// Share the just-recorded video (issue #14). Idempotent: _lastVideo is
  /// never consumed — a second tap re-opens the sheet with the same file;
  /// it is replaced only by the next _stop(). The caption pipeline is
  /// untouched: no generation bump, no cancel, status text unchanged on
  /// success (dismissing the sheet is a no-op). Not routed through
  /// _guard/_perform: sharing must not take the _busy lock — the button
  /// stays visible while the sheet is open.
  Future<void> _shareVideo() async {
    final path = _lastVideo;
    if (path == null) return;
    if (!File(path).existsSync()) {
      // File deleted / moved after save: hide the button, say so plainly.
      _update(() {
        _lastVideo = null;
        _status = 'Video no longer available. Record again.';
      });
      return;
    }
    try {
      await _shareChannel.invokeMethod<void>('shareVideo', {'path': path});
    } catch (e) {
      // Platform failure (MissingPluginException, channel error, native
      // error incl. a file vanishing mid-call): same failure pattern as
      // other commands — status + _error, no crash, button stays visible.
      _update(() {
        _status = 'Could not open share sheet. See settings for details.';
        _error = '$e';
      });
    }
  }

  void _queueCaptions(String mp4) {
    final generation = _captionGeneration;
    _update(() => _captionJobs++);
    _captionQueue = _captionQueue.then((_) async {
      if (!mounted) return;
      if (generation != _captionGeneration) {
        // Stopped while queued: drop the job, keep the original video.
        _update(() => _captionJobs--);
        return;
      }
      await _captionVideo(mp4, generation);
      _update(() => _captionJobs--);
    });
  }

  bool _captionAborted(int generation) => generation != _captionGeneration;

  /// Stop button on the caption notification (v0.5.3). Bumps the
  /// generation: the in-flight job aborts at the next stage boundary and
  /// queued jobs are dropped. The transcription decode itself is
  /// synchronous FFI and cannot be interrupted mid-decode, so a stop tapped
  /// during transcription lands after the decode, before burn-in — no
  /// captioned video is ever saved after a stop. The original video is
  /// already in the gallery and stays intact.
  void _stopCaptionJob() {
    _captionGeneration++;
    unawaited(_captionNotifier.clear());
  }

  Future<void> _captionVideo(String mp4, int generation) async {
    try {
      await _captionNotifier.showProgress(CaptionStage.extracting, 0);
      if (!mounted || _captionAborted(generation)) return;
      final wav = await _captionPipeline.extractAudio(mp4);
      if (!mounted || _captionAborted(generation)) return;

      await _captionNotifier.showProgress(CaptionStage.preparingModel, 0);
      if (!mounted || _captionAborted(generation)) return;
      final model = await _ensureModel();
      if (!mounted || _captionAborted(generation)) return;

      await _captionNotifier.showProgress(CaptionStage.transcribing, 0);
      if (!mounted || _captionAborted(generation)) return;
      // Let the progress notification paint before the blocking decode.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (!mounted || _captionAborted(generation)) return;
      final result = await _transcriber.transcribe(
        wavPath: wav,
        model: model,
        language: _captionLanguage.code,
      );
      if (!mounted || _captionAborted(generation)) return;
      final words = result.words;
      if (words.isEmpty) {
        await _captionNotifier.showNoSpeech();
        return;
      }

      await _captionNotifier.showProgress(CaptionStage.burning, 0);
      if (!mounted || _captionAborted(generation)) return;
      final captioned = await _captionPipeline.burnCaptions(
        mp4Path: mp4,
        words: words,
      );
      if (!mounted || _captionAborted(generation)) return;
      await Gal.putVideo(captioned);
      if (!mounted || _captionAborted(generation)) return;
      _update(() {
        _captionedFile = captioned;
        _captionSourceFile = mp4;
      });
      await _captionNotifier.showDone(
          words.length, result.detectedLanguage);
    } catch (e) {
      if (!mounted) return;
      if (_captionAborted(generation) ||
          (e is ModelDownloadException &&
              e.message == 'Caption job stopped')) {
        // The user stopped the job (or the model download it was waiting
        // on): silent — the original video is intact and the notification
        // is already gone. (Checked against the exception, not the
        // manager's latch: the latch stays set until the next fresh model
        // attempt, so it would misclassify a later, unrelated failure —
        // e.g. at extractAudio — as a stop.)
        await _captionNotifier.clear();
        return;
      }
      _update(() => _error = '$e');
      await _captionNotifier.showFailed('$e');
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
    _updateSettings(_settings.copyWith(mirrorFront: on));
    await _cameraCommand(
        () => _debug.invokeMethod<void>('setMirrorFront', {'on': on}));
  }

  @override
  void dispose() {
    _jobPoll?.cancel();
    _stopMapLocation();
    if (_ownsMapService) _mapService?.dispose();
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
            value: _settings.mirrorFront,
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

  // One GlobalKey per Settings section, so a bottom-menu tap can open the
  // dialog scrolled to that section (issue #20).
  final Map<SettingsSection, GlobalKey> _sectionKeys = {
    for (final section in SettingsSection.values) section: GlobalKey(),
  };

  void _sheet(String title, List<Widget> Function(DualCameraValue) contents,
      {SettingsSection? initialSection}) {
    // Scroll to the requested section once, when the sheet opens.
    var scrolled = false;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF19181F),
      builder: (sheetContext) {
        if (initialSection != null && !scrolled) {
          scrolled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final sectionContext =
                _sectionKeys[initialSection]?.currentContext;
            if (sectionContext != null) {
              Scrollable.ensureVisible(sectionContext,
                  alignment: 0.0,
                  duration: const Duration(milliseconds: 200));
            }
          });
        }
        return SafeArea(
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
        );
      },
    );
  }

  Widget _sectionHeader(SettingsSection section) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 4),
        child: Text(section.title,
            key: _sectionKeys[section],
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w800)),
      );

  /// The one Settings dialog (issue #20, v2): Map & compass, Front camera,
  /// Rear camera, Captions — plus the existing exposure / session / debug
  /// rows below. A bottom-menu tap opens it at that section; tapping never
  /// toggles the feature directly.
  void _settingsSheet({SettingsSection initialSection = SettingsSection.map}) =>
      _sheet(
        'Camera settings',
        (value) => [
          _sectionHeader(SettingsSection.map),
          const Text('Compass mode'),
          const Text('How the map turns as you move',
              style: TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final mode in CompassMode.values)
                ChoiceChip(
                  label: Text(mode.label),
                  selected: _settings.compassMode == mode,
                  onSelected: (_) =>
                      _updateSettings(_settings.copyWith(compassMode: mode)),
                ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Location circle'),
            subtitle:
                const Text('Show the map on the camera screen'),
            value: _settings.mapVisible,
            onChanged: _busy
                ? null
                : (v) {
                    _updateSettings(_settings.copyWith(mapVisible: v));
                    if (v) {
                      unawaited(_ensureMapLocation());
                    } else {
                      _stopMapLocation();
                    }
                  },
          ),
          if (_settings.mapVisible &&
              !_locationGranted &&
              _settings.locationPermissionRequested)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                    'Location permission is off, so the circle stays hidden.'),
                TextButton(
                    onPressed: openAppSettings,
                    child: const Text('Enable location in settings')),
              ],
            ),
          _sectionHeader(SettingsSection.front),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Mirror selfie'),
            subtitle:
                const Text('Flip the front preview like a mirror'),
            value: _settings.mirrorFront,
            onChanged: _busy ? null : (v) => _guard(() => _setMirror(v), 'Mirror'),
          ),
          _sectionHeader(SettingsSection.rear),
          const Text('Video quality'),
          const Text('Recording resolution',
              style: TextStyle(fontSize: 12)),
          if (!_supports4k)
            const Text('4K is not available on this device.',
                style: TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('1080p'),
                selected:
                    _settings.videoQuality == DualResolution.hd1080,
                onSelected: _busy || value.isRecording
                    ? null
                    : (_) => _guard(
                        () => _setVideoQuality(DualResolution.hd1080),
                        'Video quality'),
              ),
              ChoiceChip(
                label: const Text('4K'),
                selected: _settings.videoQuality ==
                    DualResolution.ultraHd2160,
                onSelected: _busy || value.isRecording || !_supports4k
                    ? null
                    : (_) => _guard(
                        () => _setVideoQuality(
                            DualResolution.ultraHd2160),
                        'Video quality'),
              ),
            ],
          ),
          _sectionHeader(SettingsSection.captions),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Auto-captions'),
            subtitle: const Text(
                'On-device speech recognition and karaoke subtitles (alpha).'),
            value: _captions,
            onChanged: _busy || value.isRecording ? null : _toggleCaptions,
          ),
          const SizedBox(height: 8),
          const Text('Caption language'),
          const Text(
              'Auto usually works, but it can mishear a short phrase in the wrong language. Pick a language to force it.',
              style: TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final language in CaptionLanguage.values)
                ChoiceChip(
                  label: Text(language.label),
                  selected: _captionLanguage == language,
                  onSelected: _busy || value.isRecording
                      ? null
                      : (_) => _setCaptionLanguage(language),
                ),
            ],
          ),
          if (_usesBackgroundJobs) ..._backgroundJobCards(),
          if (!_usesBackgroundJobs) ...[
            const Text(
                'The speech model downloads at startup (about 160 MB on first use). Download progress is in the notification shade. Captions run on device once ready. Your original video is always kept.'),
            if (_modelError != null) ...[
              const SizedBox(height: 8),
              Text(_modelError!),
              TextButton(
                onPressed: _prepareModel,
                child: const Text('Retry'),
              ),
            ],
          ],
          // Caption processing state lives in the notification only
          // (v0.5.3): no status text, no progress bar, no queue count
          // here. The busy indicator below is for camera commands only.
          if (_busy) const LinearProgressIndicator(),
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
              if (value.isInitialized)
                FittedBox(
                    fit: BoxFit.scaleDown,
                    child: DualCameraStatsOverlay(_controller)),
            ],
          ),
          if (value.isInitialized)
            IgnorePointer(ignoring: _busy, child: _debugPanel()),
        ],
        initialSection: initialSection,
      );

  Future<void> _record() {
    if (_busy) {
      // The shutter stays enabled while busy (v0.5.2): queue the tap and
      // say so at once instead of dropping it silently. Fired from
      // `_perform`'s finally once the lock frees.
      _pendingRecord = true;
      _update(() => _status = 'Please wait…');
      return Future<void>.value();
    }
    return _guard(() async {
      if (_controller.value.isRecording) {
        await _stop();
      } else {
        await _cameraCommand(_controller.startRecording);
        _update(() {
          _status = 'Recording your story';
        });
      }
    }, 'Recording');
  }

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
          if (_visibleJobError != null) _visibleJobError!,
        ].join('\n');
        return StoryCamera(
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
          status: status,
          onCapture: value.isInitialized
              ? _record
              : (_caps?.isSupported ?? false)
                  ? _start
                  : null,
          onPhoto: ready ? _photo : null,
          onSwap: ready ? _swapPrimary : null,
          onSettings: () => _settingsSheet(),
          // Map circle (issue #20): only when the circle is on AND the
          // location permission was granted — a denial hides it, no crash,
          // no repeated prompt. No position yet = plain disc + N arrow.
          mapCircle: _settings.mapVisible && _locationGranted
              ? MapCircle(
                  position: _position,
                  headingDeg: _heading,
                  mode: _settings.compassMode,
                  // No tile fetches under `flutter test` (hermetic; the
                  // disc + dot + N arrow still render).
                  showTiles: Platform.environment['FLUTTER_TEST'] != 'true',
                )
              : null,
          // Lens pills (issue #20): only the active camera's probed
          // lenses; hidden before init (nothing probed yet).
          lensPills: value.isInitialized
              ? LensPills(
                  lenses:
                      _primaryFront ? _lensesFront : _lensesRear,
                  selectedRatio: (_primaryFront
                          ? _settings.frontLens
                          : _settings.rearLens) ??
                      1.0,
                  onSelected: _setLens,
                  enabled: !_busy,
                )
              : null,
          // Filter slider (issue #20): over the video, above the record
          // button. Disabled until the camera is ready.
          filterSlider: FilterSlider(
            selected: _settings.filter,
            onSelected: _setFilter,
            enabled: ready,
          ),
          // Bottom text menu (issue #20): tap opens Settings at the
          // section, never a direct toggle.
          bottomMenu: CameraBottomMenu(
            mapOn: _settings.mapVisible,
            frontPrimary: _primaryFront,
            captionsOn: _captions,
            onMap: () =>
                _settingsSheet(initialSection: SettingsSection.map),
            onFront: () =>
                _settingsSheet(initialSection: SettingsSection.front),
            onRear: () =>
                _settingsSheet(initialSection: SettingsSection.rear),
            onCaptions: () =>
                _settingsSheet(initialSection: SettingsSection.captions),
            onSettings: () => _settingsSheet(),
          ),
          // Share (issue #14): only once a video is saved and no command
          // is in flight — hidden before any recording, while recording,
          // and while _busy (e.g. Gal.putVideo still in flight in _stop).
          // Appears on the rebuild after _perform's finally clears _busy.
          onShare: (!_busy && !value.isRecording && _lastVideo != null)
              ? _shareVideo
              : null,
        );
      },
    );
  }
}
