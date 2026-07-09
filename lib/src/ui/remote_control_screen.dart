import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';

/// Remote Control screen (Roadmap Phase 4).
///
/// Fits entirely on one screen — no scrolling. Layout:
///   • Slim status chip at the top
///   • Power card  (shutdown row + sleep/hibernate/cancel row)
///   • Media card  (prev / play-pause / next)
///   • Volume card (down / mute / up)
///
/// On Windows, shows a settings toggle instead of the control buttons.
class RemoteControlScreen extends StatefulWidget {
  const RemoteControlScreen({super.key});

  @override
  State<RemoteControlScreen> createState() => _RemoteControlScreenState();
}

class _RemoteControlScreenState extends State<RemoteControlScreen> {
  String? _lastSent;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final isAndroid = state.identity.platform == 'android';
    final hasPeer = state.connectedPeers.isNotEmpty;
    final remoteEnabled = state.remoteControlEnabled;
    final canSend = isAndroid && hasPeer;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Remote control'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(
              height: 1, color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ---- Status chip -----------------------------------------------
              _StatusChip(
                isAndroid: isAndroid,
                hasPeer: hasPeer,
                remoteEnabled: remoteEnabled,
                peerName: hasPeer ? state.connectedPeers.first.name : null,
              ),
              const SizedBox(height: 8),

              // ---- PC-only settings toggle -----------------------------------
              if (!isAndroid) ...[
                _CompactCard(
                  color: const Color(0xFF2979FF),
                  icon: Icons.settings_remote_outlined,
                  title: 'PC Settings',
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          remoteEnabled
                              ? 'Phone can send commands to this PC'
                              : 'Enable to allow phone to control this PC',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      Switch(
                        value: remoteEnabled,
                        onChanged: (v) => state.setRemoteControlEnabled(v),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
              ],

              // ---- Power card ------------------------------------------------
              Expanded(
                flex: 5,
                child: _CompactCard(
                  color: const Color(0xFFFF6F00),
                  icon: Icons.power_settings_new_rounded,
                  title: 'Power',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Shutdown chips row — all 6 in a single row
                      Row(
                        children: [
                          for (final min in [10, 20, 30, 40, 50, 60]) ...[
                            Expanded(
                              child: _ShutdownChip(
                                minutes: min,
                                enabled: canSend,
                                sent: _lastSent == 'shutdown_$min',
                                onTap: () => _confirmShutdown(state, min),
                              ),
                            ),
                            if (min != 60) const SizedBox(width: 4),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6),
                      // Sleep / Hibernate / Cancel in one row
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: _Btn(
                                icon: Icons.bedtime_outlined,
                                label: 'Sleep',
                                color: const Color(0xFF5C6BC0),
                                enabled: canSend,
                                sent: _lastSent == 'sleep',
                                onTap: () => _send(state, 'sleep'),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: _Btn(
                                icon: Icons.downloading_outlined,
                                label: 'Hibernate',
                                color: const Color(0xFF5C6BC0),
                                enabled: canSend,
                                sent: _lastSent == 'hibernate',
                                onTap: () => _send(state, 'hibernate'),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: _Btn(
                                icon: Icons.cancel_outlined,
                                label: 'Cancel shutdown',
                                color: const Color(0xFFE65100),
                                enabled: canSend,
                                sent: _lastSent == 'shutdown_cancel',
                                onTap: () => _send(state, 'shutdown_cancel'),
                                outlined: true,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),

              // ---- Media card ------------------------------------------------
              Expanded(
                flex: 3,
                child: _CompactCard(
                  color: const Color(0xFF00897B),
                  icon: Icons.music_note_rounded,
                  title: 'Media',
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _Btn(
                          icon: Icons.skip_previous_rounded,
                          label: 'Prev',
                          color: const Color(0xFF00897B),
                          enabled: canSend,
                          sent: _lastSent == 'media_prev',
                          onTap: () => _send(state, 'media_prev'),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        flex: 2,
                        child: _Btn(
                          icon: Icons.play_circle_rounded,
                          label: 'Play / Pause',
                          color: const Color(0xFF00897B),
                          enabled: canSend,
                          sent: _lastSent == 'media_play_pause',
                          onTap: () => _send(state, 'media_play_pause'),
                          primary: true,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _Btn(
                          icon: Icons.skip_next_rounded,
                          label: 'Next',
                          color: const Color(0xFF00897B),
                          enabled: canSend,
                          sent: _lastSent == 'media_next',
                          onTap: () => _send(state, 'media_next'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),

              // ---- Volume card -----------------------------------------------
              Expanded(
                flex: 3,
                child: _CompactCard(
                  color: const Color(0xFF1565C0),
                  icon: Icons.volume_up_rounded,
                  title: 'Volume',
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _Btn(
                          icon: Icons.volume_down_rounded,
                          label: 'Vol Down',
                          color: const Color(0xFF1565C0),
                          enabled: canSend,
                          sent: _lastSent == 'volume_down',
                          onTap: () => _send(state, 'volume_down'),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _Btn(
                          icon: Icons.volume_mute_rounded,
                          label: 'Mute',
                          color: const Color(0xFF1565C0),
                          enabled: canSend,
                          sent: _lastSent == 'volume_mute',
                          onTap: () => _send(state, 'volume_mute'),
                          primary: true,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _Btn(
                          icon: Icons.volume_up_rounded,
                          label: 'Vol Up',
                          color: const Color(0xFF1565C0),
                          enabled: canSend,
                          sent: _lastSent == 'volume_up',
                          onTap: () => _send(state, 'volume_up'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Actions ---------------------------------------------------------------

  Future<void> _send(AppState state, String name) async {
    await state.sendRemoteCommand(name);
    if (!mounted) return;
    setState(() => _lastSent = name);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && _lastSent == name) setState(() => _lastSent = null);
    });
  }

  Future<void> _confirmShutdown(AppState state, int minutes) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        icon: const Icon(Icons.power_settings_new_rounded,
            size: 36, color: Color(0xFFFF6F00)),
        title: Text('Shutdown in $minutes min?'),
        content: Text(
          'This will schedule your PC to shut down in $minutes minute${minutes == 1 ? '' : 's'}.\n\n'
          'Use "Cancel shutdown" to abort if you change your mind.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFFF6F00)),
            onPressed: () => Navigator.of(dctx).pop(true),
            icon: const Icon(Icons.power_settings_new_rounded),
            label: Text('Shutdown in $minutes min'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) await _send(state, 'shutdown_$minutes');
  }
}

// ---- Widgets -----------------------------------------------------------------

/// Slim one-line status indicator at the top.
class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.isAndroid,
    required this.hasPeer,
    required this.remoteEnabled,
    this.peerName,
  });
  final bool isAndroid;
  final bool hasPeer;
  final bool remoteEnabled;
  final String? peerName;

  @override
  Widget build(BuildContext context) {
    final Color color;
    final IconData icon;
    final String label;

    if (!isAndroid) {
      color = remoteEnabled ? Colors.green.shade700 : Colors.grey;
      icon = remoteEnabled ? Icons.check_circle_outline : Icons.block_outlined;
      label =
          remoteEnabled ? 'Remote control enabled' : 'Remote control disabled';
    } else if (!hasPeer) {
      color = Colors.grey;
      icon = Icons.phonelink_off_outlined;
      label = 'No PC connected — open Conduit on your PC';
    } else {
      color = Colors.green.shade700;
      icon = Icons.phonelink_outlined;
      label = 'Connected to ${peerName ?? 'your PC'}';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact card with a small colored header row and arbitrary child.
class _CompactCard extends StatelessWidget {
  const _CompactCard({
    required this.color,
    required this.icon,
    required this.title,
    required this.child,
  });
  final Color color;
  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: color.withValues(alpha: 0.25)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Section header
            Row(
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

/// Compact shutdown time chip — text only, no avatar.
class _ShutdownChip extends StatelessWidget {
  const _ShutdownChip({
    required this.minutes,
    required this.enabled,
    required this.sent,
    required this.onTap,
  });
  final int minutes;
  final bool enabled;
  final bool sent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFFFF6F00);
    final label = sent ? '✓' : '${minutes}m';
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          color: sent
              ? color.withValues(alpha: 0.22)
              : enabled
                  ? color.withValues(alpha: 0.1)
                  : Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest
                      .withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: sent
                ? color.withValues(alpha: 0.6)
                : color.withValues(alpha: 0.25),
          ),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: enabled ? color : Theme.of(context).colorScheme.outline,
                fontWeight: FontWeight.w700,
              ),
        ),
      ),
    );
  }
}

/// Compact icon+label button that fills its parent height.
class _Btn extends StatefulWidget {
  const _Btn({
    required this.icon,
    required this.label,
    required this.color,
    required this.enabled,
    required this.sent,
    required this.onTap,
    this.primary = false,
    this.outlined = false,
  });
  final IconData icon;
  final String label;
  final Color color;
  final bool enabled;
  final bool sent;
  final VoidCallback onTap;
  final bool primary;
  final bool outlined;

  @override
  State<_Btn> createState() => _BtnState();
}

class _BtnState extends State<_Btn> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 80));
    _scale = Tween<double>(begin: 1, end: 0.93)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.primary
        ? widget.color
        : widget.sent
            ? widget.color.withValues(alpha: 0.22)
            : widget.enabled
                ? widget.color.withValues(alpha: 0.1)
                : Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: 0.5);
    final fg = widget.primary
        ? Colors.white
        : widget.enabled
            ? widget.color
            : Theme.of(context).colorScheme.outline;
    final border = widget.outlined
        ? Border.all(color: widget.color.withValues(alpha: 0.45))
        : null;

    return GestureDetector(
      onTapDown: widget.enabled ? (_) => _ctrl.forward() : null,
      onTapUp: widget.enabled
          ? (_) {
              _ctrl.reverse();
              widget.onTap();
            }
          : null,
      onTapCancel: () => _ctrl.reverse(),
      child: ScaleTransition(
        scale: _scale,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            border: border,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                widget.sent ? Icons.check_rounded : widget.icon,
                size: 22,
                color: fg,
              ),
              const SizedBox(height: 4),
              Text(
                widget.sent ? 'Sent!' : widget.label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w600,
                      fontSize: 10,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
