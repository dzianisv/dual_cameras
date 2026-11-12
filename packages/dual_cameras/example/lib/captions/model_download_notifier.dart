import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

/// Reports caption-model download progress through a system notification
/// (v0.5.2: Den asked for the download status to live in the notification
/// shade, not as a banner on top of the camera screen).
///
/// Implementations must never throw: a notification failure must not break
/// the download or the capture flow.
abstract class ModelDownloadNotifier {
  /// A download is in flight at [progress] (0..1). Called at most once per
  /// whole percent by the caller.
  Future<void> showProgress(double progress);

  /// The model is ready (downloaded or already cached): clear any progress
  /// notification. No-op when nothing was shown.
  Future<void> showReady();

  /// The download failed: show a persistent notification; the retry lives
  /// in the Captions sheet / settings, not in the notification.
  Future<void> showFailed(String error);
}

/// System notification implementation (Android notification shade).
class SystemModelDownloadNotifier implements ModelDownloadNotifier {
  SystemModelDownloadNotifier(
      [FlutterLocalNotificationsPlugin? plugin,
      Future<PermissionStatus> Function()? requestNotificationPermission])
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
        _requestNotificationPermission = requestNotificationPermission ??
            Permission.notification.request;

  static const _notificationId = 1001;
  static const _channelId = 'storycam_model_download';
  static const _channelName = 'Caption model download';
  static const _channelDescription =
      'Progress while the on-device caption model downloads.';

  final FlutterLocalNotificationsPlugin _plugin;
  final Future<PermissionStatus> Function() _requestNotificationPermission;
  bool _initialized = false;
  bool _permissionChecked = false;
  bool _permissionGranted = false;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    try {
      await _plugin.initialize(const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ));
    } catch (_) {
      // Notifications are best effort; the Captions sheet still shows state.
    }
    _initialized = true;
  }

  /// Android 13+ needs the runtime notification permission. Asked at most
  /// once per app run, only when a download is actually in flight, so a
  /// cached-model launch never prompts. A denial just means no notification
  /// (the Captions sheet remains the fallback); it never throws.
  Future<bool> _ensurePermission() async {
    if (_permissionChecked) return _permissionGranted;
    _permissionChecked = true;
    try {
      final status = await Permission.notification.status;
      if (status.isGranted) {
        _permissionGranted = true;
      } else {
        _permissionGranted =
            (await _requestNotificationPermission()).isGranted;
      }
    } catch (_) {
      _permissionGranted = false;
    }
    return _permissionGranted;
  }

  NotificationDetails _progressDetails(int percent) => NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          autoCancel: false,
          onlyAlertOnce: true,
          showProgress: true,
          maxProgress: 100,
          progress: percent,
        ),
      );

  @override
  Future<void> showProgress(double progress) async {
    if (progress >= 1) return showReady();
    if (progress <= 0) return;
    try {
      await _ensureInitialized();
      if (!await _ensurePermission()) return;
      await _plugin.show(
        _notificationId,
        'Downloading caption model',
        '${(progress * 100).floor()}% · on device',
        _progressDetails((progress * 100).floor()),
      );
    } catch (_) {
      // Best effort only.
    }
  }

  @override
  Future<void> showReady() async {
    try {
      await _ensureInitialized();
      await _plugin.cancel(_notificationId);
    } catch (_) {
      // Best effort only.
    }
  }

  @override
  Future<void> showFailed(String error) async {
    try {
      await _ensureInitialized();
      if (!await _ensurePermission()) return;
      await _plugin.show(
        _notificationId,
        'Caption model download failed',
        'Captions will keep the original video. Open Captions to retry.',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDescription,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            ongoing: false,
            autoCancel: true,
          ),
        ),
      );
    } catch (_) {
      // Best effort only.
    }
  }
}
