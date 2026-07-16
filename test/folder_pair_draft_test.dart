import 'package:conduit/src/protocol/wire.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('folder pair draft requires an explicit destination peer', () {
    expect(
      () => FolderPairDraft(
        name: 'Camera',
        localPath: 'C:/Camera',
        direction: SyncDirection.sendOnly,
        peerDeviceId: '',
      ),
      throwsArgumentError,
    );
  });

  test('folder pair draft materializes the complete configuration', () {
    final pair = FolderPairDraft(
      name: ' Camera ',
      localPath: ' C:/Camera ',
      direction: SyncDirection.sendOnly,
      peerDeviceId: 'PEER-0001',
      ignoreExtensions: const ['.tmp'],
    ).materialize('pair-1');

    expect(pair.id, 'pair-1');
    expect(pair.name, 'Camera');
    expect(pair.localPath, 'C:/Camera');
    expect(pair.peerDeviceId, 'PEER-0001');
    expect(pair.direction, SyncDirection.sendOnly);
    expect(pair.ignoreExtensions, ['.tmp']);
  });
}
