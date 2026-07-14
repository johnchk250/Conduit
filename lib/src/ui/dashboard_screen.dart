import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../core/config_store.dart';
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
import 'glass.dart';

/// A fast 180 ms fade transition used for all pushed sub-screens.
/// The default [MaterialPageRoute] slide takes ~300 ms and feels heavy on top
/// of a glass UI that already has backdrop-blur compositing overhead.
PageRoute<T> _fadeRoute<T>(WidgetBuilder builder) => PageRouteBuilder<T>(
      pageBuilder: (ctx, _, secondary) => builder(ctx),
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 140),
      transitionsBuilder: (_, animation, secondary, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      ),
    );

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
          _fadeRoute((_) => const SendPanel()),
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
      final c = GlassColors.of(ctx);
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: GlassBackground(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 48,
                  height: 48,
                  child: CircularProgressIndicator(
                    strokeWidth: 4,
                    valueColor: AlwaysStoppedAnimation<Color>(c.violet),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Starting Conduit…',
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  state.status,
                  style: TextStyle(color: c.textSecondary, fontSize: 12),
                ),
              ],
            ),
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
        onNavigate: (i) => setState(() => _index = i),
      ),
      const RepaintBoundary(child: FolderPairsScreen()),
      const RepaintBoundary(child: PairingScreen()),
      const RepaintBoundary(child: SendPanel()),
      const RepaintBoundary(child: ActivityScreen()),
      const RepaintBoundary(child: ClipboardScreen()),
      const RepaintBoundary(child: RemoteControlScreen()),
      const RepaintBoundary(child: _SettingsHubPage()),
    ];

    final mobilePages = [
      _OverviewPage(
        onNavigate: (i) => setState(() => _index = i),
      ),
      const RepaintBoundary(child: FolderPairsScreen()),
      const RepaintBoundary(child: PairingScreen()),
      const RepaintBoundary(child: ClipboardScreen()),
      const RepaintBoundary(child: RemoteControlScreen()),
      const RepaintBoundary(child: _SettingsHubPage()),
    ];

    final activeIndex = isWide
        ? _index.clamp(0, desktopPages.length - 1)
        : _index.clamp(0, mobilePages.length - 1);

    if (isWide) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: GlassBackground(
          child: Row(
            children: [
              // NavigationRail must be width-bounded: a Row gives unbounded
              // width to non-Expanded children, so the rail's internal
              // trailing buttons (SizedBox(width: infinity)) would receive
              // infinite constraints → layout assertion → frame abort →
              // black screen + corrupted MouseTracker (buttons + tray stop
              // responding). SizedBox bounds the rail to its declared
              // minWidth so it never sees infinity. Still true for
              // GlassNavRail, which keeps the same leading/trailing shape.
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
              // No VerticalDivider here — GlassNavRail is a floating panel
              // with its own border/blur, so a hard-line divider next to it
              // reads as a glass rendering artifact rather than a boundary.
              Expanded(
                child: desktopPages[activeIndex],
              ),
            ],
          ),
        ),
      );
    }
    return GlassBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: false,
        body: mobilePages[activeIndex],
        bottomNavigationBar: GlassNavBar(
          selectedIndex: activeIndex,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: const [
            GlassNavDestination(
                icon: Icons.dashboard_outlined,
                selectedIcon: Icons.dashboard,
                label: 'Home'),
            GlassNavDestination(
                icon: Icons.folder_outlined,
                selectedIcon: Icons.folder,
                label: 'Folders'),
            GlassNavDestination(
                icon: Icons.devices_outlined,
                selectedIcon: Icons.devices,
                label: 'Devices'),
            GlassNavDestination(
                icon: Icons.content_copy_outlined,
                selectedIcon: Icons.content_copy,
                label: 'Clipboard'),
            GlassNavDestination(
                icon: Icons.settings_remote_outlined,
                selectedIcon: Icons.settings_remote,
                label: 'Remote'),
            GlassNavDestination(
                icon: Icons.settings_outlined,
                selectedIcon: Icons.settings,
                label: 'Settings'),
          ],
        ),
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
    final c = GlassColors.of(ctx);
    return GlassNavRail(
      selectedIndex: index,
      onDestinationSelected: onChanged,
      leading: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.sync, color: c.violet, size: 26),
                const SizedBox(width: 10),
                Text(
                  'Conduit',
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              state.identity.name,
              style: TextStyle(color: c.textSecondary, fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              state.identity.deviceId,
              style: TextStyle(
                color: c.textTertiary,
                fontSize: 11,
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
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GlassButton(
              icon: state.isPaused ? Icons.play_arrow : Icons.pause,
              label: state.isPaused ? 'Resume' : 'Pause',
              accentColor: state.isPaused ? c.mint : c.amber,
              style: GlassButtonStyle.primary,
              onTap: onPauseToggle,
            ),
            const SizedBox(height: 8),
            GlassButton(
              icon: Icons.power_settings_new,
              label: 'Quit',
              accentColor: c.textSecondary,
              style: GlassButtonStyle.outline,
              onTap: onQuit,
            ),
          ],
        ),
      ),
      destinations: const [
        GlassNavDestination(
            icon: Icons.dashboard_outlined,
            selectedIcon: Icons.dashboard,
            label: 'Home'),
        GlassNavDestination(
            icon: Icons.folder_outlined,
            selectedIcon: Icons.folder,
            label: 'Folders'),
        GlassNavDestination(
            icon: Icons.devices_outlined,
            selectedIcon: Icons.devices,
            label: 'Devices'),
        GlassNavDestination(
            icon: Icons.send_outlined,
            selectedIcon: Icons.send,
            label: 'Send'),
        GlassNavDestination(
            icon: Icons.history_outlined,
            selectedIcon: Icons.history,
            label: 'Activity'),
        GlassNavDestination(
            icon: Icons.content_copy_outlined,
            selectedIcon: Icons.content_copy,
            label: 'Clipboard'),
        GlassNavDestination(
            icon: Icons.settings_remote_outlined,
            selectedIcon: Icons.settings_remote,
            label: 'Remote'),
        GlassNavDestination(
            icon: Icons.settings_outlined,
            selectedIcon: Icons.settings,
            label: 'Settings'),
      ],
    );
  }
}

class _OverviewPage extends StatelessWidget {
  const _OverviewPage({required this.onNavigate});
  final ValueChanged<int> onNavigate;

  @override
  Widget build(BuildContext ctx) {
    final state = ctx.watch<AppState>();
    final c = GlassColors.of(ctx);
    final pairs = state.config.folderPairs;
    final connectedCount = state.pairedPeers
        .where((p) => state.isPeerConnected(p.deviceId))
        .length;
    final discovered = state.discoveredPeers;

    // Reference has no separate app-bar row — the "Overview" heading is
    // just the first thing in the scrollable content
    // (`h1.page-title` inside `.content`), so this no longer wraps in its
    // own `Scaffold`/`AppBar` (both the wide-desktop and mobile shells in
    // `DashboardScreen.build` already provide one Scaffold + a
    // `GlassBackground` ancestor for this page to sit inside).
    return SafeArea(
      child: ListView(
        // Reference `.content{padding:26px 20px 100px}`. The extra bottom
        // padding (vs. the CSS's 100px) gives room for the floating
        // `GlassNavBar` on phones, same purpose the old trailing
        // `SizedBox(height: 90)` served.
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 32),
        children: [
          const GlassPageTitle('Overview'),
          () {
            final String title;
            final String subtitle;
            final IconData icon;
            final Color accentColor;

            if (!state.isStarted) {
              title = 'Starting up…';
              subtitle = 'Warming up identity and discovery';
              icon = Icons.hourglass_top;
              accentColor = c.amber;
            } else if (state.isPaused) {
              title = 'Sync is paused';
              subtitle = 'Syncing is temporarily suspended';
              icon = Icons.pause_circle_filled;
              accentColor = c.amber;
            } else if (state.pairedPeers.isEmpty) {
              title = 'No paired devices';
              subtitle = 'Pair a device in the Devices tab to start syncing';
              icon = Icons.info_outline;
              accentColor = c.blue;
            } else if (connectedCount == 0) {
              title = 'Waiting for connection';
              subtitle = 'Searching for ${state.pairedPeers.length} paired device(s) on local network';
              icon = Icons.sync;
              accentColor = c.blue;
            } else {
              title = 'Sync is running';
              subtitle = 'Connected to $connectedCount of ${state.pairedPeers.length} paired device(s)';
              icon = Icons.check_circle;
              accentColor = c.mint;
            }

            return GlassStatusBanner(
              title: title,
              subtitle: subtitle,
              icon: icon,
              accentColor: accentColor,
            );
          }(),
          const SizedBox(height: 26),
          if (Platform.isWindows) ...[
            ...state.pairedPeers
                .where((p) => p.platform == 'android')
                .map((peer) => Padding(
                      padding: const EdgeInsets.only(bottom: 26),
                      child: PhoneSummaryCard(peer: peer),
                    )),
          ],
          const GlassSectionLabel('Folder pairs'),
          if (pairs.isEmpty)
            GlassListTile(
              leadingIcon: Icons.folder_off_outlined,
              accentColor: c.textSecondary,
              title: 'No folder pairs yet',
              subtitle: 'Add a folder to start syncing with a paired device.',
              trailing: Icon(Icons.chevron_right, color: c.textTertiary),
              onTap: () => _goToFolders(ctx),
            )
          else
            ...pairs.map((p) {
              final st = state.stateFor(p.id);
              final status = st?.status ?? 'Idle';
              // Reference only shows `.status-idle`/`.status-live`
              // (green); `Paused`/`Error` are this app's own states with
              // no reference example, mapped to sensible dot colors from
              // the same accent family rather than left unstyled.
              final Color dotColor;
              final bool live;
              if (status == 'Error') {
                dotColor = c.danger;
                live = false;
              } else if (status == 'Paused') {
                dotColor = c.amber;
                live = false;
              } else if (status.startsWith('Idle')) {
                dotColor = c.textTertiary;
                live = false;
              } else {
                // Scanning / Requesting peer index / actively
                // transferring — matches reference `.status-live`.
                dotColor = c.mint;
                live = true;
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: GlassListTile(
                  leadingIcon: Icons.folder,
                  accentColor: c.violet,
                  title: p.name,
                  subtitle: '${p.direction.label} · $status',
                  subtitleDotColor: dotColor,
                  subtitleLive: live,
                  trailing: st?.progress != null
                      ? SizedBox(
                          width: 40,
                          child: LinearProgressIndicator(
                            value: st!.progress,
                            color: c.violet,
                            backgroundColor: c.violet.withValues(alpha: 0.15),
                          ),
                        )
                      : Icon(Icons.chevron_right, color: c.textTertiary),
                  onTap: () => _goToFolders(ctx),
                ),
              );
            }),
          const SizedBox(height: 26),
          const GlassSectionLabel('Devices on this network'),
          if (discovered.isEmpty)
            GlassListTile(
              leadingIcon: Icons.wifi_find_outlined,
              accentColor: c.blue,
              title: 'Searching for devices…',
              subtitle: 'Make sure both devices are on the same Wi-Fi.',
            )
          else
            ...discovered.map((d) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: GlassListTile(
                    leadingIcon: d.platform == 'android'
                        ? Icons.phone_android
                        : Icons.computer,
                    accentColor: c.blue,
                    title: d.name,
                    // Reference `.tile-sub.mono` — JetBrains Mono, no
                    // status dot (device rows aren't a live/idle state).
                    subtitle: '${d.deviceId} · ${d.address.address}',
                    subtitleMono: true,
                    trailing: state.isPeerConnected(d.deviceId)
                        ? GlassChip(
                            label: 'Connected',
                            icon: Icons.link,
                            accentColor: c.mint,
                            filled: true,
                          )
                        : state.pairedPeers
                                .any((p) => p.deviceId == d.deviceId)
                            ? GlassChip(
                                // Reference's one `.badge` example is
                                // exactly this: "Paired", accent-violet.
                                label: 'Paired',
                                icon: Icons.handshake_outlined,
                                accentColor: c.violet,
                              )
                            : GlassChip(
                                label: 'New',
                                accentColor: c.textSecondary,
                              ),
                    onTap: () => _goToDevices(ctx),
                  ),
                )),
          const SizedBox(height: 26),
          const GlassSectionLabel('Quick actions'),
          GlassListTile(
            leadingIcon: Icons.send_outlined,
            accentColor: c.amber,
            title: 'Send files',
            subtitle: 'Share ad-hoc files directly to paired devices',
            trailing: Icon(Icons.chevron_right, color: c.textTertiary),
            onTap: () {
              Navigator.of(ctx).push(
                _fadeRoute((_) => const SendPanel()),
              );
            },
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

/// A compact, premium Settings Hub page (Roadmap Phase 5).
/// Collapses "Send files", "Activity log", and execution settings into one
/// easily accessible, clean and unified layout.
class _SettingsHubPage extends StatelessWidget {
  const _SettingsHubPage();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = GlassColors.of(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 32),
          children: [
            const GlassPageTitle('Settings'),

            // ---- Storage ----
            // Each former Card(ListTile) row is now its own GlassListTile —
            // that's the intended 1:1 replacement (see glass.dart doc comment)
            // rather than one big panel with internal dividers.
            GlassListTile(
              leadingIcon: Icons.download,
              accentColor: c.violet,
              title: 'Received files folder',
              subtitle: state.receivedFilesPath ??
                  (Platform.isWindows
                      ? 'Defaults to Documents\\Sync'
                      : 'Required: tap to pick folder'),
              // Swaps the old red-text warning for a "Required" chip — the
              // GlassListTile subtitle style is fixed, so the warning signal
              // moves to the trailing slot instead of a color override.
              trailing: (Platform.isAndroid && state.receivedFilesPath == null)
                  ? GlassChip(
                      label: 'Required',
                      icon: Icons.priority_high,
                      accentColor: c.amber,
                      filled: true,
                    )
                  : Icon(Icons.edit_outlined, size: 20, color: c.textTertiary),
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
            const SizedBox(height: 10),
            GlassListTile(
              leadingIcon: Icons.history_outlined,
              accentColor: c.violet,
              title: 'Activity log',
              subtitle: 'View history of sync operations and events',
              trailing:
                  Icon(Icons.chevron_right, size: 20, color: c.textTertiary),
              onTap: () {
                Navigator.of(context).push(
                  _fadeRoute((_) => const ActivityScreen()),
                );
              },
            ),

            const SizedBox(height: 20),

            // ---- System (Android-only UI, but the section is always shown) ----
            const GlassSectionLabel('System'),
            const SizedBox(height: 2),
            // Notification visibility: show/hide the status-bar icon.
            // Android only — on Windows there is no persistent notification.
            if (Platform.isAndroid) ...[
              GlassListTile(
                leadingIcon: Icons.notifications_outlined,
                accentColor: c.teal,
                title: 'Show in status bar',
                subtitle:
                    'Display a Conduit icon in the Android status bar while '
                    'sync is running in the background.',
                trailing: Switch(
                  value: state.showPersistentNotification,
                  onChanged: (v) => state.setShowPersistentNotification(v),
                  activeColor: c.teal,
                ),
              ),
              const SizedBox(height: 10),
              GlassListTile(
                leadingIcon: Icons.volume_up_outlined,
                accentColor: c.amber,
                title: 'Allow phone alerts',
                subtitle:
                    'Let your Windows PC play a sound and vibrate this phone '
                    'to help you locate it. Disable to block all remote alerts.',
                trailing: Switch(
                  value: state.allowPlayPhoneAlert,
                  onChanged: (v) => state.setAllowPlayPhoneAlert(v),
                  activeColor: c.amber,
                ),
              ),
              const SizedBox(height: 10),
            ],

            // Battery-saver mode: 1-hour watcher cadence.
            GlassListTile(
              leadingIcon: Icons.battery_saver_outlined,
              accentColor: c.teal,
              title: 'Battery saver mode',
              subtitle:
                  'Scan folders every hour instead of every 4\u202fs — greatly '
                  'reduces battery use. Local changes sync with up to 1-hour delay.',
              trailing: Switch(
                value: state.batterySaverMode,
                onChanged: (v) => state.setBatterySaverMode(v),
                activeColor: c.teal,
              ),
            ),

            if (Platform.isAndroid) ...[
              const SizedBox(height: 10),
              GlassListTile(
                leadingIcon: Icons.battery_saver_rounded,
                accentColor: c.amber,
                title: 'Battery optimization',
                subtitle:
                    'Set battery setting to "Unrestricted" so the OS doesn\'t interrupt background synchronization.',
                trailing: GestureDetector(
                  onTap: () => state.openBatteryOptimizationSettings(),
                  child: GlassChip(
                    label: 'Configure',
                    icon: Icons.open_in_new_rounded,
                    accentColor: c.amber,
                  ),
                ),
              ),
            ],

            const SizedBox(height: 30),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: GlassButton(
                icon: Icons.power_settings_new_rounded,
                label: 'Quit Conduit',
                accentColor: c.danger,
                style: GlassButtonStyle.outline,
                onTap: () => _confirmQuit(context, state),
              ),
            ),
            const SizedBox(height: 80),
          ],
        ),
      ),
    );
  }

  /// Confirmation for the intentional Quit.
  Future<void> _confirmQuit(BuildContext ctx, AppState state) async {
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
      exit(0);
    }
  }
}

class PhoneSummaryCard extends StatefulWidget {
  const PhoneSummaryCard({super.key, required this.peer});
  final PairedPeer peer;

  @override
  State<PhoneSummaryCard> createState() => _PhoneSummaryCardState();
}

class _PhoneSummaryCardState extends State<PhoneSummaryCard> {
  bool _alerting = false;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = GlassColors.of(context);
    final isConnected = state.isPeerConnected(widget.peer.deviceId);
    final dstate = state.getOrCreateDashboardState(widget.peer.deviceId);

    String updateTimeStr = 'Never connected';
    if (isConnected) {
      updateTimeStr = 'Last updated now';
    } else if (dstate.statusReceivedAt != null) {
      final diff = DateTime.now().difference(dstate.statusReceivedAt!);
      if (diff.inSeconds < 60) {
        updateTimeStr = 'Last updated moments ago';
      } else if (diff.inMinutes < 60) {
        updateTimeStr = 'Last updated ${diff.inMinutes}m ago';
      } else if (diff.inHours < 24) {
        updateTimeStr = 'Last updated ${diff.inHours}h ago';
      } else {
        updateTimeStr = 'Last updated ${diff.inDays}d ago';
      }
    } else if (dstate.lastDisconnectedAt != null) {
      final diff = DateTime.now().difference(dstate.lastDisconnectedAt!);
      if (diff.inMinutes < 60) {
        updateTimeStr = 'Disconnected ${diff.inMinutes}m ago';
      } else {
        updateTimeStr = 'Disconnected ${diff.inHours}h ago';
      }
    }

    String connQuality = 'Offline';
    Color qualityColor = c.textTertiary;
    if (isConnected) {
      if (dstate.missedHeartbeats >= 4) {
        connQuality = 'Reconnecting';
        qualityColor = c.danger;
      } else if (dstate.missedHeartbeats >= 2) {
        connQuality = 'Spotty';
        qualityColor = c.amber;
      } else {
        final rtt = dstate.latestRttMs;
        if (rtt != null) {
          if (rtt < 30) {
            connQuality = 'Excellent ($rtt ms)';
            qualityColor = c.mint;
          } else if (rtt < 100) {
            connQuality = 'Good ($rtt ms)';
            qualityColor = c.blue;
          } else {
            connQuality = 'Spotty ($rtt ms)';
            qualityColor = c.amber;
          }
        } else {
          connQuality = 'Connected';
          qualityColor = c.mint;
        }
      }
    }

    Widget batteryWidget = const SizedBox.shrink();
    if (dstate.batteryPct != null) {
      final pct = dstate.batteryPct!;
      final power = dstate.powerState;
      final isCharging = power == 'charging' || power == 'full';
      final icon = isCharging
          ? Icons.battery_charging_full_rounded
          : pct > 80
              ? Icons.battery_full_rounded
              : pct > 20
                  ? Icons.battery_3_bar_rounded
                  : Icons.battery_alert_rounded;
      final batteryColor = isCharging
          ? c.mint
          : pct > 20
              ? c.textSecondary
              : c.danger;

      batteryWidget = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: batteryColor),
          const SizedBox(width: 4),
          Text(
            '$pct% · ${power ?? 'Unknown'}',
            style: TextStyle(color: c.textSecondary, fontSize: 13),
          ),
        ],
      );
    }

    Widget storageWidget = const SizedBox.shrink();
    if (dstate.storageTotalBytes != null && dstate.storageTotalBytes! > 0) {
      final total = dstate.storageTotalBytes!;
      final avail = dstate.storageAvailableBytes ?? 0;
      final used = total - avail;
      final ratio = used / total;
      final totalGB = (total / (1024 * 1024 * 1024)).toStringAsFixed(1);
      final freeGB = (avail / (1024 * 1024 * 1024)).toStringAsFixed(1);

      storageWidget = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Device storage',
                style: TextStyle(color: c.textSecondary, fontSize: 12),
              ),
              Text(
                '$freeGB GB free of $totalGB GB total',
                style: TextStyle(color: c.textTertiary, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: ratio,
              color: ratio > 0.9 ? c.danger : c.blue,
              backgroundColor: c.glassBorder,
              minHeight: 6,
            ),
          ),
        ],
      );
    }

    Widget warningWidget = const SizedBox.shrink();
    if (isConnected && dstate.conduitHealth != null) {
      final health = dstate.conduitHealth!;
      final warning = health['batteryOptimizationWarning'] == true;
      final powerSaver = health['powerSaverMode'] == true;
      if (warning || powerSaver) {
        warningWidget = Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 14, color: c.amber),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  warning
                      ? 'Conduit health: Battery optimization warning (background sync may be throttled).'
                      : 'Conduit health: Battery saver active on phone.',
                  style: TextStyle(color: c.amber, fontSize: 11.5, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        );
      }
    }

    final peerFolders = state.config.folderPairs
        .where((p) => p.peerDeviceId == widget.peer.deviceId)
        .toList();

    Widget folderRollupWidget = const SizedBox.shrink();
    if (peerFolders.isNotEmpty) {
      folderRollupWidget = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 14),
          Text(
            'Sync health',
            style: GoogleFonts.manrope(
              textStyle: TextStyle(
                color: c.textPrimary,
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 8),
          ...peerFolders.map((p) {
            final isAccepted = state.isPairAcceptedByPeer(p.id);
            final st = state.stateFor(p.id);
            String folderStatus = st?.status ?? 'Idle';
            Color dotColor = c.textTertiary;

            if (!isConnected) {
              folderStatus = 'Peer offline';
              dotColor = c.textTertiary;
            } else if (!isAccepted) {
              folderStatus = 'Waiting for peer accept';
              dotColor = c.amber;
            } else if (state.isPaused) {
              folderStatus = 'Paused';
              dotColor = c.amber;
            } else if (folderStatus == 'Error') {
              dotColor = c.danger;
            } else if (folderStatus.startsWith('Idle')) {
              dotColor = c.mint;
            } else {
              dotColor = c.blue;
            }

            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Icon(Icons.folder, size: 15, color: c.violet.withValues(alpha: 0.8)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      p.name,
                      style: TextStyle(color: c.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    p.direction.label.split(' ').first,
                    style: TextStyle(color: c.textTertiary, fontSize: 11.5),
                  ),
                  const SizedBox(width: 10),
                  _PhoneCardStatusDot(color: dotColor),
                  const SizedBox(width: 6),
                  Text(
                    folderStatus,
                    style: TextStyle(color: c.textSecondary, fontSize: 12.5),
                  ),
                ],
              ),
            );
          }),
        ],
      );
    }

    return GlassPanel(
      ringColor: isConnected ? c.violet : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.phone_android, size: 22, color: isConnected ? c.violet : c.textSecondary),
                  const SizedBox(width: 8),
                  Text(
                    widget.peer.name,
                    style: GoogleFonts.manrope(
                      textStyle: TextStyle(
                        color: c.textPrimary,
                        fontSize: 16.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              GlassChip(
                label: isConnected ? 'Connected' : 'Offline',
                icon: isConnected ? Icons.link : Icons.link_off,
                accentColor: isConnected ? c.mint : c.textSecondary,
                filled: isConnected,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                updateTimeStr,
                style: TextStyle(color: c.textTertiary, fontSize: 12.5),
              ),
              const SizedBox(width: 8),
              Text('·', style: TextStyle(color: c.textTertiary)),
              const SizedBox(width: 8),
              Text(
                'Connection: ',
                style: TextStyle(color: c.textTertiary, fontSize: 12.5),
              ),
              Text(
                connQuality,
                style: TextStyle(color: qualityColor, fontSize: 12.5, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          if (isConnected && (dstate.batteryPct != null || dstate.storageTotalBytes != null)) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                batteryWidget,
                const SizedBox(width: 10),
              ],
            ),
            if (dstate.storageTotalBytes != null) ...[
              const SizedBox(height: 10),
              storageWidget,
            ],
          ],
          warningWidget,
          folderRollupWidget,
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              GlassButton(
                icon: Icons.send_outlined,
                label: 'Send files',
                accentColor: c.violet,
                enabled: isConnected,
                compact: true,
                style: GlassButtonStyle.tint,
                onTap: () {
                  Navigator.of(context).push(
                    PageRouteBuilder<void>(
                      pageBuilder: (ctx, _, secondary) => SendPanel(initialPeerId: widget.peer.deviceId),
                      transitionDuration: const Duration(milliseconds: 180),
                      reverseTransitionDuration: const Duration(milliseconds: 140),
                      transitionsBuilder: (_, animation, secondary, child) => FadeTransition(
                        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
                        child: child,
                      ),
                    ),
                  );
                },
              ),
              GlassButton(
                icon: Icons.content_copy_outlined,
                label: 'Send clipboard',
                accentColor: c.violet,
                enabled: isConnected,
                compact: true,
                style: GlassButtonStyle.tint,
                onTap: () async {
                  final ok = await state.sendClipboard(targetPeerId: widget.peer.deviceId);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(ok
                            ? 'Clipboard sent to ${widget.peer.name}'
                            : 'Failed to send clipboard (is it empty?)'),
                      ),
                    );
                  }
                },
              ),
              if (!isConnected)
                GlassButton(
                  icon: Icons.sync,
                  label: 'Reconnect',
                  accentColor: c.blue,
                  compact: true,
                  style: GlassButtonStyle.outline,
                  onTap: () async {
                    try {
                      await state.reconnectPeer(widget.peer);
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(e.toString())),
                        );
                      }
                    }
                  },
                ),
              if (isConnected) ...[
                () {
                  final hasFeature = state.peerHasFeature(widget.peer.deviceId, 'phone_alert_v1');
                  return GlassButton(
                    icon: _alerting ? Icons.hourglass_top : Icons.volume_up,
                    label: _alerting ? 'Alerting...' : 'Play alert',
                    accentColor: c.amber,
                    enabled: isConnected && hasFeature && !_alerting,
                    compact: true,
                    style: GlassButtonStyle.outline,
                    onTap: () => _triggerPhoneAlert(context, state),
                  );
                }(),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _triggerPhoneAlert(BuildContext ctx, AppState state) async {
    setState(() {
      _alerting = true;
    });

    final res = await state.playPhoneAlert(widget.peer.deviceId);

    if (mounted) {
      setState(() {
        _alerting = false;
      });

      String msg = '';
      switch (res) {
        case 'started':
          msg = 'Alert played successfully on ${widget.peer.name}.';
          break;
        case 'disabled':
          msg = '${widget.peer.name} has locating/play alerts disabled in settings.';
          break;
        case 'unsupported':
          msg = 'Locate alerts are not supported by the peer.';
          break;
        case 'offline':
          msg = 'Locate failed: Peer went offline.';
          break;
        case 'timeout':
          msg = 'Alert request timed out.';
          break;
        default:
          msg = 'Locate failed.';
      }

      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(content: Text(msg)),
      );
    }
  }
}

class _PhoneCardStatusDot extends StatelessWidget {
  const _PhoneCardStatusDot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }
}
