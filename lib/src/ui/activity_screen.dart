import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../sync/engine.dart';

enum _FilterType { user, all, warnings }

class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  _FilterType _filter = _FilterType.user;

  bool _isInternalMessage(String message) {
    final msg = message.toLowerCase();
    return msg.contains('seeded') ||
        msg.contains('watching "') ||
        msg.contains('pragma') ||
        msg.contains('integrity');
  }

  String _formatMessage(String message) {
    if (message.startsWith('V2 in sync (')) {
      final match = RegExp(r'\((\d+)\s+files?\)').firstMatch(message);
      if (match != null) {
        final count = match.group(1);
        return '$count files in sync';
      }
    }
    if (message.startsWith('Socket closed for')) {
      return message.replaceFirst('Socket closed for', 'Disconnected from');
    }
    return message;
  }

  String _pairDisplayName(AppState state, String pairId) {
    if (pairId.isEmpty || pairId == 'system') return 'System';
    final pairs = state.config.folderPairs.where((p) => p.id == pairId);
    if (pairs.isNotEmpty) {
      return pairs.first.name;
    }
    if (pairId.length > 8) {
      return 'Pair …${pairId.substring(pairId.length - 8)}';
    }
    return pairId;
  }

  @override
  Widget build(BuildContext ctx) {
    final state = ctx.watch<AppState>();
    final allEvents = state.events;

    // Filter events based on selection
    final List<SyncEvent> events;
    if (_filter == _FilterType.warnings) {
      events = allEvents
          .where((e) =>
              e.level == SyncEventLevel.warn || e.level == SyncEventLevel.error)
          .toList();
    } else if (_filter == _FilterType.user) {
      events = allEvents.where((e) => !_isInternalMessage(e.message)).toList();
    } else {
      events = allEvents;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(
              height: 1, color: Theme.of(ctx).colorScheme.outlineVariant),
        ),
      ),
      body: Column(
        children: [
          // Filter Chips Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('Activity'),
                  selected: _filter == _FilterType.user,
                  onSelected: (selected) {
                    if (selected) setState(() => _filter = _FilterType.user);
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('All events'),
                  selected: _filter == _FilterType.all,
                  onSelected: (selected) {
                    if (selected) setState(() => _filter = _FilterType.all);
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Warnings & Errors'),
                  selected: _filter == _FilterType.warnings,
                  onSelected: (selected) {
                    if (selected)
                      setState(() => _filter = _FilterType.warnings);
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: events.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.history,
                              size: 48,
                              color: Theme.of(ctx).colorScheme.outline),
                          const SizedBox(height: 16),
                          const Text(
                            'No logs match this filter',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Sync events will appear here once folders are paired and transferring.',
                            style: Theme.of(ctx).textTheme.bodySmall,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: events.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, indent: 56),
                    itemBuilder: (_, i) {
                      final e = events[i];
                      return ListTile(
                        leading: _iconFor(e.level),
                        title: Text(_formatMessage(e.message)),
                        subtitle: Text(
                          '${_pairDisplayName(state, e.pairId)} · ${_fmtTime(e.time)}',
                          style: Theme.of(ctx).textTheme.bodySmall,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Icon _iconFor(SyncEventLevel lvl) {
    switch (lvl) {
      case SyncEventLevel.info:
        return const Icon(Icons.check_circle_outline,
            color: Colors.blue, size: 22);
      case SyncEventLevel.warn:
        return const Icon(Icons.warning_amber, color: Colors.amber, size: 22);
      case SyncEventLevel.error:
        return const Icon(Icons.error_outline, color: Colors.red, size: 22);
    }
  }

  String _fmtTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}
