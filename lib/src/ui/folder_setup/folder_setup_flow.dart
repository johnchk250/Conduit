import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/app_controllers.dart';
import '../../platform/saf_access.dart';
import '../../protocol/wire.dart';
import '../../sync/folder_preset.dart';

Future<bool> runFolderSetupFlow(
  BuildContext context, {
  String? preselectedPeerId,
  VoidCallback? onCustom,
}) async {
  final connections = context.read<ConnectionController>().snapshot;
  final platform =
      context.read<FolderSyncController>().appState.identity.platform;
  final available = folderPresets
      .where((preset) => preset.supports(platform))
      .toList(growable: false);
  final preset = await showDialog<FolderPreset>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: const Text('Choose a folder preset'),
      children: [
        for (final candidate in available)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, candidate),
            child: ListTile(
              leading: Icon(_icon(candidate.iconKey)),
              title: Text(candidate.title),
              subtitle: Text(candidate.description),
            ),
          ),
      ],
    ),
  );
  if (preset == null || !context.mounted) return false;
  if (preset.id == FolderPresetId.custom) {
    onCustom?.call();
    return false;
  }

  var peerId = preselectedPeerId;
  peerId ??= await showDialog<String>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: const Text('Choose destination device'),
      children: [
        for (final summary in connections.peers)
          SimpleDialogOption(
            onPressed: () =>
                Navigator.pop(dialogContext, summary.peer.deviceId),
            child: ListTile(
              leading: const Icon(Icons.devices_outlined),
              title: Text(summary.peer.name),
              subtitle: Text(summary.peer.deviceId),
            ),
          ),
      ],
    ),
  );
  if (peerId == null || !context.mounted) return false;
  final peer = connections.peers
      .where((summary) => summary.peer.deviceId == peerId)
      .map((summary) => summary.peer)
      .firstOrNull;
  if (peer == null) return false;

  final path = Platform.isAndroid
      ? await SafFileSystemAccess.pickTree(initialHint: preset.sourceHint)
      : await FilePicker.platform.getDirectoryPath(
          initialDirectory: preset.sourceHint,
        );
  if (path == null || !context.mounted) return false;

  final nameController = TextEditingController(text: preset.suggestedName);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Review ${preset.title}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Folder name'),
            ),
            const SizedBox(height: 16),
            Text('Device: ${peer.name}'),
            Text('Folder: $path'),
            Text('Direction: ${preset.direction!.label}'),
            const SizedBox(height: 12),
            Text(_directionExplanation(preset.direction!)),
            const SizedBox(height: 8),
            const Text(
              'Deletion behavior: source-side deletions can propagate in the configured direction. This is synchronization, not permanent archive backup.',
            ),
            if (preset.sourceHint != null) ...[
              const SizedBox(height: 8),
              Text('Suggested location: ${preset.sourceHint}'),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Create and invite'),
        ),
      ],
    ),
  );
  final name = nameController.text.trim();
  nameController.dispose();
  if (confirmed != true || name.isEmpty || !context.mounted) return false;

  final controller = context.read<FolderSyncController>();
  final pair = await controller.createFolderPair(
    buildPresetDraft(
      preset: preset,
      name: name,
      localPath: path,
      peerDeviceId: peerId,
    ),
  );
  try {
    controller.invitePeer(pair.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$name created; invitation sent.')),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$name was created, but the invitation could not be sent. Open the pair to retry.',
          ),
        ),
      );
    }
  }
  return true;
}

String _directionExplanation(SyncDirection direction) => switch (direction) {
      SyncDirection.twoWay =>
        'This device and the peer can both send edits and deletions.',
      SyncDirection.sendOnly =>
        'This device sends changes outward. The selected peer does not send edits back through this pair.',
      SyncDirection.receiveOnly =>
        'This device receives changes from the peer and does not advertise local edits through this pair.',
    };

IconData _icon(String key) => switch (key) {
      'camera' => Icons.photo_camera_outlined,
      'screenshot' => Icons.screenshot_outlined,
      'download' => Icons.download_outlined,
      'documents' => Icons.description_outlined,
      'inbox' => Icons.inbox_outlined,
      _ => Icons.tune_outlined,
    };
