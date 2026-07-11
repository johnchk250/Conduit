import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../protocol/wire.dart';
import '../sync/vault_log.dart';

/// Roadmap Phase 6.4 — version-restore UI, edit-only scope. Restoring a
/// *deleted* file is explicitly out of scope for this pass (it would
/// require touching `_applyRemoteTombstone`, which is on the project's
/// do-not-touch list — see PROGRESS.md 2026-07-11).
///
/// Lists every entry in this pair's vault catalog
/// ([AppState.vaultEntries]) and lets the user restore one back to its
/// live path ([AppState.restoreVersion]). The catalog only ever contains
/// files that were locally overwritten by an incoming sync from the peer
/// — see block_transfer.dart's `_replacePartWithFinal` — so an empty list
/// here is the common case for a pair that's never had a same-file
/// edit-conflict.
class VersionHistoryScreen extends StatefulWidget {
  final FolderPair pair;

  const VersionHistoryScreen({super.key, required this.pair});

  @override
  State<VersionHistoryScreen> createState() => _VersionHistoryScreenState();
}

class _VersionHistoryScreenState extends State<VersionHistoryScreen> {
  List<VaultLogEntry>? _entries;
  String? _error;

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
      final entries =
          await context.read<AppState>().vaultEntries(widget.pair);
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Restore this version?'),
        content: Text(
          'This replaces the current "${entry.relPath}" with the version '
          'from ${_fmtTimestamp(entry.timestamp)}. The current file is '
          'vaulted first, so this itself can be undone from this same '
          'screen afterward.',
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
      await context.read<AppState>().restoreVersion(widget.pair, entry);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Restore versions — ${widget.pair.name}')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Could not load version history: $_error'),
        ),
      );
    }
    final entries = _entries;
    if (entries == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (entries.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No previous versions yet. A version is saved here '
            'automatically whenever a synced file is about to be '
            'overwritten by an edit coming from the other device.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: entries.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (ctx, i) {
          final e = entries[i];
          return ListTile(
            title: Text(
              e.relPath,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
            subtitle: Text('${_fmtTimestamp(e.timestamp)} · '
                '${_fmtBytes(e.sizeBytes)}'),
            trailing: OutlinedButton(
              onPressed: () => _confirmAndRestore(e),
              child: const Text('Restore'),
            ),
          );
        },
      ),
    );
  }
}
