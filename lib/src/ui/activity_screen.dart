import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../sync/engine.dart';
import 'glass.dart';

enum _FilterType { user, all, warnings }

class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  _FilterType _filter = _FilterType.user;

  // Cached filtered list — recomputed only when the source list length or
  // the selected filter changes, not on every AppState.notifyListeners().
  List<SyncEvent> _cachedEvents = const [];
  int _cachedSourceLength = -1;
  _FilterType _cachedFilter = _FilterType.user;

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

  List<SyncEvent> _buildFilteredList(List<SyncEvent> allEvents) {
    if (_filter == _FilterType.warnings) {
      return allEvents
          .where((e) =>
              e.level == SyncEventLevel.warn || e.level == SyncEventLevel.error)
          .toList(growable: false);
    } else if (_filter == _FilterType.user) {
      return allEvents
          .where((e) => !_isInternalMessage(e.message))
          .toList(growable: false);
    }
    return allEvents;
  }

  @override
  Widget build(BuildContext ctx) {
    final state = ctx.watch<AppState>();
    final c = GlassColors.of(ctx);
    final allEvents = state.events;

    // Only re-filter when something actually changed — the source length
    // or the user's selected filter tab. This avoids running toLowerCase()
    // + contains() × 5 on every AppState.notifyListeners() broadcast.
    if (allEvents.length != _cachedSourceLength || _filter != _cachedFilter) {
      _cachedEvents = _buildFilteredList(allEvents);
      _cachedSourceLength = allEvents.length;
      _cachedFilter = _filter;
    }
    final events = _cachedEvents;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            // ---- Fixed header (title + filter chips) -----------------------
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Navigator.canPop(context)
                        ? Padding(
                            padding: const EdgeInsets.only(bottom: 16),
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
                                    'Activity',
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
                          )
                        : const GlassPageTitle('Activity'),
                    // Filter chip row — GlassChip with filled: true for active
                    Row(
                      children: [
                        _filterChip(
                          c: c,
                          label: 'Activity',
                          active: _filter == _FilterType.user,
                          onTap: () =>
                              setState(() => _filter = _FilterType.user),
                        ),
                        const SizedBox(width: 8),
                        _filterChip(
                          c: c,
                          label: 'All events',
                          active: _filter == _FilterType.all,
                          onTap: () =>
                              setState(() => _filter = _FilterType.all),
                        ),
                        const SizedBox(width: 8),
                        _filterChip(
                          c: c,
                          label: 'Warnings',
                          active: _filter == _FilterType.warnings,
                          icon: _filter == _FilterType.warnings
                              ? Icons.warning_amber_rounded
                              : null,
                          accentColor: _filter == _FilterType.warnings
                              ? c.amber
                              : null,
                          onTap: () =>
                              setState(() => _filter = _FilterType.warnings),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),

            // ---- Event list or empty state ---------------------------------
            if (events.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                  child: Center(
                    child: GlassPanel(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.history, size: 48, color: c.textTertiary),
                          const SizedBox(height: 16),
                          Text(
                            'No logs match this filter',
                            style: TextStyle(
                              color: c.textPrimary,
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Sync events will appear here once folders are '
                            'paired and transferring.',
                            style: TextStyle(
                              color: c.textSecondary,
                              fontSize: 13,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                sliver: SliverList.separated(
                  itemCount: events.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (_, i) {
                    final e = events[i];
                    final accent = _accentFor(c, e.level);
                    return GlassListTile(
                      leadingIcon: _iconFor(e.level),
                      accentColor: accent,
                      title: _formatMessage(e.message),
                      subtitle:
                          '${_pairDisplayName(state, e.pairId)} · ${_fmtTime(e.time)}',
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---- Helpers ---------------------------------------------------------------

  Widget _filterChip({
    required GlassColors c,
    required String label,
    required bool active,
    required VoidCallback onTap,
    IconData? icon,
    Color? accentColor,
  }) {
    return GlassChip(
      label: label,
      icon: icon,
      accentColor: accentColor ?? (active ? c.violet : c.textSecondary),
      filled: active,
      onTap: onTap,
    );
  }

  Color _accentFor(GlassColors c, SyncEventLevel lvl) {
    switch (lvl) {
      case SyncEventLevel.info:
        return c.mint;
      case SyncEventLevel.warn:
        return c.amber;
      case SyncEventLevel.error:
        return c.danger;
    }
  }

  IconData _iconFor(SyncEventLevel lvl) {
    switch (lvl) {
      case SyncEventLevel.info:
        return Icons.check_circle_outline;
      case SyncEventLevel.warn:
        return Icons.warning_amber_rounded;
      case SyncEventLevel.error:
        return Icons.error_outline;
    }
  }

  String _fmtTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}
