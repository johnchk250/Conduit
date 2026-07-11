import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Thin wrapper around [FlutterLocalNotificationsPlugin] for Conduit's
/// ad-hoc file-send notifications (Roadmap Phase 3b).
///
/// ## Platform Compatibility & Engine Safety
/// Under Dart SDK 3.6.0, [flutter_local_notifications] 18.0.1 is used. Since
/// version 18.0.1 does not include Windows support natively, this class is
/// platform-gated to run only on Android. This avoids any compiler errors
/// due to missing ATL build tool components (`atlbase.h`) on Windows machines.
///
/// On Windows, notifications are displayed in-app (Snackbar/Activity) and the
/// system notification calls here are safe, compile-time clean no-ops.
class AppNotifier {
  AppNotifier();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  // Android notification channel for file transfer events.
  static const _androidChannelId = 'conduit_transfers';
  static const _androidChannelName = 'File Transfers';
  static const _androidChannelDesc =
      'Notifications for ad-hoc file send and receive';

  /// Initialise the plugin and request permissions on Android.
  ///
  /// Safe to call multiple times — subsequent calls are no-ops once [_ready].
  /// Errors are swallowed: a notification failure must never block sync.
  Future<void> init() async {
    if (!Platform.isAndroid) return;
    if (_ready) return;
    try {
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const initSettings = InitializationSettings(
        android: androidInit,
      );
      await _plugin.initialize(initSettings);

      // Android: create the notification channel (idempotent on re-init).
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          _androidChannelId,
          _androidChannelName,
          description: _androidChannelDesc,
          importance: Importance.high,
        ),
      );
      // Request POST_NOTIFICATIONS permission (Android 13+). Best-effort.
      await android?.requestNotificationsPermission();
      _ready = true;
    } catch (_) {
      // Best-effort: if notifications aren't available (e.g. in tests or a
      // stripped platform build), just mark not-ready and skip all shows.
    }
  }

  /// Show progress for receiving a file.
  Future<void> showReceiveProgress(String name, int received, int total) async {
    if (!Platform.isAndroid || !_ready) return;
    try {
      final percent = total > 0 ? (received * 100) ~/ total : 0;
      final androidDetails = AndroidNotificationDetails(
        _androidChannelId,
        _androidChannelName,
        channelDescription: _androidChannelDesc,
        importance: Importance
            .low, // low importance so it doesn't alert/sound on every update
        priority: Priority.low,
        showProgress: true,
        maxProgress: 100,
        progress: percent,
        icon: '@mipmap/ic_launcher',
        onlyAlertOnce: true,
      );
      final details = NotificationDetails(android: androidDetails);
      await _plugin.show(
        name.hashCode ^ 3,
        'Receiving file',
        '$name ($percent%)',
        details,
      );
    } catch (_) {}
  }

  /// Show progress for sending a file.
  Future<void> showSendProgress(String name, int sent, int total) async {
    if (!Platform.isAndroid || !_ready) return;
    try {
      final percent = total > 0 ? (sent * 100) ~/ total : 0;
      final androidDetails = AndroidNotificationDetails(
        _androidChannelId,
        _androidChannelName,
        channelDescription: _androidChannelDesc,
        importance: Importance
            .low, // low importance so it doesn't alert/sound on every update
        priority: Priority.low,
        showProgress: true,
        maxProgress: 100,
        progress: percent,
        icon: '@mipmap/ic_launcher',
        onlyAlertOnce: true,
      );
      final details = NotificationDetails(android: androidDetails);
      await _plugin.show(
        name.hashCode ^ 4,
        'Sending file',
        '$name ($percent%)',
        details,
      );
    } catch (_) {}
  }

  /// Show a "File sent" system notification. Fires after a successful send.
  ///
  /// [name] is the file name (no path). [peerName] is the connected peer's
  /// display name. Best-effort — swallows errors.
  Future<void> showFileSent(String name, String peerName) async {
    try {
      if (Platform.isAndroid && _ready) {
        await _plugin.cancel(name.hashCode ^ 4);
      }
    } catch (_) {}
    await _show(
      id: name.hashCode ^ 1,
      title: 'File sent',
      body: '$name → $peerName',
    );
  }

  /// Show a "File received" system notification. Fires after a successful
  /// receive. [name] is the file name; [peerName] the sender's display name.
  Future<void> showFileReceived(String name, String peerName) async {
    try {
      if (Platform.isAndroid && _ready) {
        await _plugin.cancel(name.hashCode ^ 3);
      }
    } catch (_) {}
    await _show(
      id: name.hashCode ^ 2,
      title: 'File received',
      body: '$name ← $peerName',
    );
  }

  /// Show a "Clipboard pending" notification.
  ///
  /// Only fired when the clipboard write genuinely failed (i.e.
  /// `ClipboardSync.pendingRemoteText` is still non-null after the attempt
  /// because the write call itself threw — see `ClipboardSync.onPushReceived`
  /// doc, 2026-07-11). A successful write, foreground or backgrounded, never
  /// shows this notification.
  ///
  /// The notification auto-dismisses after 10 s so it never lingers — the
  /// user either taps it to open the app and paste, or it disappears on its own.
  Future<void> showClipboardSyncReceived(String preview, String peerName) async {
    if (!Platform.isAndroid || !_ready) return;
    try {
      final androidDetails = AndroidNotificationDetails(
        _androidChannelId,
        _androidChannelName,
        channelDescription: _androidChannelDesc,
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        icon: '@mipmap/ic_launcher',
        onlyAlertOnce: true,
        // Auto-dismiss after 10 seconds — clipboard notifications are transient.
        timeoutAfter: 10000,
      );
      await _plugin.show(
        9999,
        'Clipboard ready to paste',
        'From ${peerName.isEmpty ? "PC" : peerName}: "$preview" — open app to paste',
        NotificationDetails(android: androidDetails),
      );
    } catch (_) {}
  }

  Future<void> _show({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!Platform.isAndroid) return;
    if (!_ready) return;
    try {
      const androidDetails = AndroidNotificationDetails(
        _androidChannelId,
        _androidChannelName,
        channelDescription: _androidChannelDesc,
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
      );
      const details = NotificationDetails(
        android: androidDetails,
      );
      await _plugin.show(id, title, body, details);
    } catch (_) {
      // Swallow — a notification failure must never break a transfer.
    }
  }
}
