import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../diag.dart';

/// Background notification response handler. Runs on a background isolate
/// when showsUserInterface is false, forwarding the response back to the main isolate
/// via the registered SendPort.
///
/// TEMP diagnostic logging (2026-07-14): the cancel-button report ("nothing
/// happens") could break at several points — the tap never reaching this
/// background isolate at all, the port lookup failing, or the main isolate
/// never getting the forwarded message. These Diag.log calls (always-on,
/// visible in `flutter run`/logcat as `[Conduit][diag]` lines) make it
/// possible to tell which. Safe to leave in permanently or strip once the
/// cause is confirmed — remove this comment block when that happens.
@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) {
  final sendPort = IsolateNameServer.lookupPortByName('conduit_notification_port');
  Diag.log('notif_tap_background', fields: {
    'actionId': response.actionId,
    'responseType': response.notificationResponseType.toString(),
    'hasPayload': response.payload != null,
    'portFound': sendPort != null,
  });
  sendPort?.send(response);
}

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

  // Notification ID range reserved for "file received" completions. The IDs
  // are derived from `name.hashCode ^ 2` and are never used by any other show.
  // The payload encodes `treeUri\nrelPath` so [onFileNotificationTap] can open
  // the file directly. SAF tree URIs are `content://…` strings — no newlines.

  /// Called when the user taps a "File received" notification.
  ///
  /// The two arguments are the SAF tree URI (root of the received-files folder)
  /// and the file's relative path within that tree. Set this before calling
  /// [init] or at any time before files can be received.
  void Function(String treeUri, String relPath)? onFileNotificationTap;

  /// Called when the user taps "Cancel" on a file receive progress notification.
  void Function(String offerId)? onCancelReceiveTap;

  /// Initialise the plugin and request permissions on Android.
  ///
  /// Safe to call multiple times — subsequent calls are no-ops once [_ready].
  /// Errors are swallowed: a notification failure must never block sync.
  Future<void> init() async {
    if (!Platform.isAndroid) return;
    if (_ready) return;
    try {
      // Set up the background message channel port
      const portName = 'conduit_notification_port';
      IsolateNameServer.removePortNameMapping(portName);
      final receivePort = ReceivePort();
      IsolateNameServer.registerPortWithName(receivePort.sendPort, portName);
      receivePort.listen((dynamic message) {
        if (message is NotificationResponse) {
          _onNotificationResponse(message);
        }
      });

      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const initSettings = InitializationSettings(
        android: androidInit,
      );
      await _plugin.initialize(
        initSettings,
        onDidReceiveNotificationResponse: _onNotificationResponse,
        onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
      );

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

  /// Handles a tap on any notification fired by this plugin.
  ///
  /// Only "file received" notifications carry a payload (format: `treeUri\nrelPath`).
  /// All other notifications have no payload and are ignored — tapping them
  /// simply brings the app to the foreground as before.
  void _onNotificationResponse(NotificationResponse response) {
    // TEMP diagnostic logging (2026-07-14) — see notificationTapBackground's
    // doc comment. This confirms the response actually reached the main
    // isolate (whether via the direct foreground callback or the background
    // bridge) before we look at what it says.
    Diag.log('notif_tap_main', fields: {
      'actionId': response.actionId,
      'responseType': response.notificationResponseType.toString(),
      'hasPayload': response.payload != null,
    });

    if (response.notificationResponseType ==
        NotificationResponseType.selectedNotificationAction) {
      if (response.actionId == 'cancel_receive') {
        final offerId = response.payload;
        Diag.log('cancel_action_received', fields: {
          'offerId': offerId,
          'callbackSet': onCancelReceiveTap != null,
        });
        if (offerId != null && offerId.isNotEmpty) {
          onCancelReceiveTap?.call(offerId);
        }
      }
      return;
    }

    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    final sep = payload.indexOf('\n');
    if (sep < 0) return;
    final treeUri = payload.substring(0, sep);
    final relPath = payload.substring(sep + 1);
    if (treeUri.isNotEmpty && relPath.isNotEmpty) {
      onFileNotificationTap?.call(treeUri, relPath);
    }
  }

  /// Show progress for receiving a file.
  Future<void> showReceiveProgress(
    String name,
    int received,
    int total, {
    required String offerId,
  }) async {
    if (!Platform.isAndroid || !_ready) return;
    try {
      final percent = total > 0 ? (received * 100) ~/ total : 0;
      final androidDetails = AndroidNotificationDetails(
        _androidChannelId,
        _androidChannelName,
        channelDescription: _androidChannelDesc,
        importance: Importance.low, // low importance so it doesn't alert/sound on every update
        priority: Priority.low,
        showProgress: true,
        maxProgress: 100,
        progress: percent,
        icon: '@mipmap/ic_launcher',
        onlyAlertOnce: true,
        actions: const <AndroidNotificationAction>[
          AndroidNotificationAction(
            'cancel_receive',
            'Cancel',
            // The live inbound offer exists in the main Flutter engine.
            // Running this action in the plugin's separate background engine
            // cannot reach that in-memory state, so the notification merely
            // reappears on the next progress update. Route it to the main
            // engine instead, where [_onNotificationResponse] cancels it.
            showsUserInterface: true,
            cancelNotification: true,
          ),
        ],
      );
      final details = NotificationDetails(android: androidDetails);
      await _plugin.show(
        name.hashCode ^ 3,
        'Receiving file',
        '$name ($percent%)',
        details,
        payload: offerId,
      );
    } catch (_) {}
  }

  /// Cancel/dismiss the "Receiving file" progress notification for a file.
  Future<void> cancelReceiveProgress(String name) async {
    if (!Platform.isAndroid || !_ready) return;
    try {
      await _plugin.cancel(name.hashCode ^ 3);
    } catch (_) {}
  }

  /// Cancel/dismiss the "Sending file" progress notification for a file.
  Future<void> cancelSendProgress(String name) async {
    if (!Platform.isAndroid || !_ready) return;
    try {
      await _plugin.cancel(name.hashCode ^ 4);
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
  ///
  /// [treeUri] is the SAF tree root URI of the received-files folder.
  /// When both [treeUri] and [name] are provided, tapping the notification
  /// opens the file directly in the appropriate system viewer (Phase 3b+).
  Future<void> showFileReceived(
    String name,
    String peerName, {
    String? treeUri,
  }) async {
    try {
      if (Platform.isAndroid && _ready) {
        await _plugin.cancel(name.hashCode ^ 3);
      }
    } catch (_) {}
    // Encode the file location as the notification payload only when we have
    // a SAF tree URI — on Windows there's no notification payload mechanism.
    final payload = (treeUri != null && treeUri.isNotEmpty)
        ? '$treeUri\n$name'
        : null;
    await _showWithPayload(
      id: name.hashCode ^ 2,
      title: 'File received',
      body: '$name ← $peerName',
      payload: payload,
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
  }) => _showWithPayload(id: id, title: title, body: body);

  Future<void> _showWithPayload({
    required int id,
    required String title,
    required String body,
    String? payload,
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
      await _plugin.show(id, title, body, details, payload: payload);
    } catch (_) {
      // Swallow — a notification failure must never break a transfer.
    }
  }
}
