import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../core/config_store.dart';
import '../net/transport.dart';
import 'clipboard_screen.dart';
import 'connection_doctor_screen.dart';
import 'remote_control_screen.dart';
import 'send_panel.dart';
import 'transfer_history_screen.dart';
import 'folder_setup/folder_setup_flow.dart';

class DeviceDetailScreen extends StatelessWidget {
  const DeviceDetailScreen({super.key, required this.peer});

  final PairedPeer peer;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final connection = state.connectionStateFor(peer.deviceId);
    final connected = connection.isConnected;
    final pairs = state.config.folderPairs
        .where((pair) => pair.peerDeviceId == peer.deviceId)
        .toList();
    final clipboardSupported =
        state.peerHasFeature(peer.deviceId, 'clipboard_v1');
    final remoteSupported =
        state.peerHasFeature(peer.deviceId, 'remote_control_v1');

    return Scaffold(
      appBar: AppBar(title: Text(peer.name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: Icon(
                connected ? Icons.link : Icons.link_off,
                color: connected ? Colors.green : Colors.orange,
              ),
              title: Text(connected ? 'Connected' : 'Offline'),
              subtitle: Text(
                connection.transport == null
                    ? 'No active transport'
                    : '${connection.transport!.label} transport',
              ),
              trailing: connected
                  ? OutlinedButton(
                      onPressed: () => state.disconnectPeer(peer.deviceId),
                      child: const Text('Disconnect'),
                    )
                  : FilledButton(
                      onPressed: () => state.reconnectPeer(peer),
                      child: const Text('Reconnect'),
                    ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Actions', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _ActionTile(
            icon: Icons.send_outlined,
            title: 'Send files',
            subtitle: 'Open the send flow for an ad-hoc transfer.',
            enabled: true,
            onTap: () => _push(context, const SendPanel()),
          ),
          _ActionTile(
            icon: Icons.create_new_folder_outlined,
            title: 'Set up a synced folder',
            subtitle: 'Choose a preset with this device preselected.',
            enabled: true,
            onTap: () => runFolderSetupFlow(
              context,
              preselectedPeerId: peer.deviceId,
            ),
          ),
          _ActionTile(
            icon: Icons.receipt_long_outlined,
            title: 'Transfer receipts',
            subtitle: 'View recent transfers involving this device.',
            enabled: true,
            onTap: () => _push(
              context,
              TransferHistoryScreen(peerId: peer.deviceId),
            ),
          ),
          _ActionTile(
            icon: Icons.content_copy_outlined,
            title: 'Clipboard',
            subtitle: clipboardSupported
                ? 'Share clipboard content with this device.'
                : 'This device has not advertised clipboard support.',
            enabled: clipboardSupported,
            onTap: () => _push(context, const ClipboardScreen()),
          ),
          _ActionTile(
            icon: Icons.settings_remote_outlined,
            title: 'Remote control',
            subtitle: remoteSupported
                ? 'Open device remote-control actions.'
                : 'This device has not advertised remote-control support.',
            enabled: remoteSupported,
            onTap: () => _push(context, const RemoteControlScreen()),
          ),
          _ActionTile(
            icon: Icons.health_and_safety_outlined,
            title: 'Connection Doctor',
            subtitle: 'Check discovery, transport, identity, and sync layers.',
            enabled: true,
            onTap: () => _push(
              context,
              ConnectionDoctorScreen(peerId: peer.deviceId),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Folder pairs (${pairs.length})',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (pairs.isEmpty)
            const Card(
              child: ListTile(
                leading: Icon(Icons.folder_off_outlined),
                title: Text('No folders use this device yet'),
              ),
            )
          else
            for (final pair in pairs)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(pair.name),
                  subtitle: Text(
                    '${pair.direction.label} · ${state.stateFor(pair.id)?.status ?? 'Idle'}',
                  ),
                ),
              ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: () => _confirmForget(context, state),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Forget device'),
          ),
        ],
      ),
    );
  }

  static void _push(BuildContext context, Widget child) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => child));
  }

  Future<void> _confirmForget(BuildContext context, AppState state) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Forget ${peer.name}?'),
        content: const Text(
          'The identity pin and saved endpoints will be removed. Existing folder pairs may need attention.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await state.unpairPeer(peer.deviceId);
      if (context.mounted) Navigator.of(context).pop();
    }
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          minVerticalPadding: 12,
          enabled: enabled,
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: enabled ? const Icon(Icons.chevron_right) : null,
          onTap: enabled ? onTap : null,
        ),
      );
}
