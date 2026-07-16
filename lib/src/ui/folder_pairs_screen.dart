import 'dart:io';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../app_state.dart';
import '../platform/saf_access.dart';
import '../protocol/wire.dart';
import 'glass.dart';
import 'version_history_screen.dart';

/// Fast 180 ms fade push — avoids the heavy 300 ms slide of [MaterialPageRoute]
/// on top of backdrop-blur glass surfaces.
PageRoute<T> _fadeRoute<T>(WidgetBuilder builder) => PageRouteBuilder<T>(
      pageBuilder: (ctx, _, secondary) => builder(ctx),
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 140),
      transitionsBuilder: (_, animation, secondary, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      ),
    );

/// Folder pairs list + add/invite/accept flow + per-pair detail view.
///
/// NOTE: the folder-invite listener (that shows the accept/decline dialog when
/// the peer sends a folderInvite) has been moved UP to [DashboardScreen] (the
/// always-mounted root). It used to live here, but this widget is only in the
/// tree while the Folders tab is selected, so invites arriving on any other
/// tab were silently dropped (logged, never surfaced). The dialog widget
/// itself ([_InviteDialog]) is now in dashboard_screen.dart too, for the same
/// reason — keeping the listener and the dialog in the same file makes the
/// dependency obvious.
///
/// The three flows:
///   1. Initiator: tap "Add synced folder" → pick local folder + direction +
///      name → save locally → tap "Send to peer" → engine sends folderInvite.
///   2. Peer (incoming): DashboardScreen listens to AppState.pendingInvites
///      → shows accept dialog with a folder picker → saves the pair with the
///      SHARED pairId from the invite → engine sends folderAccept.
///   3. Either side: tap a pair's "Details" to see its status, last-synced
///      timestamp, and the current file list (like any standard sync app).
class FolderPairsScreen extends StatefulWidget {
  const FolderPairsScreen({super.key});

  @override
  State<FolderPairsScreen> createState() => _FolderPairsScreenState();
}

class _FolderPairsScreenState extends State<FolderPairsScreen> {
  @override
  Widget build(BuildContext ctx) {
    final state = ctx.watch<AppState>();
    final c = GlassColors.of(ctx);
    final pairs = state.config.folderPairs;
    // Shell matches _OverviewPage's pattern (GlassPageTitle inline, no own
    // AppBar) rather than _SettingsHubPage's older AppBar co    // THINKING.md, "Design-system choice" for why.
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: _GlassFab(
        label: 'Add synced folder',
        icon: Icons.add_rounded,
        accentColor: c.violet,
        onTap: () => _showPairDialog(ctx, state, null),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      body: SafeArea(
        child: ListView(
          // Same content padding recipe as _OverviewPage — see that file's
          // comment for the reference source (`.content{padding:26px 20px
          // 100px}`, extra bottom room for the floating GlassNavBar).
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 100),
          children: [
            const GlassPageTitle('Folders'),
            GlassListTile(
              leadingIcon:
                  state.isPaused ? Icons.pause_circle_outline : Icons.sync,
              accentColor: state.isPaused ? c.amber : c.mint,
              title: 'Sync enabled',
              subtitle: state.isPaused
                  ? 'Sync is paused. Tap to resume.'
                  : 'Sync is running. Tap to pause.',
              trailing: Switch(
                value: !state.isPaused,
                onChanged: (v) {
                  if (state.isPaused) {
                    state.resumeSync();
                  } else {
                    state.pauseSync();
                  }
                },
                activeColor: c.mint,
              ),
              onTap: () {
                if (state.isPaused) {
                  state.resumeSync();
                } else {
                  state.pauseSync();
                }
              },
            ),
            const SizedBox(height: 20),
            if (pairs.isEmpty)
              _emptyState(ctx, c)
            else ...[
              const GlassSectionLabel('Folder pairs'),
              for (final p in pairs)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _FolderPairCard(
                    pair: p,
                    state: state,
                    onDetails: () => Navigator.of(ctx).push(
                      _fadeRoute((_) => _PairDetailScreen(pair: p)),
                    ),
                    onSyncNow: () => _syncNow(ctx, state, p),
                    onEdit: () => _showPairDialog(ctx, state, p),
                    onRemove: () => _confirmRemove(ctx, state, p.id),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _emptyState(BuildContext ctx, GlassColors c) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 30),
      child: GlassPanel(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_copy_outlined, size: 56, color: c.textTertiary),
            const SizedBox(height: 16),
            Text(
              'No folders yet',
              style: GoogleFonts.manrope(
                textStyle: TextStyle(
                  color: c.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Tap "Add synced folder", pick a folder on this device, then '
              'send it to a paired device. The other device picks where the '
              'files should go, and syncing starts.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                textStyle: TextStyle(color: c.textSecondary, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _syncNow(
      BuildContext ctx, AppState state, FolderPair pair) async {
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
          content: Text('Syncing "${pair.name}"…'),
          duration: const Duration(seconds: 1)),
    );
    await state.syncFolderNow(pair);
  }

  Future<void> _confirmRemove(
      BuildContext ctx, AppState state, String id) async {
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: const Text('Remove folder pair?'),
        content: const Text(
            'This stops syncing the folder. Your files stay on both devices.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('Cancel')),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await state.removeFolderPair(id);
    }
  }

  Future<void> _showPairDialog(
    BuildContext ctx,
    AppState state,
    FolderPair? existing,
  ) async {
    final isAndroid = state.identity.platform == 'android';
    final hasPeer = state.connectedPeers.isNotEmpty;
    final nameCtl = TextEditingController(text: existing?.name ?? '');
    final pathCtl = TextEditingController(text: existing?.localPath ?? '');
    var direction = existing?.direction ?? SyncDirection.twoWay;

    await showDialog<void>(
      context: ctx,
      builder: (dctx) => StatefulBuilder(
        builder: (sctx, setState) => AlertDialog(
          title:
              Text(existing == null ? 'Add synced folder' : 'Edit folder pair'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: nameCtl,
                  decoration: const InputDecoration(
                      labelText: 'Name', hintText: 'e.g. Work Documents'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: pathCtl,
                        readOnly: true,
                        decoration: InputDecoration(
                          labelText: isAndroid
                              ? 'Folder (SAF tree URI)'
                              : 'Folder path',
                          hintText:
                              isAndroid ? 'Tap browse to pick' : 'D:\\Sync',
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
                        if (path != null) {
                          pathCtl.text = path;
                          if (nameCtl.text.isEmpty) {
                            nameCtl.text =
                                path.split(Platform.pathSeparator).last;
                          }
                          setState(() {});
                        }
                      },
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Browse'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<SyncDirection>(
                  value: direction,
                  decoration: const InputDecoration(labelText: 'Direction'),
                  items: SyncDirection.values
                      .map((d) =>
                          DropdownMenuItem(value: d, child: Text(d.label)))
                      .toList(),
                  onChanged: (v) =>
                      setState(() => direction = v ?? SyncDirection.twoWay),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(sctx),
                child: const Text('Cancel')),
            if (existing != null)
              FilledButton(
                onPressed: () async {
                  final name = nameCtl.text.trim();
                  final path = pathCtl.text.trim();
                  if (name.isEmpty || path.isEmpty) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(
                          content:
                              Text('Please provide both name and folder.')),
                    );
                    return;
                  }
                  final updated = existing.copyWith(
                      name: name, localPath: path, direction: direction);
                  await state.addFolderPair(updated);
                  if (sctx.mounted) Navigator.pop(sctx);
                },
                child: const Text('Save'),
              )
            else
              FilledButton.icon(
                onPressed: hasPeer
                    ? () async {
                        final name = nameCtl.text.trim();
                        final path = pathCtl.text.trim();
                        if (name.isEmpty || path.isEmpty) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(
                                content: Text(
                                    'Please provide both name and folder.')),
                          );
                          return;
                        }
                        final peerId = state.connectedPeers.first.deviceId;
                        final pair = FolderPair(
                          id: const Uuid().v4(),
                          name: name,
                          localPath: path,
                          direction: direction,
                          peerDeviceId: peerId,
                        );
                        await state.addFolderPair(pair);
                        // Send the invite so the peer can pick its own folder.
                        state.invitePeerToFolder(pair.id);
                        if (sctx.mounted) {
                          Navigator.pop(sctx);
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(
                                content: Text(
                                    'Invite sent. Waiting for the other device.')),
                          );
                        }
                      }
                    : null,
                icon: const Icon(Icons.send),
                label: const Text('Send to peer'),
              ),
          ],
        ),
      ),
    );
  }
}

/// A glassmorphic floating-action-button pill that matches the design system.
/// Uses [BackdropFilter] for the frosted-glass blur, a violet gradient fill,
/// and the same border/radius language as [GlassPanel].
class _GlassFab extends StatefulWidget {
  const _GlassFab({
    required this.label,
    required this.icon,
    required this.accentColor,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color accentColor;
  final VoidCallback onTap;

  @override
  State<_GlassFab> createState() => _GlassFabState();
}

class _GlassFabState extends State<_GlassFab>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 90));
    _scale = Tween<double>(begin: 1.0, end: 0.95)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.accentColor;
    final platform = Theme.of(context).platform;
    final isMobile =
        platform == TargetPlatform.android || platform == TargetPlatform.iOS;

    final container = Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(50),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: isMobile ? 0.85 : 0.22),
            accent.withValues(alpha: isMobile ? 0.70 : 0.08),
          ],
        ),
        border: Border.all(
          color: accent.withValues(alpha: isMobile ? 0.95 : 0.38),
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: isMobile ? 0.35 : 0.25),
            blurRadius: 20,
            spreadRadius: 2,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(widget.icon, color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Text(
            widget.label,
            style: GoogleFonts.manrope(
              textStyle: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
          ),
        ],
      ),
    );

    Widget buttonBody = container;
    if (!isMobile) {
      buttonBody = ClipRRect(
        borderRadius: BorderRadius.circular(50),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: container,
        ),
      );
    }

    return GestureDetector(
      onTapDown: (_) => _ctrl.forward(),
      onTapUp: (_) {
        _ctrl.reverse();
        widget.onTap();
      },
      onTapCancel: () => _ctrl.reverse(),
      child: ScaleTransition(
        scale: _scale,
        child: buttonBody,
      ),
    );
  }
}

/// One folder pair's row on the Folders tab: a [GlassListTile] header (tap
/// to expand/collapse) plus, when expanded, a second [GlassPanel] directly
/// beneath it holding progress/last-synced info and the Details/Sync-now/
/// Edit/Remove actions. See THINKING.md ("Folder pairs: the one real
/// judgment call this pass") for why this shape was chosen over collapsing
/// straight into [_PairDetailScreen] on tap.
class _FolderPairCard extends StatefulWidget {
  const _FolderPairCard({
    required this.pair,
    required this.state,
    required this.onDetails,
    required this.onSyncNow,
    required this.onEdit,
    required this.onRemove,
  });

  final FolderPair pair;
  final AppState state;
  final VoidCallback onDetails;
  final VoidCallback onSyncNow;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  State<_FolderPairCard> createState() => _FolderPairCardState();
}

class _FolderPairCardState extends State<_FolderPairCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final c = GlassColors.of(context);
    final p = widget.pair;
    final st = widget.state.stateFor(p.id);
    final status = st?.status ?? 'Idle';

    // Same status -> dot-color/live mapping _OverviewPage uses for its own
    // folder-pair rows — kept identical rather than reinventing a second
    // status vocabulary for this screen (see THINKING.md).
    final Color dotColor;
    final bool live;
    if (status == 'Error') {
      dotColor = c.danger;
      live = false;
    } else if (status == 'Paused') {
      dotColor = c.amber;
      live = false;
    } else if (status.startsWith('Idle') || status == 'Peer offline') {
      dotColor = c.textTertiary;
      live = false;
    } else {
      dotColor = c.mint;
      live = true;
    }

    final pendingInvite =
        p.peerDeviceId != null && (st?.status?.contains('Waiting') ?? false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassListTile(
          leadingIcon: Icons.folder,
          accentColor: c.violet,
          title: p.name,
          subtitle: '${p.direction.label} · $status',
          subtitleDotColor: dotColor,
          subtitleLive: live,
          trailing: AnimatedRotation(
            turns: _expanded ? 0.5 : 0,
            duration: const Duration(milliseconds: 180),
            child: Icon(Icons.expand_more, color: c.textTertiary),
          ),
          onTap: () => setState(() => _expanded = !_expanded),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: GlassPanel(
              // blur:false — same perf rule as GlassListTile: this panel
              // multiplies per expanded pair, so it skips the real
              // BackdropFilter (see glass.dart's `blur` param doc).
              blur: false,
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.localPath,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.jetBrainsMono(
                      textStyle: TextStyle(
                        color: c.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  if (st != null) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: st.progress,
                              minHeight: 4,
                              color: c.violet,
                              backgroundColor: c.violet.withValues(alpha: 0.15),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          status,
                          style: GoogleFonts.inter(
                            textStyle: TextStyle(
                              color: c.textSecondary,
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (st.lastSyncedAt != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Last synced: ${_fmtDateTime(st.lastSyncedAt!)}',
                        style: GoogleFonts.inter(
                          textStyle: TextStyle(
                            color: c.textTertiary,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ],
                  if (pendingInvite) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Icon(Icons.hourglass_top, size: 15, color: c.amber),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Invite sent — waiting for the other device to '
                            'accept.',
                            style: GoogleFonts.inter(
                              textStyle: TextStyle(
                                color: c.textSecondary,
                                fontSize: 11.5,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: GlassButton(
                          icon: Icons.list_alt,
                          label: 'Details',
                          accentColor: c.violet,
                          compact: true,
                          onTap: widget.onDetails,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: GlassButton(
                          icon: Icons.sync,
                          label: 'Sync now',
                          accentColor: c.teal,
                          compact: true,
                          onTap: widget.onSyncNow,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: GlassButton(
                          icon: Icons.edit_outlined,
                          label: 'Edit',
                          accentColor: c.textSecondary,
                          style: GlassButtonStyle.outline,
                          compact: true,
                          onTap: widget.onEdit,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: GlassButton(
                          icon: Icons.delete_outline,
                          label: 'Remove',
                          accentColor: c.danger,
                          style: GlassButtonStyle.outline,
                          compact: true,
                          onTap: widget.onRemove,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

String _fmtDateTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

/// Per-folder detail screen: status, last-synced timestamp, direction, and
/// the current file list under the pair's local root.
class _PairDetailScreen extends StatefulWidget {
  const _PairDetailScreen({required this.pair});
  final FolderPair pair;

  @override
  State<_PairDetailScreen> createState() => _PairDetailScreenState();
}

class _PairDetailScreenState extends State<_PairDetailScreen> {
  List<String>? _files;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final state = context.read<AppState>();
      final files = await state.fs.listFiles(widget.pair.localPath);
      files.sort();
      if (!mounted) return;
      setState(() {
        _files = files;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext ctx) {
    final state = context.watch<AppState>();
    final st = state.stateFor(widget.pair.id);
    // Re-derive from live config (not the immutable widget.pair) so the
    // ignore-rules summary below reflects a save immediately, instead of
    // only after this screen is reopened. Falls back to widget.pair if the
    // pair was removed while this screen is open.
    final currentPair = state.config.folderPairs
            .cast<FolderPair?>()
            .firstWhere((p) => p?.id == widget.pair.id, orElse: () => null) ??
        widget.pair;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.pair.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadFiles,
            tooltip: 'Refresh file list',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _kv('Direction', widget.pair.direction.label),
          _kv('Local path', widget.pair.localPath),
          _kv('Status', st?.status ?? 'Idle'),
          _kv(
            'Last synced',
            st?.lastSyncedAt != null
                ? _fmtDateTime(st!.lastSyncedAt!)
                : 'never',
          ),
          if (widget.pair.peerDeviceId != null)
            _kv('Paired with', widget.pair.peerDeviceId!),
          if (currentPair.ignoreGlobs.isNotEmpty ||
              currentPair.ignoreExtensions.isNotEmpty ||
              currentPair.maxFileSizeBytes != null)
            _kv('Ignore rules', _ignoreRulesSummary(currentPair)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () =>
                      _showIgnoreRulesDialog(ctx, state, currentPair),
                  icon: const Icon(Icons.rule_folder_outlined),
                  label: const Text('Ignore rules'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.push(
                    ctx,
                    _fadeRoute((_) => VersionHistoryScreen(pair: currentPair)),
                  ),
                  icon: const Icon(Icons.history),
                  label: const Text('Restore versions'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Text('Files (${_files?.length ?? 0})',
                  style: Theme.of(ctx).textTheme.titleMedium),
              const Spacer(),
              if (_loading)
                const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          const SizedBox(height: 8),
          if (_error != null)
            Card(
              color: Theme.of(ctx).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!,
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ),
            )
          else if (_files == null || _files!.isEmpty)
            const Card(
              child: ListTile(
                leading: Icon(Icons.folder_off_outlined),
                title: Text('No files'),
                subtitle: Text('The folder is empty or could not be read.'),
              ),
            )
          else
            Card(
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _files!.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, indent: 56),
                itemBuilder: (_, i) {
                  final rel = _files![i];
                  return ListTile(
                    dense: true,
                    leading:
                        const Icon(Icons.insert_drive_file_outlined, size: 20),
                    title: Text(rel,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13)),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(k, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Expanded(
              child: Text(v,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 12))),
        ],
      ),
    );
  }

  String _ignoreRulesSummary(FolderPair pair) {
    final parts = <String>[];
    if (pair.ignoreGlobs.isNotEmpty) {
      parts.add('${pair.ignoreGlobs.length} pattern'
          '${pair.ignoreGlobs.length == 1 ? '' : 's'}');
    }
    if (pair.ignoreExtensions.isNotEmpty) {
      parts.add('${pair.ignoreExtensions.length} extension'
          '${pair.ignoreExtensions.length == 1 ? '' : 's'}');
    }
    if (pair.maxFileSizeBytes != null) {
      parts.add('max ${_fmtBytes(pair.maxFileSizeBytes!)}');
    }
    return parts.join(', ');
  }

  String _fmtBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  /// Roadmap Phase 6.2 — ignore rules editor. Purely local per pair (see
  /// wire.dart doc comment on why this isn't peer-negotiated). Saving calls
  /// [AppState.updateIgnoreRules], which restarts this pair's watcher so
  /// the new rules take effect immediately rather than after an app
  /// restart.
  Future<void> _showIgnoreRulesDialog(
    BuildContext ctx,
    AppState state,
    FolderPair pair,
  ) async {
    final globsCtl = TextEditingController(text: pair.ignoreGlobs.join('\n'));
    final extCtl =
        TextEditingController(text: pair.ignoreExtensions.join('\n'));
    final sizeCtl = TextEditingController(
      text: pair.maxFileSizeBytes != null
          ? (pair.maxFileSizeBytes! / (1024 * 1024)).toStringAsFixed(0)
          : '',
    );

    await showDialog<void>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: const Text('Ignore rules'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Matching files are never synced. Files already synced when '
                'a rule is added keep their last-synced copy on both '
                'devices — they are frozen in place, not deleted.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: globsCtl,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Glob patterns (one per line)',
                  hintText: 'node_modules/**\n*.tmp',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: extCtl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Extensions (one per line)',
                  hintText: '.tmp\n.log',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: sizeCtl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Max file size in MB (blank = no limit)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final globs = globsCtl.text
                  .split('\n')
                  .map((s) => s.trim())
                  .where((s) => s.isNotEmpty)
                  .toList();
              final exts = extCtl.text
                  .split('\n')
                  .map((s) => s.trim())
                  .where((s) => s.isNotEmpty)
                  .toList();
              final sizeText = sizeCtl.text.trim();
              int? maxBytes;
              if (sizeText.isNotEmpty) {
                final mb = double.tryParse(sizeText);
                if (mb == null || mb <= 0) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(
                        content: Text('Max file size must be a positive '
                            'number, or left blank.')),
                  );
                  return;
                }
                maxBytes = (mb * 1024 * 1024).round();
              }
              await state.updateIgnoreRules(
                pair.id,
                ignoreGlobs: globs,
                ignoreExtensions: exts,
                maxFileSizeBytes: maxBytes,
              );
              if (dctx.mounted) Navigator.pop(dctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
