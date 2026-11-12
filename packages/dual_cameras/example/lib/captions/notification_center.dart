import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

/// Owns the app's single flutter_local_notifications plugin instance and
/// routes notification-action taps to the handler registered for the action
/// id (v0.5.3).
///
/// One plugin instance, one `initialize` call: every `initialize` replaces
/// the response callback, so two notifiers initializing separately would
/// steal each other's Stop taps. Every notification in the app goes through
/// this center. Never throws: a notification failure must not break the
/// download or the capture flow.
class NotificationCenter {
  NotificationCenter({
    FlutterLocalNotificationsPlugin? plugin,
    Future<PermissionStatus> Function()? checkPermission,
    Future<PermissionStatus> Function()? requestPermission,
  })  : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
        _checkPermission =
            checkPermission ?? (() => Permission.notification.status),
        _requestPermission =
            requestPermission ?? Permission.notification.request;

  final FlutterLocalNotificationsPlugin _plugin;
  final Future<PermissionStatus> Function() _checkPermission;
  final Future<PermissionStatus> Function() _requestPermission;
  bool _initialized = false;
  bool _permissionChecked = false;
  bool _permissionGranted = false;
  final Map<String, void Function()> _actions = {};

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    try {
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
        ),
        // The Stop actions use `showsUserInterface: true`, so a tap brings
        // the app forward and the response reaches this callback on the
        // main isolate — where the ModelManager and the caption job live.
        // A background-isolate callback could not reach them.
        onDidReceiveNotificationResponse: _onResponse,
      );
    } catch (_) {
      // Best effort only.
    }
  }

  void _onResponse(NotificationResponse response) {
    final handler = _actions[response.actionId];
    if (handler != null) handler();
  }

  /// Register the handler for a notification-action id. Replaces any
  /// previous handler for the id.
  void registerAction(String actionId, void Function() handler) {
    _actions[actionId] = handler;
  }

  void unregisterAction(String actionId) {
    _actions.remove(actionId);
  }

  /// Android 13+ runtime notification permission, asked at most once per
  /// app run. A denial just means no notification; it never throws.
  Future<bool> ensurePermission() async {
    if (_permissionChecked) return _permissionGranted;
    _permissionChecked = true;
    try {
      final status = await _checkPermission();
      if (status.isGranted) {
        _permissionGranted = true;
      } else {
        _permissionGranted = (await _requestPermission()).isGranted;
      }
    } catch (_) {
      _permissionGranted = false;
    }
    return _permissionGranted;
  }

  Future<void> show(
      int id, String title, String body, NotificationDetails details) async {
    try {
      await _ensureInitialized();
      if (!await ensurePermission()) return;
      await _plugin.show(id, title, body, details);
    } catch (_) {
      // Best effort only.
    }
  }

  Future<void> cancel(int id) async {
    try {
      await _ensureInitialized();
      await _plugin.cancel(id);
    } catch (_) {
      // Best effort only.
    }
  }

  @visibleForTesting
  void simulateActionTap(String actionId) {
    final handler = _actions[actionId];
    if (handler != null) handler();
  }
}
