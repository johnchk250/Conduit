import 'dart:async';

import 'package:flutter/material.dart';
import 'typography.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import 'glass.dart';

/// Clipboard sync screen (Roadmap Phase 2).
///
/// Shows the on/off toggle (off by default for privacy — clipboard can contain
/// passwords / 2FA codes), connection status, and a "Send clipboard" button for
/// manual phone→PC sends. Displays only metadata (text length, last-received
/// timestamp), never the actual clipboard content.
///
/// Reads [AppState]; calls only public methods. Pure UI — engine-safe.
class ClipboardScreen extends StatefulWidget {
  const ClipboardScreen({super.key});

  @override
  State<ClipboardScreen> createState() => _ClipboardScreenState();
}

class _ClipboardScreenState extends State<ClipboardScreen> {
  bool _sending = false;
  bool _sendResultShown = false;

  @override
  Widget build(BuildContext ctx) {
    final state = ctx.watch<AppState>();
    final c = GlassColors.of(ctx);
    final clipboard = state.clipboard;
    final enabled = state.config.clipboardSyncEnabled;
    final hasPeer = clipboard?.hasConnectedPeer() ?? false;
    final isAndroid = state.identity.platform == 'android';
    final lastReceivedAt = clipboard?.lastReceivedAt;
    final lastReceivedFrom =
        _peerName(state, clipboard?.lastReceivedPeerId);
    final lastSentAt = clipboard?.lastSentAt;
    final lastError = clipboard?.lastError;

    // Shell matches _OverviewPage's pattern — see THINKING.md.
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 32),
          children: [
            const GlassPageTitle('Clipboard'),

            // ---- Master toggle ---------------------------------------------
            GlassListTile(
              leadingIcon: enabled ? Icons.link : Icons.link_off,
              accentColor: enabled ? c.violet : c.textSecondary,
              title: 'Sync clipboard',
              subtitle: enabled
                  ? hasPeer
                      ? (isAndroid
                          ? 'Receive from PC automatically · Phone→PC manual'
                          : 'Watching this PC clipboard automatically · '
                              'incoming clipboard is applied automatically')
                      : 'Enabled, but no peer connected'
                  : 'Off — clipboard is not shared',
              trailing: Switch(
                value: enabled,
                onChanged: (v) => state.setClipboardSyncEnabled(v),
                activeThumbColor: c.violet,
              ),
            ),
            const SizedBox(height: 12),

            // ---- Connected devices ------------------------------------------
            GlassPanel(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.devices, size: 17, color: c.textTertiary),
                      const SizedBox(width: 8),
                      Text(
                        'Connected devices',
                        style: AppTypography.manrope(
                          textStyle: TextStyle(
                            color: c.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (hasPeer) ...[
                    for (final peer in state.connectedPeers)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          children: [
                            Container(
                              width: 5,
                              height: 5,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: c.mint,
                                boxShadow: [
                                  BoxShadow(
                                    color: c.mint.withValues(alpha: 0.9),
                                    blurRadius: 6,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              peer.name,
                              style: AppTypography.inter(
                                textStyle: TextStyle(
                                  color: c.textPrimary,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ] else
                    Text(
                      enabled
                          ? 'No peer connected — clipboard will sync when a '
                              'peer connects'
                          : 'Enable clipboard sync to start',
                      style: AppTypography.inter(
                        textStyle:
                            TextStyle(color: c.textSecondary, fontSize: 12.5),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // ---- Manual send (the streamlined flow) --------------------------
            // Present on both platforms. On PC it's an explicit action; on
            // phone the QuickShare chip surfaces it with one tap from the
            // copy action.
            if (enabled && hasPeer) ...[
              GlassPanel(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Send clipboard now',
                      style: AppTypography.manrope(
                        textStyle: TextStyle(
                          color: c.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Reads your current clipboard and sends it to all '
                      'connected devices.',
                      style: AppTypography.inter(
                        textStyle:
                            TextStyle(color: c.textSecondary, fontSize: 12),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // GlassButton's built-in `selected` state already
                    // renders a checkmark + "Sent!" — reused directly
                    // instead of building a separate result indicator.
                    // The original's inline CircularProgressIndicator
                    // while sending isn't reproduced (GlassButton has no
                    // spinner slot); disabling the button + an icon swap
                    // to Icons.sync communicates the busy state instead,
                    // a small, deliberate simplification.
                    GlassButton(
                      icon: _sending ? Icons.sync : Icons.send,
                      label: _sending ? 'Sending…' : 'Send clipboard',
                      accentColor: c.violet,
                      style: GlassButtonStyle.primary,
                      enabled: !_sending,
                      selected: _sendResultShown,
                      onTap: _sendClipboard,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],

            // ---- Live, content-free diagnostics -----------------------------
            if (enabled) ...[
              GlassPanel(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Clipboard status',
                      style: AppTypography.manrope(
                        textStyle: TextStyle(
                          color: c.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _statusRow(
                      c,
                      icon: isAndroid
                          ? Icons.phone_android_rounded
                          : Icons.visibility_outlined,
                      label: isAndroid
                          ? 'Automatic watcher'
                          : 'Desktop watcher',
                      value: isAndroid
                          ? 'Incoming only'
                          : (clipboard?.isPolling == true ? 'Running' : 'Idle'),
                    ),
                    const SizedBox(height: 7),
                    _statusRow(
                      c,
                      icon: Icons.upload_rounded,
                      label: 'Last sent',
                      value: lastSentAt == null
                          ? 'Nothing sent yet'
                          : _formatTime(lastSentAt),
                    ),
                    const SizedBox(height: 7),
                    _statusRow(
                      c,
                      icon: Icons.download_rounded,
                      label: 'Last received',
                      value: lastReceivedAt == null
                          ? 'Nothing received yet'
                          : '${lastReceivedFrom ?? "a device"} · '
                              '${_formatTime(lastReceivedAt)}',
                    ),
                  ],
                ),
              ),
              if (lastError != null) ...[
                const SizedBox(height: 12),
                GlassListTile(
                  leadingIcon: Icons.error_outline_rounded,
                  accentColor: c.danger,
                  title: 'Clipboard error',
                  subtitle: lastError,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _sendClipboard() async {
    setState(() {
      _sending = true;
      _sendResultShown = false;
    });
    try {
      final state = context.read<AppState>();
      final ok = await state.sendClipboard();
      if (mounted) {
        setState(() => _sendResultShown = ok);
        if (!ok) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'Nothing to send — clipboard is empty or no peer connected'),
              duration: Duration(seconds: 2),
            ),
          );
        }
        // Clear the "Sent!" label after a brief moment.
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) setState(() => _sendResultShown = false);
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _sendResultShown = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to send clipboard'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Widget _statusRow(
    GlassColors c, {
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Row(
      children: [
        Icon(icon, size: 16, color: c.textTertiary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: AppTypography.inter(
              textStyle: TextStyle(color: c.textSecondary, fontSize: 12.5),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: AppTypography.inter(
              textStyle: TextStyle(
                color: c.textPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }

  String? _peerName(AppState state, String? peerId) {
    if (peerId == null) return null;
    for (final peer in state.config.pairedPeers) {
      if (peer.deviceId == peerId) return peer.name;
    }
    return peerId;
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}
