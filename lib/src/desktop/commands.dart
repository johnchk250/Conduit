import 'dart:io';

import 'package:flutter/services.dart';

import '../diag.dart';

/// Remote-command executor for the PC side (Roadmap Phase 4 — Option A).
///
/// Maintains a FIXED ALLOWLIST of command names; any name not in the list is
/// rejected (logged, silently dropped). Commands are either:
///   - OS-level shell calls via [Process.run] (power management)
///   - Media/volume virtual-key presses via the [_chRemoteKeys] method channel,
///     which is handled natively in windows/runner/ (SendInput Win32 API).
///
/// Engine-safe by construction: this class has no knowledge of the sync engine,
/// IndexDb, or version vectors. It is instantiated by [AppState] and its
/// [execute] method is called from the [SyncEngine.onRunCommand] callback.
///
/// Only instantiated on Windows; [AppState] guards with [Platform.isWindows].
class RemoteCommandExecutor {
  RemoteCommandExecutor({
    this.enabled = false,
    this.onLog,
  });

  /// When false, [execute] returns immediately without running anything.
  /// Toggled by the PC-side settings toggle.
  bool enabled;

  /// Optional structured log sink (routes to Diag / activity feed).
  final void Function(String message, {bool isError})? onLog;

  /// Method channel for Win32 virtual-key media / volume presses.
  /// Implemented in windows/runner/flutter_window.cpp (registered on startup).
  static const _chRemoteKeys = MethodChannel('conduit/remote_keys');

  // ---- Allowlist -----------------------------------------------------------
  /// Every command the PC will act on. Anything else is dropped.
  static const _shutdownMinutes = [10, 20, 30, 40, 50, 60];

  static final Set<String> allowlist = {
    for (final m in _shutdownMinutes) 'shutdown_$m',
    'shutdown_cancel',
    'sleep',
    'hibernate',
    'media_play_pause',
    'media_next',
    'media_prev',
    'volume_up',
    'volume_down',
    'volume_mute',
  };

  // ---- Public API ----------------------------------------------------------

  /// Execute [name] if it is in the allowlist and the feature is enabled.
  /// Returns `true` if the command was dispatched, `false` if blocked/invalid.
  Future<bool> execute(String name) async {
    if (!enabled) {
      _log('Remote control is disabled — ignoring command "$name"');
      return false;
    }
    if (!allowlist.contains(name)) {
      _log('Unknown command "$name" — rejected (not in allowlist)',
          isError: true);
      return false;
    }
    _log('Executing remote command: $name');
    try {
      await _dispatch(name);
      return true;
    } catch (e) {
      _log('Command "$name" failed: $e', isError: true);
      return false;
    }
  }

  // ---- Dispatch ------------------------------------------------------------

  Future<void> _dispatch(String name) async {
    // ---- Shutdown family ---------------------------------------------------
    if (name.startsWith('shutdown_') && name != 'shutdown_cancel') {
      final minutes = int.tryParse(name.replaceFirst('shutdown_', ''));
      if (minutes != null) {
        final seconds = minutes * 60;
        // /f: force close apps  /t: delay in seconds
        await _shell('shutdown', ['/s', '/f', '/t', '$seconds']);
        return;
      }
    }
    switch (name) {
      case 'shutdown_cancel':
        await _shell('shutdown', ['/a']);
        break;

      case 'sleep':
        // rundll32 SetSuspendState: S3 sleep (RAM stays powered).
        // Args: hibernate=0, forceCritical=1, disableWakeEvent=0
        await _shell(
          'rundll32.exe',
          ['powrprof.dll,SetSuspendState', '0,1,0'],
        );
        break;

      case 'hibernate':
        await _shell('shutdown', ['/h']);
        break;

      // ---- Media / volume (Win32 virtual keys via method channel) ----------
      case 'media_play_pause':
      case 'media_next':
      case 'media_prev':
      case 'volume_up':
      case 'volume_down':
      case 'volume_mute':
        await _sendKey(name);
        break;
    }
  }

  // ---- Helpers -------------------------------------------------------------

  /// Run a Windows shell command (non-interactive, no window).
  Future<void> _shell(String exe, List<String> args) async {
    final result = await Process.run(
      exe,
      args,
      runInShell: false,
    );
    if (result.exitCode != 0) {
      // Some commands (e.g. shutdown /a when no shutdown is pending) exit non-zero.
      // Log but don't throw — the user may have hit Cancel when nothing was pending.
      _log(
        'Command "$exe ${args.join(' ')}" exited with code ${result.exitCode}: '
        '${result.stderr}',
        isError: result.exitCode != 0,
      );
    }
  }

  Future<void> _sendKey(String name) async {
    try {
      await _chRemoteKeys.invokeMethod<void>(name);
    } on MissingPluginException {
      // Channel not registered — fall back to PowerShell WScript.Shell SendKeys.
      // This works on all Windows versions without a native plugin.
      final psKey = _psKeyFor(name);
      if (psKey != null) {
        await _shell('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          '(New-Object -ComObject WScript.Shell).SendKeys($psKey)',
        ]);
      }
    }
  }

  /// Maps command names to WScript.Shell.SendKeys strings for the fallback path.
  String? _psKeyFor(String name) => switch (name) {
        'media_play_pause' => '[char]179',
        'media_next' => '[char]176',
        'media_prev' => '[char]177',
        'volume_up' => '[char]175',
        'volume_down' => '[char]174',
        'volume_mute' => '[char]173',
        _ => null,
      };

  void _log(String msg, {bool isError = false}) {
    Diag.log('remote_cmd', fields: {
      'msg': msg,
      if (isError) 'level': 'error',
    });
    onLog?.call(msg, isError: isError);
  }
}
