import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
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
    // Dialog stays standard Material per the project rule:
    // "Modal surfaces (AlertDialog, SnackBar, BottomSheet) are deliberately LEFT as standard Material"
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
                      'Versions — ${widget.pair.name}',
                      style: GoogleFonts.manrope(
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
                  'is about to be overwritten by an edit coming from the other device.',
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
        itemCount: entries.length,
        separatorBuilder: (_, __) => const SizedBox(height: 6),
        itemBuilder: (ctx, i) {
          final e = entries[i];
          return GlassListTile(
            title: e.relPath,
            subtitle: '${_fmtTimestamp(e.timestamp)} · ${_fmtBytes(e.sizeBytes)}',
            subtitleMono: true,
            trailing: GlassButton(
              icon: Icons.settings_backup_restore_rounded,
              label: 'Restore',
              accentColor: c.violet,
              compact: true,
              onTap: () => _confirmAndRestore(e),
            ),
          );
        },
      ),
    );
  }
}
