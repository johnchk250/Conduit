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
import 'glass.dart';

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
              Expanded(child: desktopPages[activeIndex]),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      // The nav bar floats above the content (its own blurred panel with
      // margin on all sides), so the body needs to paint underneath it.
      extendBody: true,
      body: GlassBackground(child: mobilePages[activeIndex]),
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
            icon: Icons.power_settings_new_outlined,
            selectedIcon: Icons.power_settings_new,
            label: 'Survival'),
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
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 110),
        children: [
          const GlassPageTitle('Overview'),
          GlassStatusBanner(
            title: state.isStarted ? 'Sync is running' : 'Starting up…',
            subtitle: state.isStarted
                ? 'Connected to $connectedCount of ${state.pairedPeers.length} paired device(s)'
                : 'Warming up identity and discovery',
            icon: state.isStarted ? Icons.check_circle : Icons.hourglass_top,
            accentColor: state.isStarted ? c.mint : c.amber,
          ),
          const SizedBox(height: 26),
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
                MaterialPageRoute(builder: (_) => const SendPanel()),
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

/// A compact, premium Settings Hub page for mobile users (Roadmap Phase 5).
/// Collapses "Send files", "Activity log", and "Keep alive" screens into one
/// easily accessible, clean and unified layout.
class _SettingsHubPage extends StatelessWidget {
  const _SettingsHubPage();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = GlassColors.of(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: Colors.transparent,
        foregroundColor: c.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
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
                MaterialPageRoute(builder: (_) => const ActivityScreen()),
              );
            },
          ),
          const SizedBox(height: 10),
          GlassListTile(
            leadingIcon: Icons.power_settings_new_outlined,
            accentColor: c.violet,
            title: 'Keep alive',
            subtitle: 'Execution controls and background battery settings',
            trailing:
                Icon(Icons.chevron_right, size: 20, color: c.textTertiary),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const BackgroundSurvivalScreen()),
              );
            },
          ),

          const SizedBox(height: 20),

          // ---- System (Android-only UI, but the section is always shown) ----
          GlassSectionLabel('System'),
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
          const SizedBox(height: 90),
        ],
      ),
    );
  }
}
