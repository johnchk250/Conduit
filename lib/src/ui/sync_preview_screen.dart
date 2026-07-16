import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controllers.dart';
import '../protocol/wire.dart';
import '../sync/sync_preview.dart';

class SyncPreviewScreen extends StatefulWidget {
  const SyncPreviewScreen({super.key, required this.pair});

  final FolderPair pair;

  @override
  State<SyncPreviewScreen> createState() => _SyncPreviewScreenState();
}

class _SyncPreviewScreenState extends State<SyncPreviewScreen> {
  SyncPreview? _preview;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool refreshLocal = true}) async {
    setState(() {
      _preview = null;
      _error = null;
    });
    try {
      final value = await context
          .read<FolderSyncController>()
          .buildPreview(widget.pair.id, refreshLocal: refreshLocal);
      if (mounted) setState(() => _preview = value);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Sync preview — ${widget.pair.name}')),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 42),
              const SizedBox(height: 12),
              Text('Preview unavailable: $_error', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    final preview = _preview;
    if (preview == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final receive = preview.items
        .where((item) =>
            item.direction == SyncPreviewDirection.receive &&
            item.action != SyncPreviewAction.advertiseDelete)
        .toList(growable: false);
    final send = preview.items
        .where((item) =>
            item.direction == SyncPreviewDirection.send &&
            item.action != SyncPreviewAction.advertiseDelete)
        .toList(growable: false);
    final deletes = preview.items
        .where((item) => item.action == SyncPreviewAction.advertiseDelete)
        .toList(growable: false);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Based on snapshots captured at '
                          '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(preview.capturedAt.toLocal()))}',
                        ),
                      ),
                      Chip(label: Text(_freshnessLabel(preview.freshness))),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    children: [
                      _total('To this device', preview.totals.receiveCount,
                          preview.totals.receiveBytes),
                      _total('To peer', preview.totals.sendCount,
                          preview.totals.sendBytes),
                      _count('Conflicts', preview.totals.conflictCount),
                      _count('Deferred', preview.totals.bluetoothDeferredCount),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (preview.freshness == SyncPreviewFreshness.unavailable)
            const Card(
              child: ListTile(
                leading: Icon(Icons.cloud_off_outlined),
                title: Text('Peer snapshot unavailable'),
                subtitle:
                    Text('Reconnect the peer to build a trustworthy preview.'),
              ),
            ),
          _section('Receive', receive),
          _section('Send', send),
          _section('Deletions to advertise', deletes),
          for (final limitation in preview.limitations)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                limitation,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh preview'),
              ),
              FilledButton.icon(
                onPressed: () async {
                  await context
                      .read<FolderSyncController>()
                      .syncNow(widget.pair.id);
                  if (mounted) await _load(refreshLocal: false);
                },
                icon: const Icon(Icons.sync),
                label: const Text('Sync now'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _section(String title, List<SyncPreviewItem> items) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final item in items.take(200))
            ListTile(
              dense: true,
              title: Text(item.relPath),
              subtitle: Text(
                '${_actionLabel(item.action)} · ${_bytes(item.sizeBytes)}'
                '${item.transportDisposition == SyncPreviewTransportDisposition.deferredOnBluetooth ? ' · Deferred on Bluetooth' : ''}',
              ),
            ),
          if (items.length > 200)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('${items.length - 200} more items'),
            ),
        ],
      ),
    );
  }

  Widget _total(String label, int count, int bytes) =>
      Text('$label: $count · ${_bytes(bytes)}');
  Widget _count(String label, int count) => Text('$label: $count');

  String _freshnessLabel(SyncPreviewFreshness value) => switch (value) {
        SyncPreviewFreshness.live => 'Live',
        SyncPreviewFreshness.staleLocal => 'Local changed',
        SyncPreviewFreshness.stalePeer => 'Peer changed',
        SyncPreviewFreshness.offlineCached => 'Offline snapshot',
        SyncPreviewFreshness.unavailable => 'Unavailable',
      };

  String _actionLabel(SyncPreviewAction value) => switch (value) {
        SyncPreviewAction.receiveCreate ||
        SyncPreviewAction.sendCreate =>
          'Create',
        SyncPreviewAction.receiveUpdate ||
        SyncPreviewAction.sendUpdate =>
          'Update',
        SyncPreviewAction.receiveConflictWinner ||
        SyncPreviewAction.sendConflictWinner =>
          'Conflict winner',
        SyncPreviewAction.advertiseDelete => 'Delete advertisement',
      };

  String _bytes(int value) {
    if (value >= 1024 * 1024) {
      return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (value >= 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
    return '$value B';
  }
}
