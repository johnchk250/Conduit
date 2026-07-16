import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/src/protocol/wire.dart';
import 'package:conduit/src/sync/folder_preset.dart';

void main() {
  test('preset catalog has stable ids and expected directions', () {
    expect(
      folderPresets.map((preset) => preset.id).toSet().length,
      folderPresets.length,
    );
    expect(
      folderPresets
          .firstWhere((preset) => preset.id == FolderPresetId.cameraUploads)
          .direction,
      SyncDirection.sendOnly,
    );
    expect(
      folderPresets
          .firstWhere((preset) => preset.id == FolderPresetId.documentsTwoWay)
          .direction,
      SyncDirection.twoWay,
    );
  });

  test('preset conversion requires an explicit peer and copies rule lists', () {
    final preset = folderPresets
        .firstWhere((candidate) => candidate.id == FolderPresetId.downloads);
    expect(
      () => buildPresetDraft(
        preset: preset,
        name: 'Downloads',
        localPath: 'root',
        peerDeviceId: '',
      ),
      throwsArgumentError,
    );
    final draft = buildPresetDraft(
      preset: preset,
      name: 'Downloads',
      localPath: 'root',
      peerDeviceId: 'peer',
    );
    expect(draft.direction, SyncDirection.sendOnly);
    expect(() => preset.ignoreGlobs.add('*.tmp'), throwsUnsupportedError);
  });

  test('custom preset routes to the full editor', () {
    final preset = folderPresets
        .firstWhere((candidate) => candidate.id == FolderPresetId.custom);
    expect(
      () => buildPresetDraft(
        preset: preset,
        name: 'Custom',
        localPath: 'root',
        peerDeviceId: 'peer',
      ),
      throwsArgumentError,
    );
  });
}
