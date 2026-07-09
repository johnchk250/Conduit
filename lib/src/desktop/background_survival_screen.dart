import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import 'tray.dart';

/// Guidance for keeping Conduit alive in the background (Roadmap Phase 1).
///
/// Two platforms, two completely different stories, surfaced on one screen so
/// the owner (who runs Conduit on BOTH a Windows PC and an Android phone)
/// knows exactly what to do on each:
///
///   - **Windows:** closing the window hides to tray; sync keeps running. The
///     real exit is the Quit button / tray Quit. No OS-level battery killers to
///     fight here.
///   - **Android:** NO code defeats MIUI/EMUI/ColorOS's background killers, so
///     the screen walks the user through the OEM-specific battery/autostart
///     whitelists (the same reality KDE Connect documents). It also offers the
///     "request ignore battery optimizations" action (a stock-Android helper)
///     and explains the Android 14+ dataSync 6h cap caveat.
///
/// Reads only [AppState]; calls only public methods. Pure UI — engine-safe.
class BackgroundSurvivalScreen extends StatelessWidget {
  const BackgroundSurvivalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final isAndroid = state.identity.platform == 'android';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Keep alive'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(
              height: 1, color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _IntroBanner(isAndroid: isAndroid),
          const SizedBox(height: 16),
          _SyncControlsCard(state: state),
          const SizedBox(height: 16),
          if (isAndroid)
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(Icons.battery_saver,
                        color: Theme.of(context).colorScheme.primary),
                    title: const Text('Battery optimization'),
                    subtitle: const Text(
                        'Set battery setting to "Unrestricted" so the OS doesn\'t interrupt background synchronization.'),
                    trailing: OutlinedButton(
                      onPressed: () => state.openBatteryOptimizationSettings(),
                      child: const Text('Configure'),
                    ),
                  ),
                  Divider(
                      height: 1,
                      indent: 56,
                      color: Theme.of(context).colorScheme.outlineVariant),
                  const ListTile(
                    leading: Icon(Icons.notifications_active_outlined,
                        color: Colors.blue),
                    title: Text('Foreground service notification'),
                    subtitle: Text(
                        'Android requires a persistent notification to keep Conduit active in the background. Minimize it in OS settings if preferred, but do not block it.'),
                  ),
                  Divider(
                      height: 1,
                      indent: 56,
                      color: Theme.of(context).colorScheme.outlineVariant),
                  const ListTile(
                    leading: Icon(Icons.launch_outlined, color: Colors.blue),
                    title: Text('Autostart settings'),
                    subtitle: Text(
                        'Ensure Autostart is allowed for Conduit in your device\'s app details settings (common on Xiaomi, OPPO, and Vivo).'),
                  ),
                ],
              ),
            )
          else
            Card(
              child: Column(
                children: [
                  const ListTile(
                    leading: Icon(Icons.desktop_windows_outlined,
                        color: Colors.blue),
                    title: Text('System tray execution'),
                    subtitle: Text(
                        'Closing the window hides Conduit to the notification area (system tray) to run background synchronization tasks.'),
                  ),
                  Divider(
                      height: 1,
                      indent: 56,
                      color: Theme.of(context).colorScheme.outlineVariant),
                  const ListTile(
                    leading:
                        Icon(Icons.pause_circle_outline, color: Colors.blue),
                    title: Text('Pause syncing'),
                    subtitle: Text(
                        'Syncing can be paused/resumed dynamically from the sidebar or the tray context menu.'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Pause/Resume + Quit controls (Roadmap Phase 1). These are the REAL buttons
/// that the prose cards below describe — present on every platform so a phone
/// (which has no nav rail and no tray menu) can still pause sync and quit the
/// app. Quit is the intentional teardown: it stops the foreground service (so
/// the notification clears on Android), tears down discovery/connections/engine,
/// and exits the process. This is distinct from closing the window (Windows,
/// hides to tray) or backgrounding (Android), which keep the process alive.
class _SyncControlsCard extends StatelessWidget {
  const _SyncControlsCard({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext ctx) {
    final paused = state.isPaused;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  paused ? Icons.pause_circle : Icons.play_circle,
                  color: Theme.of(ctx).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    paused ? 'Sync is paused' : 'Sync is running',
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                if (paused)
                  const Chip(label: Text('Paused'), avatar: Icon(Icons.pause))
                else
                  const Chip(
                      label: Text('Active'),
                      avatar: Icon(Icons.check_circle, size: 16)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () {
                      if (paused) {
                        state.resumeSync();
                      } else {
                        state.pauseSync();
                      }
                    },
                    icon: Icon(paused ? Icons.play_arrow : Icons.pause),
                    label: Text(paused ? 'Resume sync' : 'Pause sync'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _confirmQuit(ctx),
                    icon: const Icon(Icons.power_settings_new),
                    label: const Text('Quit'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Confirmation for the intentional Quit. Quit is a real teardown (not
  /// close-to-tray), so it asks first — same gate as the desktop nav rail's
  /// Quit. On confirm, AppState.quit() runs (stops the Android foreground
  /// service, tears down supervisor/discovery/connections/engine) and then we
  /// exit the process.
  Future<void> _confirmQuit(BuildContext ctx) async {
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: const Text('Quit Conduit?'),
        content: const Text(
          'This stops sync completely and closes the app. Your folder pairs and '
          'pairing are kept, and syncing resumes the next time you start '
          'Conduit.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonalIcon(
            onPressed: () => Navigator.of(dctx).pop(true),
            icon: const Icon(Icons.power_settings_new),
            label: const Text('Quit'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (Platform.isWindows) {
      await DesktopTray.quitApp(state);
    } else {
      await state.quit();
      // The actual process exit lives at the call site (mirrors the desktop
      // tray/nav-rail Quit, where AppState.quit() tears down but the caller
      // performs exit(0)). exit() is a no-op in Flutter Web; on Android/Windows
      // it terminates the process so the foreground-service notification clears.
      exit(0);
    }
  }
}

class _IntroBanner extends StatelessWidget {
  const _IntroBanner({required this.isAndroid});
  final bool isAndroid;

  @override
  Widget build(BuildContext ctx) {
    final color = isAndroid ? Colors.orange : Colors.blue;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            color.withValues(alpha: 0.18),
            color.withValues(alpha: 0.05)
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(isAndroid ? Icons.phone_android : Icons.desktop_windows,
              color: color, size: 32),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              isAndroid
                  ? 'Keep Conduit alive in the background'
                  : 'Conduit runs in the background',
              style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
