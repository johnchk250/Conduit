import 'package:flutter/material.dart';
import 'typography.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../controllers/app_controllers.dart';
import '../protocol/wire.dart';
import '../sync/vault_log.dart';
import 'glass.dart';

/// Roadmap Phase 6.4 — version-restore UI, edit-only scope. Restoring a
/// taxed/deleted file is out of scope.
///
/// Lists every entry in this pair's vault catalog
/// ([AppState.vaultEntries]) and lets the user restore one back to its
/// live path ([AppState.restoreVersion]).
class VersionHistoryScreen extends StatefulWidget {
  final FolderPair pair;

  const VersionHistoryScreen({super.key, required this.pair});

  @override
  State<VersionHistoryScreen> createState() => _VersionHistoryScreenState();
}

class _VersionHistoryScreenState extends State<VersionHistoryScreen> {
  List<VaultLogEntry>? _entries;
  String? _error;
  final Set<String> _deleting = {};
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _entries = null;
      _error = null;
    });
    try {
      final entries = await context
          .read<FolderSyncController>()
          .versionHistory(widget.pair.id);
      if (!mounted) return;
      setState(() => _entries = entries);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  String _fmtBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  String _fmtTimestamp(DateTime dt) {
    final local = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  Future<void> _confirmAndRestore(VaultLogEntry entry) async {
    // Dialog stays standard Material per the project rule:
    // "Modal surfaces (AlertDialog, SnackBar, BottomSheet) are deliberately LEFT as standard Material"
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Restore this version?'),
        content: Text(
          'This returns "${entry.relPath}" to the local folder. The current '
          'file is saved first, and this recovery copy remains for 14 days. '
          '${widget.pair.direction == SyncDirection.receiveOnly ? 'This receive-only pair will keep the resurrection local.' : 'The restored file can sync back to the peer and recreate it on other devices.'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await context
          .read<FolderSyncController>()
          .restoreVersion(widget.pair.id, entry.entryId);
      if (result == RestoreResult.sourceMissing ||
          result == RestoreResult.permissionLost ||
          result == RestoreResult.invalidPath ||
          result == RestoreResult.failed) {
        throw StateError(_restoreFailure(result));
      }
      messenger.showSnackBar(
        SnackBar(content: Text('Restored ${entry.relPath}')),
      );
      await _load();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Restore failed: $e')),
      );
    }
  }

  Future<void> _confirmAndDelete(VaultLogEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Delete this archived version?'),
        content: Text(
          'This permanently removes the ${_fmtBytes(entry.sizeBytes)} recovery '
          'copy of "${entry.relPath}" from this device. It cannot be restored '
          'afterward.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('Delete permanently'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _deleting.add(entry.entryId));
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await context
          .read<FolderSyncController>()
          .deleteVersion(widget.pair.id, entry.entryId);
      if (result.failed > 0) {
        throw StateError('The archived file could not be deleted.');
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result.deleted > 0
                ? 'Deleted archived version and freed '
                    '${_fmtBytes(result.reclaimedBytes)}'
                : 'Removed missing version from history',
          ),
        ),
      );
      await _load();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Delete failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _deleting.remove(entry.entryId));
    }
  }

  Future<void> _confirmAndClearAll() async {
    final entries = _entries;
    if (entries == null || entries.isEmpty) return;
    final totalBytes =
        entries.fold<int>(0, (total, entry) => total + entry.sizeBytes);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Clear all version history?'),
        content: Text(
          'This permanently removes ${entries.length} archived '
          '${entries.length == 1 ? 'version' : 'versions'} '
          '(${_fmtBytes(totalBytes)}) from this device. None of them can be '
          'restored afterward.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _clearing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await context
          .read<FolderSyncController>()
          .clearVersionHistory(widget.pair.id);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result.failed == 0
                ? 'Cleared version history and freed '
                    '${_fmtBytes(result.reclaimedBytes)}'
                : 'Deleted ${result.deleted} archived versions; '
                    '${result.failed} could not be removed',
          ),
        ),
      );
      await _load();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Clear history failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = GlassColors.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ---- Pushed title bar with back button -------------------------
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 16, 20, 16),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new_rounded),
                    color: c.textPrimary,
                    iconSize: 20,
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Version history — ${widget.pair.name}',
                      style: AppTypography.manrope(
                        textStyle: TextStyle(
                          color: c.textPrimary,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_entries?.isNotEmpty == true)
                    IconButton(
                      tooltip: 'Clear all archived versions',
                      onPressed: _clearing ? null : _confirmAndClearAll,
                      icon: _clearing
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.delete_sweep_outlined),
                    ),
                ],
              ),
            ),

            // ---- Body content ----------------------------------------------
            Expanded(child: _buildBody(c)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(GlassColors c) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: GlassPanel(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 40, color: c.danger),
                const SizedBox(height: 12),
                Text(
                  'Could not load version history',
                  style: TextStyle(
                      color: c.textPrimary, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  _error!,
                  style: TextStyle(color: c.textSecondary, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                GlassButton(
                  icon: Icons.refresh_rounded,
                  label: 'Retry',
                  accentColor: c.violet,
                  onTap: _load,
                  compact: true,
                ),
              ],
            ),
          ),
        ),
      );
    }

    final entries = _entries;
    if (entries == null) {
      return Center(
        child: GlassPanel(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: c.violet),
                const SizedBox(height: 12),
                Text(
                  'Loading history…',
                  style: TextStyle(color: c.textSecondary, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: GlassPanel(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.history_rounded, size: 44, color: c.textTertiary),
                const SizedBox(height: 12),
                Text(
                  'No previous versions yet',
                  style: TextStyle(
                      color: c.textPrimary, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  'A version is saved here automatically whenever a synced file '
                  'is about to be overwritten by an edit coming from the other device. '
                  'Previous versions and files deleted by sync are kept on this device for 14 days.',
                  style: TextStyle(color: c.textSecondary, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      color: c.violet,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        itemCount: entries.length + 1,
        separatorBuilder: (_, __) => const SizedBox(height: 6),
        itemBuilder: (ctx, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Previous versions and files deleted by sync are kept on this device for 14 days.',
                style: TextStyle(color: c.textSecondary, fontSize: 13),
              ),
            );
          }
          final e = entries[i - 1];
          final deleting = _deleting.contains(e.entryId);
          return GlassListTile(
            title: e.relPath,
            subtitle:
                '${_reasonLabel(e)} · ${_fmtTimestamp(e.timestamp)} · ${_fmtBytes(e.sizeBytes)}'
                '${e.restoredAt == null ? '' : ' · Restored ${_fmtTimestamp(e.restoredAt!)}'}',
            subtitleMono: true,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GlassButton(
                  icon: Icons.settings_backup_restore_rounded,
                  label: 'Restore',
                  accentColor: c.violet,
                  compact: true,
                  enabled: !deleting && !_clearing,
                  onTap: () => _confirmAndRestore(e),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Delete archived version',
                  color: c.danger,
                  onPressed:
                      deleting || _clearing ? null : () => _confirmAndDelete(e),
                  icon: deleting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_outline_rounded),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _reasonLabel(VaultLogEntry entry) => switch (entry.reason) {
        VaultReason.peerDelete => 'Deleted by sync',
        VaultReason.restoreReplacement => 'Restore replacement',
        VaultReason.conflictReplacement => 'Conflict version',
        VaultReason.incomingOverwrite => 'Previous version',
      };

  String _restoreFailure(RestoreResult result) => switch (result) {
        RestoreResult.sourceMissing => 'The recovery copy is missing.',
        RestoreResult.permissionLost =>
          'Folder permission is no longer available.',
        RestoreResult.invalidPath => 'The stored path is invalid.',
        _ => 'The version could not be restored.',
      };
}
