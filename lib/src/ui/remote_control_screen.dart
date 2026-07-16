import 'package:flutter/material.dart';
import 'typography.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../core/config_store.dart';
import '../net/transport.dart';
import 'glass.dart';

/// Remote Control screen (Roadmap Phase 4).
///
/// Compact glass layout designed to fit on a single screen page view without scrolling:
///   • GlassStatusBanner — status at the top
///   • PC-only: GlassListTile toggle (Windows only)
///   • Power GlassPanel — 1 row of 6 compact minute chips + 1 row of 3 action buttons
///   • Media GlassPanel — horizontal Prev / Play-Pause / Next buttons
///   • Volume GlassPanel — horizontal Down / Mute / Up buttons
class RemoteControlScreen extends StatefulWidget {
  const RemoteControlScreen({super.key});

  @override
  State<RemoteControlScreen> createState() => _RemoteControlScreenState();
}

class _RemoteControlScreenState extends State<RemoteControlScreen> {
  String? _lastSent;
  String? _selectedPeerId;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = GlassColors.of(context);
    final isAndroid = state.identity.platform == 'android';
    final connectedPcs = state.connectedPeers
        .where((peer) => peer.platform == 'windows')
        .toList(growable: false);
    final selectedPeer = _selectedPeer(connectedPcs);
    final hasPeer = selectedPeer != null;
    final remoteEnabled = state.remoteControlEnabled;
    final canSend = isAndroid && hasPeer;

    // ---- Banner config -------------------------------------------------------
    final String bannerTitle;
    final String bannerSubtitle;
    final IconData bannerIcon;
    final Color bannerAccent;

    if (!isAndroid) {
      bannerTitle =
          remoteEnabled ? 'Remote control enabled' : 'Remote control disabled';
      bannerSubtitle = remoteEnabled
          ? 'Phone can send commands to this PC'
          : 'Enable below to allow your phone to control this PC';
      bannerIcon = Icons.settings_remote_rounded;
      bannerAccent = remoteEnabled ? c.mint : c.textTertiary;
    } else if (!hasPeer) {
      bannerTitle = 'No PC connected';
      bannerSubtitle = 'Open Conduit on your PC to start';
      bannerIcon = Icons.phonelink_off_rounded;
      bannerAccent = c.textTertiary;
    } else {
      bannerTitle = 'Controlling ${selectedPeer.name}';
      bannerSubtitle = connectedPcs.length > 1
          ? 'Commands are sent only to the selected PC'
          : 'Commands are sent only to this PC';
      bannerIcon = Icons.phonelink_rounded;
      bannerAccent = c.mint;
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ListView(
          // Use a compact padding so everything fits on a single page view.
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            const GlassPageTitle('Remote'),

            // ---- Status banner ---------------------------------------------
            GlassStatusBanner(
              title: bannerTitle,
              subtitle: bannerSubtitle,
              icon: bannerIcon,
              accentColor: bannerAccent,
            ),
            const SizedBox(height: 10),

            if (isAndroid && connectedPcs.isNotEmpty) ...[
              GlassPanel(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Command destination',
                      style: AppTypography.manrope(
                        textStyle: TextStyle(
                          color: c.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      key: ValueKey(selectedPeer!.deviceId),
                      initialValue: selectedPeer.deviceId,
                      decoration: const InputDecoration(
                        labelText: 'Selected PC',
                        prefixIcon: Icon(Icons.computer_rounded),
                      ),
                      items: connectedPcs
                          .map(
                            (peer) => DropdownMenuItem(
                              value: peer.deviceId,
                              child: Text(peer.name),
                            ),
                          )
                          .toList(),
                      onChanged: (peerId) =>
                          setState(() => _selectedPeerId = peerId),
                    ),
                    const SizedBox(height: 10),
                    _SelectedPcDetails(peer: selectedPeer, state: state),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],

            // ---- PC-only toggle (Windows only) -----------------------------
            if (!isAndroid) ...[
              GlassListTile(
                leadingIcon: Icons.settings_remote_rounded,
                accentColor: remoteEnabled ? c.violet : c.textSecondary,
                title: 'Allow phone control',
                subtitle: remoteEnabled
                    ? 'Phone can send commands to this PC'
                    : 'Enable to let your phone control this PC',
                trailing: Switch(
                  value: remoteEnabled,
                  onChanged: (v) => state.setRemoteControlEnabled(v),
                  activeThumbColor: c.violet,
                ),
              ),
              const SizedBox(height: 10),
            ],

            // ---- Power section ---------------------------------------------
            const GlassSectionLabel('Power'),
            GlassPanel(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Row 1: 6 compact minute buttons in a single row
                  Row(
                    children: [
                      for (final min in [10, 20, 30, 40, 50, 60]) ...[
                        _minuteButton(
                          context,
                          min,
                          canSend,
                          c,
                          selectedPeer?.deviceId,
                        ),
                        if (min != 60) const SizedBox(width: 4),
                      ],
                    ],
                  ),
                  const SizedBox(height: 10),
                  // Row 2: Sleep / Hibernate / Cancel
                  Row(
                    children: [
                      Expanded(
                        child: GlassButton(
                          icon: Icons.bedtime_rounded,
                          label: 'Sleep',
                          accentColor: c.blue,
                          compact: true,
                          enabled: canSend,
                          selected: _lastSent == 'sleep',
                          onTap: () =>
                              _send(state, 'sleep', selectedPeer!.deviceId),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: GlassButton(
                          icon: Icons.downloading_rounded,
                          label: 'Hibernate',
                          accentColor: c.blue,
                          compact: true,
                          enabled: canSend,
                          selected: _lastSent == 'hibernate',
                          onTap: () =>
                              _send(state, 'hibernate', selectedPeer!.deviceId),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: GlassButton(
                          icon: Icons.cancel_rounded,
                          label: 'Cancel',
                          accentColor: c.danger,
                          compact: true,
                          style: GlassButtonStyle.outline,
                          enabled: canSend,
                          selected: _lastSent == 'shutdown_cancel',
                          onTap: () => _send(
                              state, 'shutdown_cancel', selectedPeer!.deviceId),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // ---- Media section ---------------------------------------------
            const GlassSectionLabel('Media'),
            GlassPanel(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: GlassButton(
                      icon: Icons.skip_previous_rounded,
                      label: 'Prev',
                      accentColor: c.teal,
                      compact: true,
                      enabled: canSend,
                      selected: _lastSent == 'media_prev',
                      onTap: () =>
                          _send(state, 'media_prev', selectedPeer!.deviceId),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    flex: 3,
                    child: GlassButton(
                      icon: Icons.play_circle_rounded,
                      label: 'Play / Pause',
                      accentColor: c.teal,
                      style: GlassButtonStyle.primary,
                      compact: true,
                      enabled: canSend,
                      selected: _lastSent == 'media_play_pause',
                      onTap: () => _send(
                          state, 'media_play_pause', selectedPeer!.deviceId),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    flex: 2,
                    child: GlassButton(
                      icon: Icons.skip_next_rounded,
                      label: 'Next',
                      accentColor: c.teal,
                      compact: true,
                      enabled: canSend,
                      selected: _lastSent == 'media_next',
                      onTap: () =>
                          _send(state, 'media_next', selectedPeer!.deviceId),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // ---- Volume section ---------------------------------------------
            const GlassSectionLabel('Volume'),
            GlassPanel(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: GlassButton(
                      icon: Icons.volume_down_rounded,
                      label: 'Down',
                      accentColor: c.violet,
                      compact: true,
                      enabled: canSend,
                      selected: _lastSent == 'volume_down',
                      onTap: () =>
                          _send(state, 'volume_down', selectedPeer!.deviceId),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: GlassButton(
                      icon: Icons.volume_mute_rounded,
                      label: 'Mute',
                      accentColor: c.violet,
                      style: GlassButtonStyle.primary,
                      compact: true,
                      enabled: canSend,
                      selected: _lastSent == 'volume_mute',
                      onTap: () =>
                          _send(state, 'volume_mute', selectedPeer!.deviceId),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: GlassButton(
                      icon: Icons.volume_up_rounded,
                      label: 'Up',
                      accentColor: c.violet,
                      compact: true,
                      enabled: canSend,
                      selected: _lastSent == 'volume_up',
                      onTap: () =>
                          _send(state, 'volume_up', selectedPeer!.deviceId),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Actions ---------------------------------------------------------------

  PairedPeer? _selectedPeer(List<PairedPeer> connectedPcs) {
    if (connectedPcs.isEmpty) return null;
    for (final peer in connectedPcs) {
      if (peer.deviceId == _selectedPeerId) return peer;
    }
    return connectedPcs.first;
  }

  Future<void> _send(
    AppState state,
    String name,
    String targetPeerId,
  ) async {
    await state.sendRemoteCommand(name, targetPeerId: targetPeerId);
    if (!mounted) return;
    setState(() => _lastSent = name);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && _lastSent == name) setState(() => _lastSent = null);
    });
  }

  Future<void> _confirmShutdown(
    AppState state,
    int minutes,
    String targetPeerId,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        icon: const Icon(Icons.power_settings_new_rounded,
            size: 36, color: Color(0xFFFF6F00)),
        title: Text('Shutdown in $minutes min?'),
        content: Text(
          'This will schedule your PC to shut down in $minutes '
          'minute${minutes == 1 ? '' : 's'}.\n\n'
          'Use "Cancel" in the Power section to abort if you change your mind.',
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
    if (ok == true && mounted) {
      await _send(state, 'shutdown_$minutes', targetPeerId);
    }
  }

  // ---- Local helpers -----------------------------------------------------------

  Widget _minuteButton(
    BuildContext context,
    int min,
    bool enabled,
    GlassColors c,
    String? targetPeerId,
  ) {
    final selected = _lastSent == 'shutdown_$min';
    final color = c.amber;
    return Expanded(
      child: InkWell(
        onTap: enabled
            ? () => _confirmShutdown(
                  context.read<AppState>(),
                  min,
                  targetPeerId!,
                )
            : null,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? color.withValues(alpha: 0.25)
                : enabled
                    ? color.withValues(alpha: 0.1)
                    : c.textTertiary.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: color.withValues(alpha: selected ? 0.6 : 0.25),
            ),
          ),
          child: Text(
            selected ? '✓' : '${min}m',
            style: AppTypography.manrope(
              textStyle: TextStyle(
                color: enabled ? color : c.textTertiary,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectedPcDetails extends StatelessWidget {
  const _SelectedPcDetails({required this.peer, required this.state});

  final PairedPeer peer;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final c = GlassColors.of(context);
    final connection = state.connectionStateFor(peer.deviceId);
    final folderCount = state.config.folderPairs
        .where((pair) => pair.peerDeviceId == peer.deviceId)
        .length;
    return Row(
      children: [
        Icon(Icons.verified_user_outlined, color: c.mint, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                peer.name,
                style: TextStyle(
                  color: c.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                '${connection.transport?.label ?? 'Connected'} · '
                '${peer.deviceId} · '
                '$folderCount folder pair${folderCount == 1 ? '' : 's'}',
                style: TextStyle(color: c.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
