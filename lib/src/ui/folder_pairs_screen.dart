import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../app_state.dart';
import '../platform/saf_access.dart';
import '../protocol/wire.dart';
import '../sync/engine.dart';
import 'version_history_screen.dart';

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
    final pairs = state.config.folderPairs;
    return Scaffold(
      appBar: AppBar(title: const Text('Folder pairs')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showPairDialog(ctx, state, null),
        icon: const Icon(Icons.add),
        label: const Text('Add synced folder'),
      ),
      body: pairs.isEmpty
          ? _emptyState(ctx)
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: pairs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final p = pairs[i];
                final st = state.stateFor(p.id);
                return Card(
                  child: ExpansionTile(
                    leading: _SyncBadge(
                      state: st,
                      isPeerConnected: p.peerDeviceId != null &&
                          state.isPeerConnected(p.peerDeviceId!),
                    ),
                    title: Text(p.name),
                    subtitle: Text(
                      '${p.direction.label}\n${p.localPath}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      if (st != null) ...[
                        Row(
                          children: [
                            Expanded(
                              child: LinearProgressIndicator(
                                value: st.progress,
                                backgroundColor: Theme.of(ctx)
                                    .colorScheme
                                    .surfaceContainerHighest,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(st.status ?? 'Idle'),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (st.lastSyncedAt != null)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Last synced: ${_fmtDateTime(st.lastSyncedAt!)}',
                              style: Theme.of(ctx).textTheme.bodySmall,
                            ),
                          ),
                        const SizedBox(height: 12),
                      ],
                      // Pending-invite indicator for pairs the peer hasn't
                      // accepted yet.
                      if (p.peerDeviceId != null &&
                          st?.status?.contains('Waiting') == true)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              const Icon(Icons.hourglass_top, size: 16),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Invite sent — waiting for the other device to accept.',
                                  style: Theme.of(ctx).textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ),
                        ),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => Navigator.of(ctx).push(
                                MaterialPageRoute(
                                  builder: (_) => _PairDetailScreen(pair: p),
                                ),
                              ),
                              icon: const Icon(Icons.list_alt),
                              label: const Text('Details'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _syncNow(ctx, state, p),
                              icon: const Icon(Icons.sync),
                              label: const Text('Sync now'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _showPairDialog(ctx, state, p),
                              icon: const Icon(Icons.edit_outlined),
                              label: const Text('Edit'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.outlined(
                            onPressed: () => _confirmRemove(ctx, state, p.id),
                            icon: const Icon(Icons.delete_outline),
                            tooltip: 'Remove',
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Widget _emptyState(BuildContext ctx) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_copy_outlined,
                size: 64, color: Theme.of(ctx).colorScheme.outline),
            const SizedBox(height: 16),
            Text('No folders yet', style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'Tap "Add synced folder", pick a folder on this device, then '
              'send it to a paired device. The other device picks where the '
              'files should go, and syncing starts.',
              textAlign: TextAlign.center,
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
                    MaterialPageRoute(
                      builder: (_) =>
                          VersionHistoryScreen(pair: currentPair),
                    ),
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
    final globsCtl =
        TextEditingController(text: pair.ignoreGlobs.join('\n'));
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

class _SyncBadge extends StatefulWidget {
  final PairSyncState? state;
  final bool isPeerConnected;

  const _SyncBadge({required this.state, required this.isPeerConnected});

  @override
  State<_SyncBadge> createState() => _SyncBadgeState();
}

class _SyncBadgeState extends State<_SyncBadge>
    with SingleTickerProviderStateMixin {
  late AnimationController _rotationController;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    _updateRotation();
  }

  @override
  void didUpdateWidget(covariant _SyncBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateRotation();
  }

  void _updateRotation() {
    final isSyncing = widget.state != null &&
        (widget.state!.scanning || widget.state!.transferring);
    if (isSyncing) {
      if (!_rotationController.isAnimating) {
        _rotationController.repeat();
      }
    } else {
      _rotationController.stop();
    }
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.state;
    final isConnected = widget.isPeerConnected;

    if (st == null || !isConnected) {
      return const CircleAvatar(
        backgroundColor: Colors.grey,
        child: Icon(Icons.folder_off_outlined, color: Colors.white, size: 20),
      );
    }

    final isSyncing = st.scanning || st.transferring;
    final isError = st.status == 'Error';
    final isSynced = st.status == 'Idle' && st.lastSyncedAt != null;

    if (isSyncing) {
      return RotationTransition(
        turns: _rotationController,
        child: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Icon(
            Icons.sync,
            color: Theme.of(context).colorScheme.onPrimaryContainer,
            size: 20,
          ),
        ),
      );
    } else if (isError) {
      return CircleAvatar(
        backgroundColor: Colors.amber.shade800,
        child: const Icon(Icons.warning_amber_rounded,
            color: Colors.white, size: 20),
      );
    } else if (isSynced) {
      return CircleAvatar(
        backgroundColor: Colors.green.shade600,
        child: const Icon(Icons.check, color: Colors.white, size: 20),
      );
    } else {
      return CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
        child: Icon(
          Icons.folder_open_outlined,
          color: Theme.of(context).colorScheme.onSecondaryContainer,
          size: 20,
        ),
      );
    }
  }
}
