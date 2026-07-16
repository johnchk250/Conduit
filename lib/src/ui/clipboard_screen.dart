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
  DateTime? _lastReceivedAt;
  String? _lastReceivedFrom;
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
                          ? 'PC→phone auto · Phone→PC manual (tap below)'
                          : 'PC→phone auto · clipboard changes sync '
                              'automatically')
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

            // ---- Last received (content-free) ---------------------------------
            if (enabled)
              GlassPanel(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Last received',
                      style: AppTypography.manrope(
                        textStyle: TextStyle(
                          color: c.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    _lastReceivedAt != null
                        ? Text(
                            'From ${_lastReceivedFrom ?? "a device"} at '
                            '${_formatTime(_lastReceivedAt!)}',
                            style: AppTypography.inter(
                              textStyle: TextStyle(
                                  color: c.textPrimary, fontSize: 12.5),
                            ),
                          )
                        : Text(
                            'Nothing received yet',
                            style: AppTypography.inter(
                              textStyle: TextStyle(
                                  color: c.textSecondary, fontSize: 12.5),
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

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}
