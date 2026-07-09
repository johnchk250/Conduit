import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';

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
    final clipboard = state.clipboard;
    final enabled = state.config.clipboardSyncEnabled;
    final hasPeer = clipboard?.hasConnectedPeer() ?? false;
    final isAndroid = state.identity.platform == 'android';

    return Scaffold(
      appBar: AppBar(title: const Text('Clipboard sync')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ---- Master toggle ------------------------------------------------
          _Card(
            child: SwitchListTile(
              title: const Text('Sync clipboard'),
              subtitle: Text(enabled
                  ? hasPeer
                      ? (isAndroid
                          ? 'PC→phone auto · Phone→PC manual (tap below)'
                          : 'PC→phone auto · clipboard changes sync automatically')
                      : 'Enabled, but no peer connected'
                  : 'Off — clipboard is not shared'),
              value: enabled,
              onChanged: (v) => state.setClipboardSyncEnabled(v),
              secondary: Icon(
                enabled ? Icons.link : Icons.link_off,
                color: enabled
                    ? Theme.of(ctx).colorScheme.primary
                    : Theme.of(ctx).colorScheme.outline,
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ---- Connected devices -------------------------------------------
          _Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.devices,
                          size: 18, color: Theme.of(ctx).colorScheme.outline),
                      const SizedBox(width: 8),
                      Text('Connected devices',
                          style: Theme.of(ctx).textTheme.titleSmall),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (hasPeer) ...[
                    for (final peer in state.connectedPeers)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          children: [
                            Icon(Icons.circle,
                                size: 8, color: Colors.green.shade600),
                            const SizedBox(width: 8),
                            Text(peer.name,
                                style: Theme.of(ctx).textTheme.bodyMedium),
                          ],
                        ),
                      ),
                  ] else
                    Text(
                      enabled
                          ? 'No peer connected — clipboard will sync when a peer connects'
                          : 'Enable clipboard sync to start',
                      style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(ctx).colorScheme.outline,
                          ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ---- Manual send (the streamlined flow) ---------------------------
          // Present on both platforms. On PC it's an explicit action; on phone
          // the QuickShare chip surfaces it with one tap from the copy action.
          if (enabled && hasPeer)
            _Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Send clipboard now',
                        style: Theme.of(ctx).textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Text(
                      'Reads your current clipboard and sends it to all connected devices.',
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                            color: Theme.of(ctx).colorScheme.outline,
                          ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _sending ? null : _sendClipboard,
                        icon: _sending
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.send),
                        label: Text(_sending
                            ? 'Sending…'
                            : _sendResultShown
                                ? 'Sent!'
                                : 'Send clipboard'),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ---- Last received (content-free) ---------------------------------
          if (enabled)
            _Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Last received',
                        style: Theme.of(ctx).textTheme.titleSmall),
                    const SizedBox(height: 4),
                    _lastReceivedAt != null
                        ? Text(
                            'From ${_lastReceivedFrom ?? "a device"} at '
                            '${_formatTime(_lastReceivedAt!)}',
                            style: Theme.of(ctx).textTheme.bodyMedium,
                          )
                        : Text(
                            'Nothing received yet',
                            style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                                  color: Theme.of(ctx).colorScheme.outline,
                                ),
                          ),
                  ],
                ),
              ),
            ),
        ],
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

/// A styled card matching the app's Material 3 card theme.
class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext ctx) {
    return Card(
      margin: EdgeInsets.zero,
      child: child,
    );
  }
}
