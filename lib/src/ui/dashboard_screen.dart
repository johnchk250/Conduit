import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../desktop/background_survival_screen.dart';
import '../desktop/tray.dart';
import '../platform/saf_access.dart';
import '../protocol/wire.dart';
import '../sync/engine.dart';
import 'pairing_screen.dart';
import 'folder_pairs_screen.dart';
import 'activity_screen.dart';
import 'clipboard_screen.dart';
import 'send_panel.dart';
import 'send_widget_screen.dart';
import 'remote_control_screen.dart';

/// Responsive app shell. Desktop gets a NavigationRail; phones a BottomNav.
///
/// This is the app's root route, so it is ALWAYS mounted while the app runs.
///
/// Step 3 of the fix plan: invite delivery is now STATE-driven, not event-
/// driven. There is no StreamSubscription here anymore. We read
/// `state.pendingInvite` on every rebuild (via `context.watch<AppState>()`);
/// when it transitions to non-null we show the dialog, when the user responds
/// AppState clears it. This removes the entire class of "listener attached too
/// late / torn down on rebuild" bugs that the stream-subscription approach
/// was heir to.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _index = 0;

  /// The pairId of the invite whose dialog is currently on screen. Used to
  /// avoid re-showing the same dialog if a rebuild fires before
  /// AppState clears the field.
  String? _displayedInvitePairId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AppState>().start();
      // Phase 1: install the Windows close-to-tray + tray menu. Desktop-only;
      // on Android this is a no-op (the packages aren't initialized there, so
      // the call is gated to avoid dragging desktop deps into the mobile build
      // path at runtime).
      if (Platform.isWindows) {
        DesktopTray.forApp(context).init().catchError((Object e) {
          // A tray init failure must never block the app — sync still runs.
          debugPrint('Tray init failed: $e');
        });
      }
    });
  }

  void _showInviteDialogIfNeeded(FolderPairInvite? invite) {
    if (invite == null) {
      _displayedInvitePairId = null;
      return;
    }
    if (_displayedInvitePairId == invite.pairId) return; // already on screen
    _displayedInvitePairId = invite.pairId;
    // Defer showDialog to a post-frame callback — showing a dialog during
    // build is a Flutter anti-pattern that can assert. The state read above
    // is what gates idempotency; the actual show happens just after this
    // frame, before the next paint.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        useRootNavigator: true,
        barrierDismissible: false,
        builder: (dctx) => _InviteDialog(invite: invite),
      );
    });
    // AppState clears pendingInvite itself when accept/decline is called, so
    // the dialog dismissal is not what drives state — state drives the dialog.
  }

  /// Phase 3d: if the OS share/send mechanism queued files into AppState,
  /// switch to the Send tab so the user immediately sees the peer picker
  /// with their files pre-loaded. Uses a post-frame callback so we never
  /// navigate during a build call.
  bool _sendPanelPushed = false;
  void _navigateToSendIfSharedFiles(AppState state, bool isWide) {
    if (_sendPanelPushed) return;
    if (state.pendingSharedFiles == null) return;
    if (isWide) {
      _sendPanelPushed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() => _index = 3);
        }
        _sendPanelPushed = false;
      });
    } else {
      _sendPanelPushed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          _sendPanelPushed = false;
          return;
        }
        // Pop any sub-routes to root (e.g. settings or keep-alive sub-screens)
        // so that the SendPanel is pushed directly on top of the DashboardScreen
        // and doesn't get obscured or make the back stack confusing.
        Navigator.of(context).popUntil((route) => route.isFirst);
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const SendPanel()),
        ).then((_) {
          _sendPanelPushed = false;
        });
      });
    }
  }

  @override
  Widget build(BuildContext ctx) {
    final state = ctx.watch<AppState>();
    // Guard against the brief window before AppState.start() finishes
    // initializing the late identity/config/engine fields.
    if (!state.isStarted) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 48,
                height: 48,
                child: CircularProgressIndicator(strokeWidth: 4),
              ),
              const SizedBox(height: 20),
              Text(
                'Starting Conduit…',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                state.status,
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
    }
    // Roadmap Phase 4: a KDE-Connect-style compact "send widget" stands in
    // for the full shell while a Windows-triggered ad-hoc send is active, so
    // "Send to Conduit" from Explorer never has to open the whole app just
    // to push one file. Checked before _showInviteDialogIfNeeded and
    // _navigateToSendIfSharedFiles below, so returning early here skips both
    // — a stray folder invite never tries to render on top of the tiny
    // popup, and _index (the NavigationRail/BottomNav selection) is left
    // completely untouched, which is what lets the dashboard reappear
    // exactly where the user left it once the widget closes — see
    // SendWidgetScreen's doc comment. Android has no window to shrink, so it
    // keeps the existing full-screen Send-tab navigation unconditionally.
    if (Platform.isWindows && state.sendWidgetMode) {
      // Pop all sub-routes to root so the SendWidgetScreen is visible
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      });
      return const SendWidgetScreen();
    }

    final isWide = MediaQuery.of(ctx).size.width >= 900;
    // Step 3: invite delivery is state-driven. Check the field every rebuild;
    // if a new invite has arrived, show the dialog. This runs in build, but
    // showDialog is idempotent for a given pairId (see _displayedInvitePairId
    // guard). Doing this here — rather than via a listener — is what makes
    // delivery robust against rebuilds: the rebuild itself is the trigger.
    _showInviteDialogIfNeeded(state.pendingInvite);
    // Phase 3d: if files arrived via the OS share sheet or "Send to" menu,
    // auto-navigate to the Send tab (index 3) so the user immediately sees
    // the peer picker pre-loaded with their files.
    _navigateToSendIfSharedFiles(state, isWide);

    final desktopPages = [
      _OverviewPage(
        state: state,
        onNavigate: (i) => setState(() => _index = i),
      ),
      const FolderPairsScreen(),
      const PairingScreen(),
      const SendPanel(),
      const ActivityScreen(),
      const ClipboardScreen(),
      const RemoteControlScreen(),
      const BackgroundSurvivalScreen(),
    ];

    final mobilePages = [
      _OverviewPage(
        state: state,
        onNavigate: (i) => setState(() => _index = i),
      ),
      const FolderPairsScreen(),
      const PairingScreen(),
      const ClipboardScreen(),
      const RemoteControlScreen(),
      const _SettingsHubPage(),
    ];

    final activeIndex = isWide
        ? _index.clamp(0, desktopPages.length - 1)
        : _index.clamp(0, mobilePages.length - 1);

    if (isWide) {
      return Scaffold(
        body: Row(
          children: [
            // NavigationRail must be width-bounded: a Row gives unbounded
            // width to non-Expanded children, so the rail's internal trailing
            // buttons (SizedBox(width: infinity)) would receive infinite
            // constraints → layout assertion → frame abort → black screen +
            // corrupted MouseTracker (buttons + tray stop responding).
            // SizedBox bounds the rail to its declared minWidth so it never
            // sees infinity.
            SizedBox(
              width: 220,
              child: _NavRail(
                index: activeIndex,
                onChanged: (i) => setState(() => _index = i),
                state: state,
                onPauseToggle: () {
                  if (state.isPaused) {
                    state.resumeSync();
                  } else {
                    state.pauseSync();
                  }
                },
                onQuit: () => _confirmQuit(ctx, state),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: desktopPages[activeIndex]),
          ],
        ),
      );
    }
    return Scaffold(
      body: mobilePages[activeIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: activeIndex,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard),
              label: 'Home'),
          NavigationDestination(
              icon: Icon(Icons.folder_outlined),
              selectedIcon: Icon(Icons.folder),
              label: 'Folders'),
          NavigationDestination(
              icon: Icon(Icons.devices_outlined),
              selectedIcon: Icon(Icons.devices),
              label: 'Devices'),
          NavigationDestination(
              icon: Icon(Icons.content_copy_outlined),
              selectedIcon: Icon(Icons.content_copy),
              label: 'Clipboard'),
          NavigationDestination(
              icon: Icon(Icons.settings_remote_outlined),
              selectedIcon: Icon(Icons.settings_remote),
              label: 'Remote'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings'),
        ],
      ),
    );
  }

  /// Confirmation for the intentional Quit (Roadmap Phase 1). Closing-to-tray
  /// is the default; Quit is the rare explicit teardown, so it asks first.
  Future<void> _confirmQuit(BuildContext ctx, AppState state) async {
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: const Text('Quit Conduit?'),
        content: const Text(
          'This stops sync completely and closes the app. Folder pairs will '
          'resume syncing the next time you start Conduit.\n\n'
          '(Closing the window with the X button keeps Conduit running in '
          'the background instead.)',
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
    if (ok == true) {
      if (Platform.isWindows) {
        await DesktopTray.quitApp(state);
      } else {
        await state.quit();
        exit(0);
      }
    }
  }
}

class _NavRail extends StatelessWidget {
  const _NavRail({
    required this.index,
    required this.onChanged,
    required this.state,
    required this.onPauseToggle,
    required this.onQuit,
  });
  final int index;
  final ValueChanged<int> onChanged;
  final AppState state;
  final VoidCallback onPauseToggle;
  final VoidCallback onQuit;

  @override
  Widget build(BuildContext ctx) {
    return NavigationRail(
      selectedIndex: index,
      onDestinationSelected: onChanged,
      leading: Padding(
        padding: const EdgeInsets.fromLTRB(8, 24, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.sync,
                    color: Theme.of(ctx).colorScheme.primary, size: 28),
                const SizedBox(width: 10),
                Text('Conduit', style: Theme.of(ctx).textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              state.identity.name,
              style: Theme.of(ctx).textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              state.identity.deviceId,
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.outline,
                    fontFamily: 'monospace',
                  ),
            ),
          ],
        ),
      ),
      trailing: Padding(
        // Phase 1 controls: Pause/Resume + the intentional Quit. These are the
        // always-visible handles for "stop syncing now" and "exit the app",
        // mirroring the tray menu.
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        child: Column(
          children: [
            const Divider(),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: onPauseToggle,
                icon: Icon(state.isPaused ? Icons.play_arrow : Icons.pause),
                label: Text(state.isPaused ? 'Resume' : 'Pause'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onQuit,
                icon: const Icon(Icons.power_settings_new),
                label: const Text('Quit'),
              ),
            ),
          ],
        ),
      ),
      destinations: const [
        NavigationRailDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: Text('Home')),
        NavigationRailDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: Text('Folders')),
        NavigationRailDestination(
            icon: Icon(Icons.devices_outlined),
            selectedIcon: Icon(Icons.devices),
            label: Text('Devices')),
        NavigationRailDestination(
            icon: Icon(Icons.send_outlined),
            selectedIcon: Icon(Icons.send),
            label: Text('Send')),
        NavigationRailDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: Text('Activity')),
        NavigationRailDestination(
            icon: Icon(Icons.content_copy_outlined),
            selectedIcon: Icon(Icons.content_copy),
            label: Text('Clipboard')),
        NavigationRailDestination(
            icon: Icon(Icons.settings_remote_outlined),
            selectedIcon: Icon(Icons.settings_remote),
            label: Text('Remote')),
        NavigationRailDestination(
            icon: Icon(Icons.power_settings_new_outlined),
            selectedIcon: Icon(Icons.power_settings_new),
            label: Text('Survival')),
      ],
    );
  }
}

class _OverviewPage extends StatelessWidget {
  const _OverviewPage({required this.state, required this.onNavigate});
  final AppState state;
  final ValueChanged<int> onNavigate;

  @override
  Widget build(BuildContext ctx) {
    final pairs = state.config.folderPairs;
    final connectedCount = state.pairedPeers
        .where((p) => state.isPeerConnected(p.deviceId))
        .length;
    final discovered = state.discoveredPeers;

    return Scaffold(
      appBar: AppBar(title: const Text('Overview')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _HeroBanner(
            title: state.isStarted ? 'Sync is running' : 'Starting up…',
            subtitle: state.isStarted
                ? 'Connected to $connectedCount of ${state.pairedPeers.length} paired device(s)'
                : 'Warming up identity and discovery',
            icon: state.isStarted ? Icons.check_circle : Icons.hourglass_top,
            color: state.isStarted ? Colors.green : Colors.amber,
          ),
          const SizedBox(height: 20),
          Text('Folder pairs', style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (pairs.isEmpty)
            Card(
              child: ListTile(
                leading: const Icon(Icons.folder_off_outlined),
                title: const Text('No folder pairs yet'),
                subtitle: const Text(
                    'Add a folder to start syncing with a paired device.'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _goToFolders(ctx),
              ),
            )
          else
            ...pairs.map((p) {
              final st = state.stateFor(p.id);
              return Card(
                child: ListTile(
                  leading: Icon(Icons.folder,
                      color: Theme.of(ctx).colorScheme.primary),
                  title: Text(p.name),
                  subtitle: Text(
                    '${p.direction.label} · ${st?.status ?? "Idle"}',
                  ),
                  trailing: st?.progress != null
                      ? SizedBox(
                          width: 40,
                          child: LinearProgressIndicator(value: st!.progress),
                        )
                      : const Icon(Icons.chevron_right),
                  onTap: () => _goToFolders(ctx),
                ),
              );
            }),
          const SizedBox(height: 20),
          Text('Devices on this network',
              style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (discovered.isEmpty)
            const Card(
              child: ListTile(
                leading: Icon(Icons.wifi_find_outlined),
                title: Text('Searching for devices…'),
                subtitle: Text('Make sure both devices are on the same Wi-Fi.'),
              ),
            )
          else
            ...discovered.map((d) => Card(
                  child: ListTile(
                    leading: Icon(
                      d.platform == 'android'
                          ? Icons.phone_android
                          : Icons.computer,
                    ),
                    title: Text(d.name),
                    subtitle: Text('${d.deviceId} · ${d.address.address}'),
                    trailing: state.isPeerConnected(d.deviceId)
                        ? const Chip(
                            label: Text('Connected'),
                            avatar: Icon(Icons.link, size: 16))
                        : state.pairedPeers.any((p) => p.deviceId == d.deviceId)
                            ? const Chip(
                                label: Text('Paired'),
                                avatar:
                                    Icon(Icons.handshake_outlined, size: 16))
                            : const Chip(label: Text('New')),
                    onTap: () => _goToDevices(ctx),
                  ),
                )),
          const SizedBox(height: 20),
          Text('Quick actions', style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: Icon(Icons.send_outlined,
                  color: Theme.of(ctx).colorScheme.primary),
              title: const Text('Send files'),
              subtitle:
                  const Text('Share ad-hoc files directly to paired devices'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(ctx).push(
                  MaterialPageRoute(builder: (_) => const SendPanel()),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _goToFolders(BuildContext ctx) => _navigate(ctx, 1);
  void _goToDevices(BuildContext ctx) => _navigate(ctx, 2);

  void _navigate(BuildContext ctx, int i) {
    onNavigate(i);
  }
}

class _HeroBanner extends StatelessWidget {
  const _HeroBanner({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
  });
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext ctx) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            color.withValues(alpha: 0.18),
            color.withValues(alpha: 0.05),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 36),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: Theme.of(ctx)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(subtitle,
                    style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Dialog shown when a folder-pair invite arrives from a peer. Lets the user
/// pick a local folder to bind to the shared pairId, then accept or decline.
///
/// Lives here (in the app root) rather than in [FolderPairsScreen] because
/// the invite listener is in [_DashboardScreenState], which is always mounted
/// — see that class's docs for why.
class _InviteDialog extends StatefulWidget {
  const _InviteDialog({required this.invite});
  final FolderPairInvite invite;

  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog> {
  final _pathCtl = TextEditingController();

  @override
  void dispose() {
    _pathCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext ctx) {
    final state = ctx.read<AppState>();
    final isAndroid = state.identity.platform == 'android';
    // Describe the direction from BOTH sides so the acceptor isn't misled.
    // The invite carries the initiator's direction; our role is the inverse.
    final theirDirection = widget.invite.direction;
    final roleDescription = switch (theirDirection) {
      SyncDirection.twoWay =>
        'Files will sync BOTH WAYS — anything you add or change here also '
            'appears on ${widget.invite.peerName}, and vice versa.',
      SyncDirection.sendOnly =>
        '${widget.invite.peerName} chose "Send only", so their files will be '
            'COPIED HERE. Changes you make locally will NOT be sent back.',
      SyncDirection.receiveOnly =>
        '${widget.invite.peerName} chose "Receive only", so files you put in '
            'this folder will be SENT to them. Their files will NOT come here.',
    };
    return AlertDialog(
      title: Text('Sync "${widget.invite.name}"?'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.invite.peerName} wants to sync a folder called '
              '"${widget.invite.name}" with you. $roleDescription\n\n'
              'Pick the folder on this device where its files should go.',
              style: Theme.of(ctx).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _pathCtl,
                    readOnly: true,
                    decoration: InputDecoration(
                      labelText: isAndroid
                          ? 'Local folder (SAF tree URI)'
                          : 'Local folder path',
                      hintText: 'Tap browse to pick',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    String? path;
                    if (isAndroid) {
                      path = await SafFileSystemAccess.pickTree();
                    } else {
                      path = await FilePicker.platform.getDirectoryPath();
                    }
                    if (path != null) _pathCtl.text = path;
                    setState(() {});
                  },
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Browse'),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            state.declineInvite(widget.invite.pairId);
            Navigator.of(ctx).pop();
          },
          child: const Text('Decline'),
        ),
        FilledButton(
          onPressed: () async {
            final path = _pathCtl.text.trim();
            if (path.isEmpty) {
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(content: Text('Pick a folder first.')),
              );
              return;
            }
            await state.acceptInvite(widget.invite, path);
            if (ctx.mounted) {
              Navigator.of(ctx).pop();
              ScaffoldMessenger.of(ctx).showSnackBar(
                SnackBar(content: Text('Syncing "${widget.invite.name}" now.')),
              );
            }
          },
          child: const Text('Accept & sync'),
        ),
      ],
    );
  }
}

/// A compact, premium Settings Hub page for mobile users (Roadmap Phase 5).
/// Collapses "Send files", "Activity log", and "Keep alive" screens into one
/// easily accessible, clean and unified layout.
class _SettingsHubPage extends StatelessWidget {
  const _SettingsHubPage();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(
              height: 1, color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        children: [
          // ---- Storage ----
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(Icons.download,
                      color: Theme.of(context).colorScheme.primary),
                  title: const Text('Received files folder'),
                  subtitle: Text(
                    state.receivedFilesPath ??
                        (Platform.isWindows
                            ? 'Defaults to Documents\\Sync'
                            : 'Required: tap to pick folder'),
                    style: TextStyle(
                      color:
                          state.receivedFilesPath == null && Platform.isAndroid
                              ? Theme.of(context).colorScheme.error
                              : null,
                    ),
                  ),
                  trailing: const Icon(Icons.edit_outlined, size: 20),
                  onTap: () async {
                    String? path;
                    if (Platform.isAndroid) {
                      path = await SafFileSystemAccess.pickTree();
                    } else {
                      path = await FilePicker.platform.getDirectoryPath();
                    }
                    if (path != null) {
                      await state.setReceivedFilesPath(path);
                    }
                  },
                ),
                Divider(
                    height: 1,
                    indent: 56,
                    color: Theme.of(context).colorScheme.outlineVariant),
                ListTile(
                  leading: Icon(Icons.history_outlined,
                      color: Theme.of(context).colorScheme.primary),
                  title: const Text('Activity log'),
                  subtitle:
                      const Text('View history of sync operations and events'),
                  trailing: const Icon(Icons.chevron_right, size: 20),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const ActivityScreen()),
                    );
                  },
                ),
                Divider(
                    height: 1,
                    indent: 56,
                    color: Theme.of(context).colorScheme.outlineVariant),
                ListTile(
                  leading: Icon(Icons.power_settings_new_outlined,
                      color: Theme.of(context).colorScheme.primary),
                  title: const Text('Keep alive'),
                  subtitle: const Text(
                      'Execution controls and background battery settings'),
                  trailing: const Icon(Icons.chevron_right, size: 20),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const BackgroundSurvivalScreen()),
                    );
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ---- System (Android-only UI, but the card is always shown) ----
          Text('System',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  )),
          const SizedBox(height: 6),
          Card(
            child: Column(
              children: [
                // Notification visibility: show/hide the status-bar icon.
                // Android only — on Windows there is no persistent notification.
                if (Platform.isAndroid) ...[
                  SwitchListTile(
                    secondary: Icon(
                      Icons.notifications_outlined,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    title: const Text('Show in status bar'),
                    subtitle: const Text(
                      'Display a Conduit icon in the Android status bar while '
                      'sync is running in the background.',
                    ),
                    value: state.showPersistentNotification,
                    onChanged: (v) => state.setShowPersistentNotification(v),
                  ),
                  Divider(
                      height: 1,
                      indent: 56,
                      color: Theme.of(context).colorScheme.outlineVariant),
                ],

                // Battery-saver mode: 1-hour watcher cadence.
                SwitchListTile(
                  secondary: Icon(
                    Icons.battery_saver_outlined,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  title: const Text('Battery saver mode'),
                  subtitle: const Text(
                    'Scan folders every hour instead of every 4\u202fs — greatly '
                    'reduces battery use. Local changes sync with up to 1-hour delay.',
                  ),
                  value: state.batterySaverMode,
                  onChanged: (v) => state.setBatterySaverMode(v),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
