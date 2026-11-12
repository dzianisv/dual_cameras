import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_center.dart';

/// Reports caption-model download progress through a system notification
/// (v0.5.2: Den asked for the download status to live in the notification
/// shade, not as a banner on top of the camera screen; v0.5.3: the progress
/// notification carries a Stop button that really cancels the download).
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

  /// The user stopped the download: clear the progress notification. No
  /// failure UI — the Captions sheet offers retry.
  Future<void> showStopped();

  /// The download failed: show a persistent notification; the retry lives
  /// in the Captions sheet / settings, not in the notification.
  Future<void> showFailed(String error);

  /// Called when the user taps Stop on the progress notification. The
  /// handler must really cancel the in-flight download (not just dismiss
  /// the notification). Set by the screen that owns the download.
  set onStop(void Function()? value);
}

/// System notification implementation (Android notification shade).
class SystemModelDownloadNotifier implements ModelDownloadNotifier {
  SystemModelDownloadNotifier({NotificationCenter? center})
      : _center = center ?? NotificationCenter();

  static const _notificationId = 1001;
  static const _channelId = 'storycam_model_download';
  static const _channelName = 'Caption model download';
  static const _channelDescription =
      'Progress while the on-device caption model downloads.';

  /// Action id of the Stop button on the progress notification.
  static const stopActionId = 'stop_model_download';

  final NotificationCenter _center;
  @override
  set onStop(void Function()? value) {
    if (value != null) {
      _center.registerAction(stopActionId, value);
    } else {
      _center.unregisterAction(stopActionId);
    }
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
          actions: const [
            AndroidNotificationAction(
              stopActionId,
              'Stop',
              // Brings the app forward so the tap reaches the main isolate,
              // where the ModelManager lives. A background-isolate callback
              // could not cancel the download. Android dismisses the
              // notification on tap; the abort then clears/replaces it
              // deterministically.
              showsUserInterface: true,
              cancelNotification: true,
            ),
          ],
        ),
      );

  @override
  Future<void> showProgress(double progress) async {
    if (progress >= 1) return showReady();
    if (progress <= 0) return;
    await _center.show(
      _notificationId,
      'Downloading caption model',
      '${(progress * 100).floor()}% · on device',
      _progressDetails((progress * 100).floor()),
    );
  }

  @override
  Future<void> showReady() async {
    await _center.cancel(_notificationId);
  }

  @override
  Future<void> showStopped() async {
    await _center.cancel(_notificationId);
  }

  @override
  Future<void> showFailed(String error) async {
    await _center.show(
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
  }
}
