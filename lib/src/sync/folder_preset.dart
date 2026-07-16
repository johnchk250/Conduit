import 'dart:collection';

import '../protocol/wire.dart';

enum FolderPresetId {
  cameraUploads,
  screenshots,
  downloads,
  documentsTwoWay,
  receiveInbox,
  custom,
}

class FolderPreset {
  FolderPreset({
    required this.id,
    required this.title,
    required this.description,
    required this.direction,
    required this.suggestedName,
    required this.sourceHint,
    required List<String> ignoreGlobs,
    required List<String> ignoreExtensions,
    required this.maxFileSizeBytes,
    required this.iconKey,
    required Set<String> supportedPlatforms,
  })  : ignoreGlobs = UnmodifiableListView(List.of(ignoreGlobs)),
        ignoreExtensions = UnmodifiableListView(List.of(ignoreExtensions)),
        supportedPlatforms = UnmodifiableSetView(Set.of(supportedPlatforms));

  final FolderPresetId id;
  final String title;
  final String description;
  final SyncDirection? direction;
  final String suggestedName;
  final String? sourceHint;
  final List<String> ignoreGlobs;
  final List<String> ignoreExtensions;
  final int? maxFileSizeBytes;
  final String iconKey;
  final Set<String> supportedPlatforms;

  bool supports(String platform) =>
      supportedPlatforms.isEmpty || supportedPlatforms.contains(platform);
}

final List<FolderPreset> folderPresets = List.unmodifiable([
  FolderPreset(
    id: FolderPresetId.cameraUploads,
    title: 'Camera uploads',
    description: 'Send photos from this device to the selected peer.',
    direction: SyncDirection.sendOnly,
    suggestedName: 'Camera uploads',
    sourceHint: 'DCIM/Camera',
    ignoreGlobs: const [],
    ignoreExtensions: const [],
    maxFileSizeBytes: null,
    iconKey: 'camera',
    supportedPlatforms: const {},
  ),
  FolderPreset(
    id: FolderPresetId.screenshots,
    title: 'Screenshots',
    description: 'Send screenshots from this device.',
    direction: SyncDirection.sendOnly,
    suggestedName: 'Screenshots',
    sourceHint: 'Pictures/Screenshots',
    ignoreGlobs: const [],
    ignoreExtensions: const [],
    maxFileSizeBytes: null,
    iconKey: 'screenshot',
    supportedPlatforms: const {},
  ),
  FolderPreset(
    id: FolderPresetId.downloads,
    title: 'Downloads',
    description: 'Send downloaded files from this device.',
    direction: SyncDirection.sendOnly,
    suggestedName: 'Downloads',
    sourceHint: 'Download',
    ignoreGlobs: const [],
    ignoreExtensions: const [],
    maxFileSizeBytes: null,
    iconKey: 'download',
    supportedPlatforms: const {},
  ),
  FolderPreset(
    id: FolderPresetId.documentsTwoWay,
    title: 'Documents two-way',
    description: 'Keep an explicitly chosen documents folder synchronized.',
    direction: SyncDirection.twoWay,
    suggestedName: 'Documents',
    sourceHint: 'Documents',
    ignoreGlobs: const [],
    ignoreExtensions: const [],
    maxFileSizeBytes: null,
    iconKey: 'documents',
    supportedPlatforms: const {},
  ),
  FolderPreset(
    id: FolderPresetId.receiveInbox,
    title: 'Receive inbox',
    description: 'Receive changes from a selected peer.',
    direction: SyncDirection.receiveOnly,
    suggestedName: 'Receive inbox',
    sourceHint: null,
    ignoreGlobs: const [],
    ignoreExtensions: const [],
    maxFileSizeBytes: null,
    iconKey: 'inbox',
    supportedPlatforms: const {},
  ),
  FolderPreset(
    id: FolderPresetId.custom,
    title: 'Custom',
    description: 'Choose all folder sync settings.',
    direction: null,
    suggestedName: '',
    sourceHint: null,
    ignoreGlobs: const [],
    ignoreExtensions: const [],
    maxFileSizeBytes: null,
    iconKey: 'tune',
    supportedPlatforms: const {},
  ),
]);

FolderPairDraft buildPresetDraft({
  required FolderPreset preset,
  required String name,
  required String localPath,
  required String peerDeviceId,
}) {
  final direction = preset.direction;
  if (direction == null) {
    throw ArgumentError('The custom preset must use the full editor.');
  }
  return FolderPairDraft(
    name: name,
    localPath: localPath,
    direction: direction,
    peerDeviceId: peerDeviceId,
    ignoreGlobs: List.of(preset.ignoreGlobs),
    ignoreExtensions: List.of(preset.ignoreExtensions),
    maxFileSizeBytes: preset.maxFileSizeBytes,
  );
}
