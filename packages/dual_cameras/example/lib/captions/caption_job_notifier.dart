import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_center.dart';

/// Stages of the foreground caption pipeline, in order. The notification
/// maps each stage to a band of the overall progress bar.
enum CaptionStage { extracting, preparingModel, transcribing, burning }

/// Reports foreground caption processing through a system notification
/// (v0.5.3: Den asked for the caption-adding moment to live in the
/// notification shade with a progress bar and a Stop button, like the model
/// download — not as in-app status text, which does not look native).
///
/// Implementations must never throw: a notification failure must not break
/// captioning or capture.
abstract class CaptionJobNotifier {
  /// A caption job is in flight: [stage] with [stageProgress] (0..1 within
  /// the stage). Called at most once per whole percent by the caller.
  Future<void> showProgress(CaptionStage stage, double stageProgress);

  /// Captions were added: [words] words, [language] detected ('' if
  /// unknown). Replaces the progress notification.
  Future<void> showDone(int words, String language);

  /// No speech was detected: the original video is kept. Replaces the
  /// progress notification.
  Future<void> showNoSpeech();

  /// Captioning failed: the original video is kept. The error lives in
  /// settings; the retry lives in the Captions sheet.
  Future<void> showFailed(String error);

  /// Clear the progress notification (job stopped by the user, or stale
  /// from a previous app run). No-op when nothing was shown.
  Future<void> clear();

  /// Called when the user taps Stop on the progress notification. The
  /// handler must really cancel the in-flight caption job (not just dismiss
  /// the notification). Set by the screen that owns the job.
  set onStop(void Function()? value);
}

/// System notification implementation (Android notification shade).
class SystemCaptionJobNotifier implements CaptionJobNotifier {
  SystemCaptionJobNotifier({NotificationCenter? center})
      : _center = center ?? NotificationCenter();

  static const _notificationId = 1002;
  static const _channelId = 'storycam_caption_job';
  static const _channelName = 'Adding captions';
  static const _channelDescription =
      'Progress while captions are added to a video.';

  /// Action id of the Stop button on the progress notification.
  static const stopActionId = 'stop_caption_job';

  final NotificationCenter _center;
  @override
  set onStop(void Function()? value) {
    if (value != null) {
      _center.registerAction(stopActionId, value);
    } else {
      _center.unregisterAction(stopActionId);
    }
  }

  static const _stageBase = <CaptionStage, double>{
    CaptionStage.extracting: 0.0,
    CaptionStage.preparingModel: 0.25,
    CaptionStage.transcribing: 0.35,
    CaptionStage.burning: 0.75,
  };
  static const _stageSpan = <CaptionStage, double>{
    CaptionStage.extracting: 0.25,
    CaptionStage.preparingModel: 0.10,
    CaptionStage.transcribing: 0.40,
    CaptionStage.burning: 0.25,
  };
  static const _stageLabel = <CaptionStage, String>{
    CaptionStage.extracting: 'Extracting audio',
    CaptionStage.preparingModel: 'Preparing speech model',
    CaptionStage.transcribing: 'Transcribing on device',
    CaptionStage.burning: 'Adding captions to video',
  };

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
              // where the caption job lives. A background-isolate callback
              // could not cancel the job. Android dismisses the
              // notification on tap; the abort then clears it
              // deterministically.
              showsUserInterface: true,
              cancelNotification: true,
            ),
          ],
        ),
      );

  NotificationDetails _terminalDetails() => const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          ongoing: false,
          autoCancel: true,
        ),
      );

  @override
  Future<void> showProgress(CaptionStage stage, double stageProgress) async {
    final overall = (_stageBase[stage]! +
            _stageSpan[stage]! * stageProgress.clamp(0.0, 1.0))
        .clamp(0.0, 0.99);
    await _center.show(
      _notificationId,
      'Adding captions',
      '${_stageLabel[stage]} · ${(overall * 100).floor()}%',
      _progressDetails((overall * 100).floor()),
    );
  }

  @override
  Future<void> showDone(int words, String language) async {
    await _center.show(
      _notificationId,
      'Captions added',
      '$words word${words == 1 ? '' : 's'}${language.isEmpty ? '' : ' · $language'} — saved to gallery',
      _terminalDetails(),
    );
  }

  @override
  Future<void> showNoSpeech() async {
    await _center.show(
      _notificationId,
      'No speech detected',
      'Original video kept.',
      _terminalDetails(),
    );
  }

  @override
  Future<void> showFailed(String error) async {
    await _center.show(
      _notificationId,
      'Captioning failed',
      'Original video kept. See settings for details.',
      _terminalDetails(),
    );
  }

  @override
  Future<void> clear() async {
    await _center.cancel(_notificationId);
  }
}
