import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../app_state.dart';

/// Roadmap Phase 4: while true, [_CloseHandler]'s resize/move listeners skip
/// persisting the window's current bounds to SharedPreferences.
///
/// [SendWidgetScreen] sets this before it shrinks the shared window into the
/// compact send popup, and clears it after restoring normal bounds on the
/// way out. Without this, the very act of shrinking the window for the
/// widget would itself fire `onWindowResized` and silently overwrite the
/// user's real saved window size/position with the tiny popup's geometry.
bool suppressWindowBoundsPersistence = false;

/// Roadmap Phase 4 bug fix: monotonic counter identifying the current
/// "send widget" session (one open→close cycle of [SendWidgetScreen]).
///
/// [SendWidgetScreen] claims a new epoch synchronously in `initState`, and
/// its `_close()` cleanup — which fires `setAlwaysOnTop(false)` and
/// [DesktopTray.restoreNormalBounds] *unawaited*, deliberately, so a stalled
/// window-manager call can't hang the close — re-checks its epoch is still
/// current before actually applying each step. Without this, a new "Send to
/// Conduit" arriving while a previous send widget's cleanup is still
/// in-flight (e.g. two files sent back-to-back, or a second send triggered
/// right as the first auto-closes) could race: the new widget resizes/
/// focuses/pins itself, then the *old* widget's stale cleanup finishes a
/// moment later and undoes it — leaving the window at full size, unfocused,
/// or not on top right after the new send widget was supposed to open. From
/// the user's side that looks exactly like "the send UI doesn't open" (it's
/// there, just not visible/focused) or opens and then visibly reverts.
int sendWidgetEpoch = 0;

/// Claims and returns the next send-widget epoch. Call once, synchronously,
/// from [SendWidgetScreen.initState] — synchronous so ordering across rapid
/// mounts is deterministic (no await gap where two mounts could race to
/// claim the same epoch).
int beginSendWidgetEpoch() => ++sendWidgetEpoch;

/// True if [epoch] is still the current send-widget session — i.e. no newer
/// [SendWidgetScreen] has been mounted since [epoch] was claimed.
bool isCurrentSendWidgetEpoch(int epoch) => epoch == sendWidgetEpoch;

/// Desktop close-to-tray + system tray integration (Roadmap Phase 1).
///
/// On Windows the user expects closing the window to keep Conduit running
/// (sync is a background service), with a tray icon to surface it and an
/// explicit "Quit" for the rare intentional exit. This class wires:
///
///   - [WindowCloseHandler]: hide the window instead of destroying the process
///     so sync keeps running. The real teardown only happens on an explicit
///     Quit (tray menu or in-app button).
///   - a tray icon with three actions: **Show** (un-hide), **Pause sync** /
///     **Resume sync** (toggles [AppState.pauseSync]/[resumeSync]), and
///     **Quit** (the intentional exit the owner asked for — tears everything
///     down then `exit(0)`).
///
/// Used only on desktop (the entry point in `main.dart` is platform-gated).
/// On Android these packages are simply not initialized, so there is no tray
/// code path on mobile at all.
class DesktopTray with TrayListener {
  DesktopTray._(this._context);
  factory DesktopTray.forApp(BuildContext context) => DesktopTray._(context);

  final BuildContext _context;
  bool _paused = false;
  bool _quitting = false;

  /// Install the close-to-tray guard + tray icon. Call once after the app is
  /// running (e.g. from the Dashboard's first frame). Idempotent.
  Future<void> init() async {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.setAspectRatio(0); // allow free resize
    windowManager.addListener(_CloseHandler(_context));

    // Restore window bounds if saved. Skip if a send-widget entry is already
    // under way and has flagged the window as off-limits — otherwise this
    // startup restore could land right after the widget shrinks the window
    // and stomp its compact geometry with the user's normal saved size.
    if (!suppressWindowBoundsPersistence) {
      await restoreNormalBounds();
    }

    // Tray icon: prefer the bundled runner .ico (the same icon Windows shows
    // for the .exe), located relative to the running app. Failing to set an
    // icon must NOT abort tray setup — sync still runs without a pretty icon,
    // and the menu (the part that matters for Show/Pause/Quit) is set below.
    try {
      await trayManager.setIcon(_resolveIconPath());
    } catch (e) {
      debugPrint('Tray icon unavailable (menu still works): $e');
    }
    await trayManager.setToolTip('Conduit');
    await _rebuildMenu();
    trayManager.addListener(this);
  }

  /// Restore the window to its last saved normal size/position, falling back
  /// to centering a default-sized window if nothing has been saved yet (e.g.
  /// the very first run). Shared by [init]'s startup restore and by
  /// [SendWidgetScreen] when it hands the shared window back after a compact
  /// send — both need the exact same "what does normal look like" logic, so
  /// there is only one place that can drift from the values [_CloseHandler]
  /// persists.
  static Future<void> restoreNormalBounds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final x = prefs.getDouble('window_x');
      final y = prefs.getDouble('window_y');
      final w = prefs.getDouble('window_width');
      final h = prefs.getDouble('window_height');
      if (x != null && y != null && w != null && h != null) {
        await windowManager.setBounds(Rect.fromLTWH(x, y, w, h));
      } else {
        // Nothing saved yet — match the native runner's own default size
        // (windows/runner/main.cpp) and just center it.
        await windowManager.setBounds(null, size: const Size(1280, 720));
        await windowManager.center();
      }
    } catch (e) {
      debugPrint('Failed to restore window bounds: $e');
    }
  }

  /// Shared intentional-exit path for Windows. Use this from every in-app Quit
  /// button and from the tray menu so the shell icon is removed before the
  /// process exits.
  static Future<void> quitApp(AppState state) async {
    try {
      await state.quit().timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('Graceful quit timed out or failed; exiting anyway: $e');
    } finally {
      try {
        await trayManager.destroy();
      } catch (_) {
        // Best effort: if the tray plugin is already gone, still exit.
      }
      exit(0);
    }
  }

  /// Resolve the tray icon path. On Windows a release/profile build ships
  /// `data/flutter_assets/...` next to the exe; we reuse the runner's app icon
  /// by referencing it from the bundled assets when present, else fall back to
  /// the default (tray_manager shows a generic icon if none is set).
  String _resolveIconPath() {
    if (Platform.isWindows) {
      return 'assets/icons/app_icon.ico';
    }
    return 'assets/icons/app_icon.png';
  }

  /// Build the tray menu, reflecting the current pause state.
  Future<void> _rebuildMenu() async {
    final menu = Menu(items: [
      MenuItem(label: 'Show Conduit', onClick: _showWindow),
      MenuItem.separator(),
      MenuItem(
        label: _paused ? 'Resume sync' : 'Pause sync',
        onClick: _togglePause,
      ),
      MenuItem.separator(),
      MenuItem(label: 'Quit', onClick: _quit),
    ]);
    await trayManager.setContextMenu(menu);
  }

  void _showWindow(MenuItem _) {
    _showAppWindow();
  }

  Future<void> _showAppWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _togglePause(MenuItem _) async {
    final state = _context.read<AppState>();
    if (_paused) {
      state.resumeSync();
    } else {
      state.pauseSync();
    }
    _paused = state.isPaused;
    await _rebuildMenu();
  }

  /// Intentional exit (Roadmap Phase 1 "Quit/exit button"). Tears the app down
  /// cleanly via AppState.quit, then exits the process. This is the ONLY path
  /// that performs a real exit — close-to-tray and backgrounding keep the
  /// process alive.
  Future<void> _quit(MenuItem _) async {
    if (_quitting) return;
    _quitting = true;
    final state = _context.read<AppState>();
    await DesktopTray.quitApp(state);
  }

  @override
  void onTrayIconMouseDown() {
    _showAppWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu(bringAppToFront: true);
  }
}

/// Intercepts the window's close button so it hides-to-tray instead of killing
/// the process (Roadmap Phase 1 close-to-tray). The real exit is the tray /
/// in-app Quit.
class _CloseHandler extends WindowListener {
  _CloseHandler(this._context);
  final BuildContext _context;

  @override
  void onWindowClose() async {
    // Hide instead of destroy. The process — and therefore the sync engine —
    // stays alive in the background. A future "Show" (tray) or app re-launch
    // re-surfaces it.
    await windowManager.hide();

    // Surface a one-time hint that we're now in the tray, so the user isn't
    // confused when the window disappears. Fire-and-forget.
    if (!_shownTrayHint) {
      _shownTrayHint = true;
      try {
        final state = _context.read<AppState>();
        await trayManager.setToolTip('Conduit is still running here.\n'
            '${state.identity.name} (${state.identity.deviceId})');
      } catch (_) {}
    }
  }

  @override
  void onWindowResized() {
    _saveWindowBounds();
  }

  @override
  void onWindowMoved() {
    _saveWindowBounds();
  }

  Future<void> _saveWindowBounds() async {
    if (suppressWindowBoundsPersistence) return;
    try {
      if (await windowManager.isMaximized() ||
          await windowManager.isMinimized()) {
        return;
      }
      final rect = await windowManager.getBounds();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('window_x', rect.left);
      await prefs.setDouble('window_y', rect.top);
      await prefs.setDouble('window_width', rect.width);
      await prefs.setDouble('window_height', rect.height);
    } catch (e) {
      debugPrint('Failed to save window bounds: $e');
    }
  }
}

bool _shownTrayHint = false;
