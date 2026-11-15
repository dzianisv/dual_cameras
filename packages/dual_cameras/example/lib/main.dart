import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dual_cameras/dual_cameras.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:latlong2/latlong.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';

import 'analytics.dart';
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
import 'captions/review_prompt_gate.dart';
import 'captions/transcriber.dart';
import 'crash_reporting.dart';
import 'map/camera_settings.dart';
import 'map/map_location.dart';
import 'map/place_name.dart';
import 'review_prompt.dart';
import 'ui/bottom_menu.dart';
import 'ui/filter_slider.dart';
import 'ui/last_video_player.dart';
import 'ui/lens_pills.dart';
import 'ui/map_circle.dart';
import 'ui/story_camera.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // No-op when built without --dart-define SENTRY_DSN: Sentry is never
  // initialized and the app boots exactly as before.
  await CrashReporting.init();
  // No-op when built without --dart-define POSTHOG_API_KEY: PostHog is
  // never initialized and the app boots exactly as before.
  await Analytics.init();
  // One open per cold start; fire-and-forget — the state read must never
  // delay startup.
  unawaited(Analytics.appOpen());
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
      this.mapLocationService,
      this.placeNameService,
      this.reviewPromptGate,
      this.reviewPrompt,
      this.appVersion,
      this.deleteFile,
      this.transcriber});

  final ModelManager? modelManager;
  final CaptionJobs? captionJobs;
  final bool? backgroundCaptions;
  final CaptionLanguageStore? captionLanguageStore;
  final ModelDownloadNotifier? modelDownloadNotifier;
  final CaptionJobNotifier? captionJobNotifier;
  final Duration? cameraCommandTimeout;
  final CameraSettingsStore? cameraSettingsStore;
  final MapLocationService? mapLocationService;
  final PlaceNameService? placeNameService;
  // In-app review prompt (issue #37): injectable seams for widget tests.
  // The gate persists the prompted version; the facade is the Play call;
  // the version string is injected so tests never touch the
  // package_info_plus channel. All three default to the real thing.
  final ReviewPromptGate? reviewPromptGate;
  final ReviewPrompt? reviewPrompt;
  final String? appVersion;
  // Issue #56: the real File.delete cannot be forced to throw in a widget
  // test (the host runs as root, so a read-only directory does not fail
  // the unlink), so the twin-failure leg is untestable without this seam
  // — same pattern as transcriber below.
  final Future<void> Function(File file)? deleteFile;
  // Issue #50 (F2 fix): the real Transcriber is sherpa-onnx FFI and
  // cannot run in a widget test, so the twin path is untestable without
  // this seam — same pattern as modelManager above.
  final Transcriber? transcriber;

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
          mapLocationService: mapLocationService,
          placeNameService: placeNameService,
          reviewPromptGate: reviewPromptGate,
          reviewPrompt: reviewPrompt,
          appVersion: appVersion,
          deleteFile: deleteFile,
          transcriber: transcriber),
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
      this.mapLocationService,
      this.placeNameService,
      this.reviewPromptGate,
      this.reviewPrompt,
      this.appVersion,
      this.deleteFile,
      this.transcriber});

  final ModelManager? modelManager;
  final CaptionJobs? captionJobs;
  final bool? backgroundCaptions;
  final CaptionLanguageStore? captionLanguageStore;
  final ModelDownloadNotifier? modelDownloadNotifier;
  final CaptionJobNotifier? captionJobNotifier;
  final Duration? cameraCommandTimeout;
  final CameraSettingsStore? cameraSettingsStore;
  final MapLocationService? mapLocationService;
  final PlaceNameService? placeNameService;
  final ReviewPromptGate? reviewPromptGate;
  final ReviewPrompt? reviewPrompt;
  final String? appVersion;
  final Future<void> Function(File file)? deleteFile;
  final Transcriber? transcriber;

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
  // A resume re-init that lands while a camera command is in flight is
  // queued, not dropped (issue #18: _guard would drop it silently and
  // _wasBackgrounded is already cleared, so there is no retry — stale
  // preview until the user re-taps Open camera). Fired from `_perform`'s
  // finally once the lock frees; mirrors the _pendingRecord shutter queue.
  bool _pendingResume = false;
  // A lens tap that lands while a camera command is in flight is queued,
  // not dropped (issue #48, Path B: _guard would drop it silently and
  // the pills gave no feedback — the same shape as the v0.5.1 shutter
  // defect _pendingRecord fixed). Only the latest tap is kept; fired
  // from `_perform`'s finally once the lock frees. [_statusBeforeLensWait]
  // holds the status text from before the wait, so 'Please wait…' is
  // restored (not stuck) once the queued switch lands.
  double? _pendingLens;
  String? _statusBeforeLensWait;
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
  // In-memory thumbnail bytes for _lastVideo (issue #50): a real frame
  // at 500 ms, JPEG, max width 128, quality 75, generated in _stop()
  // after Gal.putVideo succeeds. Null while generating or when
  // generation failed — the tile falls back to a video icon, and the
  // menu is never blocked by it. In-memory only, gone on restart.
  Uint8List? _lastVideoThumb;
  // Enqueued background caption job for the last video (issue #50):
  // _stop() retains the id (it was discarded) so Delete can cancel the
  // job for this video through _jobAction. Null when captions run in
  // the foreground or no job was enqueued.
  String? _lastBackgroundJobId;
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

  // Issue #49 SPIKE ONLY (branch spike/map-capture-49, never merge as-is):
  // 2 fps RepaintBoundary snapshots of the map circle while recording, to
  // prove or disprove the design §1 capture mechanism. Capture +
  // measurement only — no burner, no caller restructure. Results go to
  // logcat as [MAPSPIKE] lines; the Stage 3 implementer reuses
  // _mapCaptureSnapshot, the takeId/dir naming, and the track shape.
  // N-H: the boundary key is a stable State field, created once.
  final GlobalKey _mapBoundaryKey = GlobalKey();
  Timer? _mapCaptureTimer;
  int? _mapTakeId;
  Directory? _mapFramesDir;
  DateTime? _mapRecStart;
  int _mapSnapAttempted = 0;
  int _mapSnapCaptured = 0;
  int _mapSnapFailed = 0;
  int _mapSnapBytes = 0;
  int _mapSnapMaxBytes = 0;
  int _mapCapHit = 0;
  // Track: (take-relative tMs, mapVisible) — one sample per snapshot plus
  // one on every map toggle (N-D: the tick skips when the boundary is
  // unmounted, i.e. map toggled off, but still records the off-sample).
  final List<({int tMs, bool mapVisible})> _mapTrack = [];
  int _mapMaxDropped = 0;
  double _mapMinFps = double.infinity;
  static const int _mapCapBytes = 100 * 1024 * 1024;

  /// Recorded frame width in px (portrait short side), from the resolution
  /// setting. Burn diameter is 315 px at 1080p (design §4), scaled linearly.
  int get _mapVideoWidth => switch (_settings.videoQuality) {
        DualResolution.sd480 => 480,
        DualResolution.hd720 => 720,
        DualResolution.hd1080 => 1080,
        DualResolution.ultraHd2160 => 2160,
      };

  /// pixelRatio so toImage() renders at burn diameter: MapCircle is 120
  /// logical px across; 315 px at 1080p, 630 px at 4K.
  double get _mapPixelRatio => (_mapVideoWidth * 315 / 1080) / 120;

  /// Start the 500 ms snapshot tick. takeId is milliseconds since epoch at
  /// the _record / startRecording call (N-A correction — _start is
  /// camera-open, recording starts in _record).
  Future<void> _mapStartCapture() async {
    _mapStopCapture(silent: true); // Defensive: never double-run.
    _mapTakeId = DateTime.now().millisecondsSinceEpoch;
    _mapRecStart = DateTime.now();
    _mapSnapAttempted = 0;
    _mapSnapCaptured = 0;
    _mapSnapFailed = 0;
    _mapSnapBytes = 0;
    _mapSnapMaxBytes = 0;
    _mapCapHit = 0;
    _mapTrack.clear();
    _mapMaxDropped = 0;
    _mapMinFps = double.infinity;
    try {
      final cache = await getTemporaryDirectory();
      // Drop stale spike dirs from earlier takes (design: deleted on the
      // next _start; the spike deletes at recording start instead).
      for (final e in cache.listSync()) {
        if (e is Directory && e.path.contains('map_frames_')) {
          try {
            await e.delete(recursive: true);
          } catch (_) {}
        }
      }
      _mapFramesDir = Directory('${cache.path}/map_frames_$_mapTakeId');
      await _mapFramesDir!.create(recursive: true);
    } catch (e) {
      debugPrint('[MAPSPIKE] START FAILED takeId=$_mapTakeId error=$e');
      _mapTakeId = null;
      _mapRecStart = null;
      return;
    }
    debugPrint('[MAPSPIKE] START takeId=$_mapTakeId '
        'videoWidth=$_mapVideoWidth '
        'pixelRatio=${_mapPixelRatio.toStringAsFixed(3)} '
        'dir=${_mapFramesDir!.path}');
    // N-C: immediate snapshot at recording start — the first periodic tick
    // lands at 500 ms, leaving tSec 0–0.5 s with no snapshot otherwise.
    unawaited(_mapCaptureSnapshot());
    _mapCaptureTimer =
        Timer.periodic(const Duration(milliseconds: 500), (_) {
      unawaited(_mapCaptureSnapshot());
    });
  }

  /// One snapshot: boundary → PNG at burn diameter → map_<tMs>.png, plus a
  /// track sample. tMs is take-relative (N-C). Never throws; a failure is
  /// counted and logged, never crashes the recording.
  Future<void> _mapCaptureSnapshot() async {
    final takeId = _mapTakeId;
    final dir = _mapFramesDir;
    final start = _mapRecStart;
    if (takeId == null || dir == null || start == null) return;
    final tMs = DateTime.now().difference(start).inMilliseconds;
    // N-D: tick guard — map toggled off unmounts the boundary; skip the
    // capture but record the off-sample so the track still gates the burn.
    final context = _mapBoundaryKey.currentContext;
    if (context == null) {
      _mapTrack.add((tMs: tMs, mapVisible: false));
      return;
    }
    final boundary = context.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) {
      _mapSnapFailed++;
      return;
    }
    _mapSnapAttempted++;
    try {
      final image = await boundary.toImage(pixelRatio: _mapPixelRatio);
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (byteData == null) {
        _mapSnapFailed++;
        return;
      }
      final bytes = byteData.buffer.asUint8List();
      await File('${dir.path}/map_$tMs.png')
          .writeAsBytes(bytes, flush: true);
      _mapSnapCaptured++;
      _mapSnapBytes += bytes.length;
      if (bytes.length > _mapSnapMaxBytes) _mapSnapMaxBytes = bytes.length;
      _mapTrack.add((tMs: tMs, mapVisible: _settings.mapVisible));
      if (_mapSnapBytes > _mapCapBytes) {
        _mapCapHit++;
        _mapCaptureTimer?.cancel();
        _mapCaptureTimer = null;
        debugPrint('[MAPSPIKE] CAP HIT takeId=$takeId bytes=$_mapSnapBytes '
            'captured=$_mapSnapCaptured — capture stopped, recording continues');
      }
    } catch (e) {
      _mapSnapFailed++;
      debugPrint('[MAPSPIKE] SNAPSHOT FAILED tMs=$tMs error=$e');
    }
    // FrameStats sample: the objective encoder-drop signal (design §1 —
    // droppedFrames is "frames dropped at the encoder boundary since
    // recording began", per messages.g.dart).
    final stats = _controller.value.stats;
    if (stats != null) {
      if (stats.droppedFrames > _mapMaxDropped) {
        _mapMaxDropped = stats.droppedFrames;
      }
      if (stats.fps < _mapMinFps) _mapMinFps = stats.fps;
    }
  }

  /// Record a track sample on a map toggle during a take (N-D companion).
  void _mapRecordToggle(bool visible) {
    final start = _mapRecStart;
    if (_mapTakeId == null || start == null) return;
    _mapTrack.add((
      tMs: DateTime.now().difference(start).inMilliseconds,
      mapVisible: visible,
    ));
  }

  /// Stop the tick and log the summary. The native stopRecordingResult log
  /// line (RenderThread MAPSPIKE) carries the encoder frame count for the
  /// duration × fps check; this line carries the capture numbers.
  void _mapStopCapture({bool silent = false}) {
    _mapCaptureTimer?.cancel();
    _mapCaptureTimer = null;
    if (silent || _mapTakeId == null || _mapRecStart == null) return;
    final durationMs =
        DateTime.now().difference(_mapRecStart!).inMilliseconds;
    // Immediate snapshot at t=0 plus one per 500 ms tick.
    final expected = durationMs ~/ 500 + 1;
    final rate = expected == 0 ? 0.0 : _mapSnapCaptured / expected * 100;
    debugPrint('[MAPSPIKE] SUMMARY takeId=$_mapTakeId '
        'durationMs=$durationMs expected=$expected '
        'attempted=$_mapSnapAttempted captured=$_mapSnapCaptured '
        'failed=$_mapSnapFailed rate=${rate.toStringAsFixed(1)}% '
        'bytes=$_mapSnapBytes '
        'avgBytes=${_mapSnapCaptured == 0 ? 0 : _mapSnapBytes ~/ _mapSnapCaptured} '
        'maxBytes=$_mapSnapMaxBytes capHit=$_mapCapHit '
        'maxDroppedFrames=$_mapMaxDropped '
        'minFps=${_mapMinFps == double.infinity ? 'n/a' : _mapMinFps.toStringAsFixed(1)} '
        'trackSamples=${_mapTrack.length} dir=${_mapFramesDir?.path}');
    _mapTakeId = null;
    _mapRecStart = null;
    _mapFramesDir = null;
  }

  // Place name (issue #47): reverse-geocoded label under the map circle,
  // derived from the live position on every launch — never persisted as a
  // display value (yesterday's place under today's dot would be wrong).
  PlaceNameService? _placeService;
  PlaceNameService get _placeNames =>
      _placeService ??= widget.placeNameService ?? PlaceNameService();
  String? _placeName;

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
  // Issue #56: injectable so a widget test can force the twin delete to
  // throw; defaults to the real File.delete.
  late final Future<void> Function(File file) _deleteFile =
      widget.deleteFile ??
          (File file) async {
            await file.delete();
          };
  // Issue #50 (F2 fix): injectable so a widget test can complete a
  // caption job and produce the twin; defaults to the real FFI one.
  late final Transcriber _transcriber =
      widget.transcriber ?? Transcriber();
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

  // In-app review prompt (issue #37): at most once per app version, on
  // the first completed recording of that version. The gate persists the
  // prompted version; the facade is the Play call behind an injectable
  // seam so widget tests count requests without Play.
  late final ReviewPromptGate _reviewGate =
      widget.reviewPromptGate ?? ReviewPromptGate();
  late final ReviewPrompt _reviewPrompt =
      widget.reviewPrompt ?? InAppReviewPrompt();

  // Live geometry tuning (debug channel) — to dial in the front/back
  // orientation and fix any stretch directly on the device.
  static const MethodChannel _debug = MethodChannel('dual_cameras/debug');
  // Share sheet (issue #14): `shareVideo {path}` fires ACTION_SEND via
  // the native ShareChannel + FileProvider. Separate channel from the
  // dead `caption_jobs` share path — that channel has no native handler.
  static const MethodChannel _shareChannel =
      MethodChannel('dual_cameras_example/share');
  // Last-video thumbnail (issue #50): `videoThumbnail {path, maxWidth,
  // quality, timeMs}` returns one frame as JPEG bytes, extracted
  // natively (Android MediaMetadataRetriever, iOS AVAssetImageGenerator).
  // Own channel, not the share channel: the thumbnail is a read-only
  // frame extraction whose failure is an invisible fallback, while
  // share/delete failures set status — and the widget tests mock the
  // two channels independently. No third-party dep: video_thumbnail
  // 0.5.6 was removed — its android/build.gradle calls jcenter(),
  // gone under this project's AGP 9+ setup, and 0.5.6 is the latest
  // version on pub.dev, so no newer release fixes it.
  static const MethodChannel _thumbnailChannel =
      MethodChannel('dual_cameras_example/thumbnail');
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
    final bootstrapFuture = _bootstrap();
    // A caption notification left over from a previous run (the app died
    // mid-captioning) must not linger: no job exists for it anymore.
    unawaited(_captionNotifier.clear());
    _languageStore.load().then((stored) {
      if (mounted) _update(() => _captionLanguage = stored);
    });
    final settingsFuture = _settingsStore.load().then((stored) {
      if (mounted) {
        // The load is async and unguarded: if the camera was already opened
        // (or the map re-enabled) before it resolved, _ensureMapLocation
        // may have set locationPermissionRequested=true in memory and saved
        // it — a stale stored snapshot must not overwrite that back to
        // false, or the next camera open would re-prompt. The flag is
        // monotonic (nothing ever clears it), so OR-merge it.
        _update(() => _settings = stored.copyWith(
              locationPermissionRequested: _settings
                      .locationPermissionRequested ||
                  stored.locationPermissionRequested,
            ));
      }
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
    // Issue #46: auto-initialize the camera on open — the first frame is
    // the trigger; _autoStart waits for the probe + settings first.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_autoStart(settingsFuture, bootstrapFuture));
    });
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
  Future<void> _resumeCamera() {
    if (_busy) {
      // The resume landed while a camera command was in flight (issue
      // #18): _guard would drop it silently and _wasBackgrounded is
      // already cleared, so queue it instead — _perform's finally fires
      // it once the lock frees. Mirrors the _pendingRecord shutter queue.
      _pendingResume = true;
      return Future<void>.value();
    }
    return _guard(() async {
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
  }

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
    // N1: `model_ready.cached` comes from this progress stream, not from
    // the ModelManager API — any value strictly between 0 and 1 means
    // bytes were actually downloaded.
    bool sawIntermediate = false;
    try {
      final model = await _modelManager.ensureModel(onProgress: (progress) {
        final value = progress.clamp(0.0, 1.0).toDouble();
        if (value > 0 && value < 1) sawIntermediate = true;
        if (lastReported == null ||
            (value * 100).floor() != (lastReported! * 100).floor()) {
          lastReported = value;
          if (value > 0 && value < 1) {
            unawaited(_notifier.showProgress(value));
          }
        }
      });
      unawaited(_notifier.showReady());
      Analytics.modelReady(cached: !sawIntermediate);
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
      Analytics.modelDownloadFailed(reason: _modelFailureReason(e));
      rethrow;
    }
  }

  /// Map a model failure to a short analytics reason code (N2): the user
  /// stopping the download, a storage failure, or anything else. Never
  /// the raw message — it could carry paths or file names. Message
  /// strings are the consts thrown in `model_manager.dart`.
  String _modelFailureReason(Object e) {
    if (_modelManager.isCancelled) return 'stopped';
    if (e is ModelDownloadException) {
      if (e.message == 'Caption job stopped') return 'stopped';
      if (e.message ==
          'Could not store the speech model. Check free storage and retry.') {
        return 'storage';
      }
    }
    return 'download';
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

  /// Auto-initialize the camera on app open (issue #46): the camera used
  /// to open only from the 'Open camera' tap, so first open showed an
  /// empty preview with no lens pills or filter slider. Fires post-frame,
  /// only after the capability probe resolved and settings loaded — so
  /// `_start` uses the stored video quality, not the default. Never fires
  /// while `_busy` is held (`_guard` would drop it silently), on an
  /// unsupported device, or when the screen is already gone; the
  /// 'Open camera' button stays as the retry for those cases.
  Future<void> _autoStart(
      Future<void> settingsLoaded, Future<void> probed) async {
    await settingsLoaded;
    await probed;
    if (!mounted || _busy || _controller.value.isInitialized) return;
    if (_caps?.isSupported != true) return;
    await _start();
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
        // Check status first (issue #46): a permanently-denied user must
        // not be re-prompted on every cold start — point at settings
        // instead. Otherwise request once; the prompt shows only for a
        // permission that is not granted yet.
        var cameraStatus = await Permission.camera.status;
        var micStatus = await Permission.microphone.status;
        if (!mounted) return;
        if (!cameraStatus.isGranted || !micStatus.isGranted) {
          if (cameraStatus.isPermanentlyDenied ||
              micStatus.isPermanentlyDenied) {
            _update(() => _status =
                'Camera and microphone access required. Allow access in device settings, then try again.');
            return;
          }
          final granted =
              await [Permission.camera, Permission.microphone].request();
          if (!mounted) return;
          cameraStatus = granted[Permission.camera] ?? cameraStatus;
          micStatus = granted[Permission.microphone] ?? micStatus;
        }
        if (!cameraStatus.isGranted || !micStatus.isGranted) {
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
  /// recording — and while busy, too: a tap that lands mid-command queues
  /// (issue #48, Path B) instead of vanishing silently, mirroring the
  /// _pendingRecord shutter queue. The _busy lock only covers the
  /// in-flight command itself.
  Future<void> _setLens(double ratio) {
    if (!mounted) return Future<void>.value();
    if (_busy) {
      _pendingLens = ratio;
      _statusBeforeLensWait ??= _status;
      _update(() => _status = 'Please wait…');
      return Future<void>.value();
    }
    return _guard(() async {
      await _cameraCommand(
          () => _controller.setLens(_primaryFront, ratio));
      _updateSettings(_primaryFront
          ? _settings.copyWith(frontLens: ratio)
          : _settings.copyWith(rearLens: ratio));
    }, 'Lens switch');
  }

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
      unawaited(_lookupPlaceName(p));
    });
    _headingSub ??= _location.headings.listen((h) {
      if (!mounted) return;
      // Compass events fire rapidly; repaint only on a real turn.
      if ((h - _heading).abs() >= 2) _update(() => _heading = h);
    });
  }

  /// Reverse-geocode the current position for the place pill (issue #47,
  /// D6/D7). The service gates on the 100 m move and the 1.1 s floor; the
  /// accuracy gate lives here: a fix worse than 50 m is skipped, so GPS
  /// jitter cannot random-walk the app past the move gate while standing
  /// still. Fire-and-forget — a failed lookup clears the label (a missing
  /// label is honest; a wrong place name is not).
  Future<void> _lookupPlaceName(LatLng position) async {
    // Hermetic widget tests run no network (the same rule as showTiles):
    // the default service never looks up under `flutter test`. A service
    // injected by a test (MockClient-backed) still runs, so the wiring
    // from fix to pill stays covered.
    if (widget.placeNameService == null &&
        Platform.environment['FLUTTER_TEST'] == 'true') {
      return;
    }
    final accuracy = _location.lastAccuracyMeters;
    if (accuracy != null && accuracy > 50) return;
    final label = await _placeNames.lookup(position);
    if (!mounted) return;
    if (label != _placeName) _update(() => _placeName = label);
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
      _firePendingResume();
      _firePendingLens();
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

  /// Fire a resume re-init that was queued while a command was in flight
  /// (issue #18). Runs only once the lock is free (a tuning flush in the
  /// same `finally` re-locks first; its own `finally` retries this). The
  /// flag stays set while busy, so a later `finally` retries it; it is
  /// cleared only when the resume actually fires. Dropped when the screen
  /// is gone — no session left to restore.
  void _firePendingResume() {
    if (!_pendingResume || _busy || !mounted) return;
    _pendingResume = false;
    unawaited(_resumeCamera());
  }

  /// Fire a lens tap that was queued while a command was in flight
  /// (issue #48, Path B). Runs only once the lock is free (a tuning flush
  /// in the same `finally` re-locks first; its own `finally` retries
  /// this). The pending ratio is cleared only when the switch actually
  /// fires. Dropped when the screen is gone or the camera is not
  /// initialized — no session left to switch. On success the pre-wait
  /// status is restored, so 'Please wait…' never sticks; on failure
  /// _perform already replaced it with the error, so there is nothing to
  /// restore. A switch while recording is fine (zoom-ratio switch, no
  /// rebind), so unlike _pendingRecord there is no recording drop.
  void _firePendingLens() {
    if (_pendingLens == null || _busy || !mounted) return;
    final ratio = _pendingLens;
    _pendingLens = null;
    final previousStatus = _statusBeforeLensWait;
    _statusBeforeLensWait = null;
    if (!_controller.value.isInitialized) {
      if (previousStatus != null && _status == 'Please wait…') {
        _update(() => _status = previousStatus);
      }
      return;
    }
    unawaited(_setLens(ratio!).then((_) {
      if (!mounted || previousStatus == null) return;
      if (_status == 'Please wait…') {
        _update(() => _status = previousStatus);
      }
    }));
  }

  /// Stop recording, save to gallery, then optionally run the auto-captions
  /// pipeline (extract audio -> on-device STT -> karaoke burn-in). The
  /// original uncaptioned mp4 is always kept; the captioned one is a second
  /// file. Any captions failure falls back to the plain video.
  Future<void> _stop() async {
    // Issue #50, stale-frame guard (N8, first half): clear the previous
    // thumbnail — and the previous background job id — before the new
    // recording stops, so the tile never shows the previous video's
    // frame while the new one generates. The generation's path check
    // (second half, _generateLastVideoThumb) closes the late-write path
    // a clear alone leaves open.
    _update(() => _lastVideoThumb = null);
    _lastBackgroundJobId = null;
    final captions = _captions;
    late final String file;
    try {
      file = await _cameraCommand(_controller.stopRecording);
      // Issue #49 spike: stop the snapshot tick, log the summary.
      _mapStopCapture();
      _lastFile = file;
      await Gal.putVideo(file);
      // Only after a successful save: on a Gal failure _lastVideo stays
      // null, so no thumbnail appears next to a save-failed status.
      _lastVideo = file;
      // Issue #50: real-frame thumbnail, fire-and-forget after the save
      // — it never delays the status and never holds _busy. A null
      // result or throw leaves _lastVideoThumb null and the tile shows
      // the video-icon placeholder; the menu is never blocked by it.
      unawaited(_generateLastVideoThumb(file));
      // Analytics: the recording completed and saved. Fire-and-forget —
      // never delays the save flow. (N3: no duration_seconds — no
      // recording timer exists at this hook, and none is added.)
      unawaited(Analytics.coreActionDone(
          captionsOn: captions, captionLanguage: _captionLanguage.code));
      if (!mounted && !_usesBackgroundJobs) return;
      _update(() {
        _status = 'Video saved to gallery';
      });
    } catch (e) {
      // Issue #49 spike: stopRecording failed — stop the tick too, so a
      // failed stop cannot leave snapshots running against a dead take.
      _mapStopCapture();
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
          // Issue #50: retain the enqueued id so Delete can cancel the
          // job for this video through _jobAction (it was discarded).
          _lastBackgroundJobId =
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
    // In-app review prompt (issue #37): the core loop is complete — the
    // video is saved. Fire-and-forget: never awaited, never holds _busy,
    // never changes status text. A failed save returned early above, so
    // it can never prompt.
    unawaited(_maybeRequestReview());
  }

  /// Ask Play for an in-app review, at most once per app version (#37).
  /// Call order is load-bearing: gate check → availability (false = skip
  /// WITHOUT marking, so a later Play install can still prompt) →
  /// request → mark prompted. The whole attempt is a silent no-op on
  /// sideloaded builds: any throw (no Play services, no method-channel
  /// handler in tests) is swallowed — no status change, no _error, no
  /// crash, captions unaffected. The version is read once per attempt
  /// here, never cached across attempts; only the version string is
  /// compared, never the build number.
  Future<void> _maybeRequestReview() async {
    try {
      final currentVersion =
          widget.appVersion ?? (await PackageInfo.fromPlatform()).version;
      if (!await _reviewGate.shouldPrompt(currentVersion)) return;
      if (!await _reviewPrompt.isAvailable()) return;
      await _reviewPrompt.requestReview();
      await _reviewGate.markPrompted(currentVersion);
    } catch (_) {
      // Sideloaded / no-Play: silent no-op (see above).
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
      Analytics.shareDone(captionsOn: _captions);
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

  /// Generate the last-video thumbnail bytes (issue #50): a real frame
  /// at 500 ms, JPEG, max width 128, quality 75 — extracted natively
  /// through the `dual_cameras_example/thumbnail` channel (Android
  /// MediaMetadataRetriever, iOS AVAssetImageGenerator). Fire-and-forget
  /// from _stop(); never throws. Second half of the N8 stale-frame guard:
  /// only write the bytes when the path is still the last video, so a
  /// slow generation from a previous recording (or one that completed
  /// after Delete) can never overwrite the current frame.
  Future<void> _generateLastVideoThumb(String path) async {
    try {
      final bytes = await _thumbnailChannel.invokeMethod<Uint8List>(
        'videoThumbnail',
        {'path': path, 'maxWidth': 128, 'quality': 75, 'timeMs': 500},
      );
      if (bytes == null || _lastVideo != path) return;
      _update(() => _lastVideoThumb = bytes);
    } catch (_) {
      // Thumbnail failure is invisible by design: the tile falls back
      // to the video-icon placeholder and the menu still opens.
    }
  }

  /// Last-video popup menu (issue #50): Open / Delete / Share on
  /// Android, Open / Delete on iOS (Share hidden, §6). Anchored at the
  /// thumbnail: the tile passes its own rect (see _anchorRect in
  /// story_camera.dart). Dismiss on outside tap or Back changes nothing.
  void _showLastVideoMenu(RelativeRect anchor) {
    final path = _lastVideo;
    if (path == null) return;
    showMenu<String>(
      context: context,
      position: anchor,
      items: [
        const PopupMenuItem<String>(
          key: Key('last-video-menu-open'),
          value: 'open',
          child: Text('Open'),
        ),
        const PopupMenuItem<String>(
          key: Key('last-video-menu-delete'),
          value: 'delete',
          child: Text('Delete'),
        ),
        if (!Platform.isIOS)
          const PopupMenuItem<String>(
            key: Key('last-video-menu-share'),
            value: 'share',
            child: Text('Share'),
          ),
      ],
    ).then((value) {
      if (!mounted || value == null) return;
      switch (value) {
        case 'open':
          unawaited(_openLastVideo());
        case 'delete':
          unawaited(_deleteLastVideo());
        case 'share':
          unawaited(_shareVideo());
      }
    });
  }

  /// Open the last video in the in-app player (issue #50): the original
  /// uncaptioned file, same as Share attaches. The controller is created
  /// and initialized here so an initialize() failure surfaces as status
  /// + _error (same failure pattern as _shareVideo) and no player route
  /// opens; the initialized controller is handed to the player page,
  /// which autoplays and owns disposal on pop.
  Future<void> _openLastVideo() async {
    final path = _lastVideo;
    if (path == null) return;
    if (!File(path).existsSync()) {
      // File deleted / moved after save: hide the tile, say so plainly.
      _update(() {
        _lastVideo = null;
        _lastVideoThumb = null;
        _status = 'Video no longer available. Record again.';
      });
      return;
    }
    final controller = VideoPlayerController.file(File(path));
    try {
      await controller.initialize();
    } catch (e) {
      // Never await dispose() here: video_player completes its creation
      // gate only after create() returns, so when initialize() threw at
      // create the dispose() future never completes — awaiting it would
      // hang this flow and the status below would never be set. No
      // native player exists in that case; when initialize() threw
      // after create, the dropped dispose still runs and cleans up.
      unawaited(controller.dispose().catchError((_) {}));
      _update(() {
        _status = 'Could not play video. See settings for details.';
        _error = '$e';
      });
      return;
    }
    if (!mounted) {
      await controller.dispose();
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LastVideoPlayerPage(controller: controller),
      ),
    );
  }

  /// Delete the last video (issue #50): the cache file, the gallery copy
  /// Gal saved, and the captioned twin when it derives from this
  /// recording. Stops any in-flight caption job for the file FIRST —
  /// foreground generation bump, background retained-id cancel through
  /// _jobAction (never a raw _jobs.cancel: the caption_jobs channel has
  /// no native handler, so a raw cancel would throw MissingPluginException
  /// and Delete would fail on the cancel instead of deleting).
  ///
  /// N11 narrow race (recorded, not fixed — see the PR): if Delete lands
  /// while the twin's Gal.putVideo(captioned) is in flight, the twin's
  /// gallery row is created after Delete's DISPLAY_NAME lookup, so one
  /// orphaned, user-deletable gallery copy can survive Delete even though
  /// the :1208 check prevents _captionedFile from being set. A sweep
  /// would need the twin's path, which is native-assigned and unknowable
  /// to Delete in that window (burnCaptions returns it to the job, not
  /// to the state); the window is the putVideo await (milliseconds), with
  /// no crash, no error, no thumbnail resurrection.
  Future<void> _deleteLastVideo() async {
    final path = _lastVideo;
    if (path == null) return;
    _stopCaptionJob();
    final jobId = _lastBackgroundJobId;
    if (jobId != null) {
      _lastBackgroundJobId = null;
      await _jobAction(jobId, () => _jobs.cancel(jobId));
    }
    final twin = _captionedFile != null && _captionSourceFile == path
        ? _captionedFile
        : null;
    // Issue #56: route on the target platform, not the host OS, so a
    // widget test can drive the iOS leg via debugDefaultTargetPlatformOverride
    // — identical on real devices, where the two always agree.
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _deleteLastVideoIos(path, twin);
      return;
    }
    await _deleteLastVideoAndroid(path, twin);
  }

  /// Android Delete (issue #50): one `deleteVideo` channel call per file
  /// (original, then the captioned twin when it derives from the same
  /// recording). The native side deletes the gallery row first and the
  /// cache file after it — so a user-cancelled system confirmation
  /// deletes nothing — and reports what each step did; the status names
  /// what survived on a partial failure. The thumbnail shows the
  /// original, so it goes away once the original is gone — even when the
  /// captioned twin survives a cancelled twin delete (the status then
  /// names the twin that was kept, never 'Video kept.').
  Future<void> _deleteLastVideoAndroid(String path, String? twin) async {
    final results = <_DeleteResult>[];
    for (final target in [path, if (twin != null) twin]) {
      final result = await _deleteVideoNative(target);
      if (result == null || result.cancelled) {
        if (results.isEmpty) {
          // Nothing was deleted yet (gallery-first order on the first
          // file): keep the video and the thumbnail. A channel error
          // already set its own status in _deleteVideoNative.
          if (result != null) _update(() => _status = 'Video kept.');
          return;
        }
        // The original is already gone and only the captioned twin
        // survives: never claim the video is kept. Name what survived
        // and drop the thumbnail — it shows a deleted file.
        _update(() {
          _lastVideo = null;
          _lastVideoThumb = null;
          _status = 'Video deleted, captioned copy kept.';
        });
        return;
      }
      results.add(result);
    }
    final cacheKept = results.any((r) => !r.cacheDeleted);
    final galleryKept = results.any((r) => !r.galleryDeleted);
    if (!cacheKept && !galleryKept) {
      _update(() {
        _lastVideo = null;
        _lastVideoThumb = null;
        _lastFile = null;
        _captionedFile = null;
        _captionSourceFile = null;
        _status = 'Video deleted.';
      });
      return;
    }
    if (cacheKept && galleryKept) {
      _update(() {
        _status = 'Could not delete video. See settings for details.';
        _error = 'Delete failed for the file and the gallery copy.';
      });
      return;
    }
    _update(() {
      _error = 'Delete incomplete: '
          '${cacheKept ? 'file kept' : 'gallery copy kept'}.';
      _status = cacheKept
          ? 'Gallery copy deleted, file kept.'
          : 'Video deleted from StoryCam, gallery copy kept.';
    });
  }

  /// iOS Delete (issue #50, §6): Dart File.delete on the cache files —
  /// the original plus the captioned twin's cache file when it derives
  /// from the same recording. No Swift handler, no channel call. The
  /// Photos copy is NOT deleted in v1 (PHAssetChangeRequest is possible
  /// with authorization, but it is not built in v1) — it stays in Photos.
  /// Issue #56: track whether anything was already deleted, not just
  /// whether anything failed — the iOS analog of Android's
  /// `results.isEmpty` test in _deleteLastVideoAndroid. If the twin's
  /// delete throws after the original is gone, the status must not claim
  /// total failure: the thumbnail shows the deleted original, so it goes
  /// away, and the kept twin's bookkeeping stays (same two-field clear
  /// as the Android F2 leg).
  Future<void> _deleteLastVideoIos(String path, String? twin) async {
    var deletedAny = false;
    var failed = false;
    for (final target in [path, if (twin != null) twin]) {
      try {
        final file = File(target);
        if (await file.exists()) {
          await _deleteFile(file);
          deletedAny = true;
        }
      } catch (e) {
        failed = true;
        _update(() {
          _status = 'Could not delete video. See settings for details.';
          _error = '$e';
        });
      }
    }
    if (failed) {
      if (!deletedAny) return;
      // The original is already gone and only the captioned twin
      // survives: never claim the video is kept. Name what survived
      // and drop the thumbnail — it shows a deleted file. _error keeps
      // naming the twin failure from the catch above.
      _update(() {
        _lastVideo = null;
        _lastVideoThumb = null;
        _status = 'Video deleted, captioned copy kept.';
      });
      return;
    }
    _update(() {
      _lastVideo = null;
      _lastVideoThumb = null;
      _lastFile = null;
      _captionedFile = null;
      _captionSourceFile = null;
      _status = 'Video deleted from StoryCam.';
    });
  }

  /// One native `deleteVideo` call. Returns null on a channel error (the
  /// status is set here, same failure pattern as _shareVideo); otherwise
  /// the map reports per-copy results — see ShareChannel.deleteVideo.
  Future<_DeleteResult?> _deleteVideoNative(String target) async {
    try {
      final reply = await _shareChannel.invokeMethod<Map<Object?, Object?>>(
          'deleteVideo', {'path': target});
      if (reply == null) throw StateError('deleteVideo returned null');
      return _DeleteResult(
        cacheDeleted: reply['cacheDeleted'] == true,
        galleryDeleted: reply['galleryDeleted'] == true,
        cancelled: reply['cancelled'] == true,
      );
    } catch (e) {
      _update(() {
        _status = 'Could not delete video. See settings for details.';
        _error = '$e';
      });
      return null;
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
      // Background jobs emit the same event with job='background' from
      // runCaptionJob (the caption isolate initializes analytics itself).
      Analytics.captionsDone(
          wordCount: words.length,
          language: result.detectedLanguage,
          captionLanguage: _captionLanguage.code);
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
    _mapCaptureTimer?.cancel();
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
                    // Issue #49 spike: track sample on every map toggle.
                    _mapRecordToggle(v);
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
          // Map zoom (issue #47, D5): the same value the pinch writes.
          // Live on drag (state-only _update), saved on release
          // (_updateSettings) — the one sanctioned exception to D1.
          Text('Map zoom ${_settings.mapZoom.toStringAsFixed(1)}'),
          const Text('How close the map looks',
              style: TextStyle(fontSize: 12)),
          Slider(
            key: const Key('map-zoom-slider'),
            min: CameraSettings.minMapZoom,
            max: CameraSettings.maxMapZoom,
            divisions: 12,
            label: _settings.mapZoom.toStringAsFixed(1),
            value: _settings.mapZoom,
            onChanged: (v) =>
                _update(() => _settings = _settings.copyWith(mapZoom: v)),
            onChangeEnd: (v) =>
                _updateSettings(_settings.copyWith(mapZoom: v)),
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
                    // _setVideoQuality is itself _guard-wrapped: wrapping
                    // it in another _guard here would set _busy first and
                    // make the inner guard return immediately (silent
                    // no-op, issue #20 fix round 2 / I1).
                    : (_) =>
                        _setVideoQuality(DualResolution.hd1080),
              ),
              ChoiceChip(
                label: const Text('4K'),
                selected: _settings.videoQuality ==
                    DualResolution.ultraHd2160,
                onSelected: _busy || value.isRecording || !_supports4k
                    ? null
                    // Same as 1080p above: no outer _guard (I1).
                    : (_) => _setVideoQuality(
                        DualResolution.ultraHd2160),
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
                // Stable key (issue #20 fix round 2 / I5): the _busy
                // indicator above is inserted/removed from this
                // ListView's children, which shifts every unkeyed child
                // below it and remounts this tile collapsed mid-drag.
                // Keyed, its expanded state survives the shift.
                key: const ValueKey('exposure-tile'),
                tilePadding: EdgeInsets.zero,
                title: const Text('Exposure'),
                subtitle: Text(_evLabel(_ev)),
                children: [IgnorePointer(ignoring: _busy, child: _evRow())],
              ),
          ],
          ExpansionTile(
            // Stable key, same hazard as the Exposure tile above (I5):
            // an unkeyed tile below the _busy indicator would remount
            // collapsed when the indicator is inserted or removed.
            key: const ValueKey('session-details-tile'),
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
            // Stable key, same hazard as the Exposure tile (I5, issue
            // #25): the _busy indicator above is inserted/removed from
            // this ListView's children, which shifts every unkeyed child
            // below it and remounts it collapsed. The key must sit on
            // this IgnorePointer — the direct ListView child — not on
            // the ExpansionTile inside _debugPanel(): the wrapper is
            // what shifts, so a key on the tile alone does not survive
            // the shift (verified: the re-query test fails with only
            // the tile keyed). Keyed, the tile's expanded state survives.
            IgnorePointer(
                key: const ValueKey('debug-tuning-panel'),
                ignoring: _busy,
                child: _debugPanel()),
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
        // Issue #49 spike: start the 2 fps map snapshot tick.
        unawaited(_mapStartCapture());
        Analytics.recordStarted(
            captionsOn: _captions, captionLanguage: _captionLanguage.code);
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
          // Issue #49 spike: wrapped in a RepaintBoundary (stable State
          // key, N-H) so the 2 fps snapshot tick can capture it.
          mapCircle: _settings.mapVisible && _locationGranted
              ? RepaintBoundary(
                  key: _mapBoundaryKey,
                  child: MapCircle(
                    position: _position,
                    headingDeg: _heading,
                    mode: _settings.compassMode,
                    zoom: _settings.mapZoom,
                    placeName: _placeName,
                    onZoomChanged: (z) =>
                        _updateSettings(_settings.copyWith(mapZoom: z)),
                    // No tile fetches under `flutter test` (hermetic; the
                    // disc + dot + N arrow still render).
                    showTiles: Platform.environment['FLUTTER_TEST'] != 'true',
                  ),
                )
              : null,
          // Lens pills (issue #20): only the active camera's probed
          // lenses; hidden before init (nothing probed yet). The pills
          // stay enabled while busy (issue #48): a tap that lands
          // mid-command queues instead of vanishing silently.
          lensPills: value.isInitialized
              ? LensPills(
                  lenses:
                      _primaryFront ? _lensesFront : _lensesRear,
                  selectedRatio: (_primaryFront
                          ? _settings.frontLens
                          : _settings.rearLens) ??
                      1.0,
                  onSelected: _setLens,
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
          // Last-video thumbnail (issue #50): only once a video is saved
          // and no command is in flight — hidden before any recording,
          // while recording, and while _busy (e.g. Gal.putVideo still in
          // flight in _stop). Appears on the rebuild after _perform's
          // finally clears _busy. Tapping it opens the Open / Delete /
          // Share menu (_showLastVideoMenu); _shareVideo stays — it is
          // now called from the menu.
          onLastVideoTap: (!_busy && !value.isRecording && _lastVideo != null)
              ? _showLastVideoMenu
              : null,
          lastVideoThumb: _lastVideoThumb,
        );
      },
    );
  }
}

/// One native `deleteVideo` result (issue #50): what the native side
/// deleted for one file. `cancelled` means the user declined the system
/// confirmation — nothing was deleted (the gallery row is deleted before
/// the cache file, so a cancel lands before any delete).
class _DeleteResult {
  const _DeleteResult({
    required this.cacheDeleted,
    required this.galleryDeleted,
    required this.cancelled,
  });

  final bool cacheDeleted;
  final bool galleryDeleted;
  final bool cancelled;
}
