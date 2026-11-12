import 'package:dual_cameras_example/captions/caption_job_notifier.dart';
import 'package:dual_cameras_example/captions/model_download_notifier.dart';
import 'package:dual_cameras_example/captions/notification_center.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

class _Shown {
  _Shown(this.id, this.title, this.body, this.details);
  final int id;
  final String? title;
  final String? body;
  final NotificationDetails details;
}

/// Stand-in for the real plugin: records initialize/show/cancel and lets a
/// test simulate the user tapping a notification action.
class _FakePlugin extends Fake implements FlutterLocalNotificationsPlugin {
  DidReceiveNotificationResponseCallback? responseCallback;
  final List<_Shown> shown = [];
  final List<int> cancelled = [];
  bool fail = false;

  @override
  Future<bool?> initialize(InitializationSettings initializationSettings,
      {DidReceiveNotificationResponseCallback?
          onDidReceiveNotificationResponse,
      DidReceiveBackgroundNotificationResponseCallback?
          onDidReceiveBackgroundNotificationResponse}) async {
    if (fail) throw Exception('no plugin');
    responseCallback = onDidReceiveNotificationResponse;
    return true;
  }

  @override
  Future<void> show(int id, String? title, String? body,
      NotificationDetails? notificationDetails,
      {String? payload}) async {
    if (fail) throw Exception('no plugin');
    shown.add(_Shown(id, title, body, notificationDetails!));
  }

  @override
  Future<void> cancel(int id, {String? tag}) async {
    if (fail) throw Exception('no plugin');
    cancelled.add(id);
  }

  @override
  Future<NotificationAppLaunchDetails?>
      getNotificationAppLaunchDetails() async {
    if (fail) throw Exception('no plugin');
    return null;
  }

  void simulateTap(int id, String actionId) {
    responseCallback?.call(NotificationResponse(
      notificationResponseType:
          NotificationResponseType.selectedNotificationAction,
      id: id,
      actionId: actionId,
    ));
  }
}

void main() {
  // The center's default permission check hits the real permission_handler
  // channel, which has no mock in a plain unit test (it would deny every
  // show). Inject a granted answer so show() reaches the fake plugin.
  NotificationCenter centerFor(_FakePlugin plugin) => NotificationCenter(
        plugin: plugin,
        checkPermission: () async => PermissionStatus.granted,
        requestPermission: () async => PermissionStatus.granted,
      );

  group('NotificationCenter', () {
    late _FakePlugin plugin;
    late NotificationCenter center;

    setUp(() {
      plugin = _FakePlugin();
      center = centerFor(plugin);
    });

    test('dispatches a registered stop tap to its handler', () async {
      var stops = 0;
      center.registerAction('stop_model_download', () => stops++);
      await center.show(
          1001, 'Downloading', '50%', const NotificationDetails());
      expect(plugin.shown, hasLength(1));
      plugin.simulateTap(1001, 'stop_model_download');
      expect(stops, 1);
    });

    test('ignores taps on unregistered action ids', () async {
      var stops = 0;
      center.registerAction('stop', () => stops++);
      await center.show(
          1001, 'Downloading', '50%', const NotificationDetails());
      plugin.simulateTap(1001, 'something-else');
      expect(stops, 0);
    });

    test('unregistered actions stop dispatching', () async {
      var stops = 0;
      center.registerAction('stop', () => stops++);
      await center.show(
          1001, 'Downloading', '50%', const NotificationDetails());
      center.unregisterAction('stop');
      plugin.simulateTap(1001, 'stop');
      expect(stops, 0);
    });

    test('never throws when the plugin is unavailable', () async {
      plugin.fail = true;
      var stops = 0;
      center.registerAction('stop', () => stops++);
      await center.show(
          1001, 'Downloading', '50%', const NotificationDetails());
      await center.cancel(1001);
      plugin.simulateTap(1001, 'stop');
      expect(stops, 0);
    });
  });

  group('SystemModelDownloadNotifier', () {
    late _FakePlugin plugin;
    late SystemModelDownloadNotifier notifier;

    setUp(() {
      plugin = _FakePlugin();
      notifier = SystemModelDownloadNotifier(center: centerFor(plugin));
    });

    test('progress notification carries a Stop action', () async {
      await notifier.showProgress(.5);
      final shown = plugin.shown.single;
      expect(shown.id, 1001);
      final android = shown.details.android!;
      expect(android.maxProgress, 100);
      expect(android.progress, 50);
      expect(android.showProgress, isTrue);
      expect(android.onlyAlertOnce, isTrue);
      expect(android.actions, hasLength(1));
      final action = android.actions!.single;
      expect(action.id, 'stop_model_download');
      expect(action.title, 'Stop');
      // The tap must reach the main isolate (which owns the download), so
      // it brings the app forward instead of a background isolate.
      expect(action.showsUserInterface, isTrue);
    });

    test('tapping Stop reaches the notifier handler', () async {
      var stops = 0;
      notifier.onStop = () => stops++;
      await notifier.showProgress(.5);
      plugin.simulateTap(1001, 'stop_model_download');
      expect(stops, 1);
    });

    test('showStopped clears the progress notification', () async {
      await notifier.showProgress(.5);
      await notifier.showStopped();
      expect(plugin.cancelled, contains(1001));
    });
  });

  group('SystemCaptionJobNotifier', () {
    late _FakePlugin plugin;
    late SystemCaptionJobNotifier notifier;

    setUp(() {
      plugin = _FakePlugin();
      notifier = SystemCaptionJobNotifier(center: centerFor(plugin));
    });

    test('progress notification carries a Stop action and stage bands',
        () async {
      await notifier.showProgress(CaptionStage.transcribing, .5);
      final shown = plugin.shown.single;
      expect(shown.id, 1002);
      final android = shown.details.android!;
      expect(android.actions, hasLength(1));
      final action = android.actions!.single;
      expect(action.id, 'stop_caption_job');
      expect(action.title, 'Stop');
      expect(action.showsUserInterface, isTrue);
      // Transcribing band is 0.35–0.75: 50% through it is 55% overall.
      expect(android.maxProgress, 100);
      expect(android.progress, 55);
      expect(android.showProgress, isTrue);
      expect(android.onlyAlertOnce, isTrue);
    });

    test('tapping Stop reaches the notifier handler', () async {
      var stops = 0;
      notifier.onStop = () => stops++;
      await notifier.showProgress(CaptionStage.extracting, 0);
      plugin.simulateTap(1002, 'stop_caption_job');
      expect(stops, 1);
    });

    test('done replaces the progress notification and reports the result',
        () async {
      await notifier.showProgress(CaptionStage.burning, .9);
      await notifier.showDone(12, 'ru');
      // Same notification id: the terminal notification replaces the
      // progress one (no cancel — cancelling first would flash it away).
      expect(plugin.shown, hasLength(2));
      expect(plugin.shown.last.title, contains('Captions added'));
      expect(plugin.shown.last.body, contains('12 words'));
      expect(plugin.shown.last.body, contains('ru'));
    });

    test('no-speech and failed replace the progress notification', () async {
      await notifier.showProgress(CaptionStage.transcribing, .5);
      await notifier.showNoSpeech();
      expect(plugin.shown, hasLength(2));
      expect(plugin.shown.last.body, contains('No speech detected'));
      await notifier.showProgress(CaptionStage.transcribing, .5);
      await notifier.showFailed('boom');
      expect(plugin.shown, hasLength(4));
      expect(plugin.shown.last.body, contains('Original video kept'));
    });
  });
}
