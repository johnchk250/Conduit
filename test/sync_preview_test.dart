import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/src/net/transport.dart';
import 'package:conduit/src/protocol/wire.dart';
import 'package:conduit/src/storage/index_db.dart';
import 'package:conduit/src/sync/index_diff.dart';
import 'package:conduit/src/sync/sync_preview.dart';
import 'package:conduit/src/sync/version_vector.dart';

void main() {
  IndexEntry live(
    String path, {
    int size = 100,
    String sha = 'sha',
    VersionVector version = const VersionVector.empty(),
    int mtime = 0,
  }) =>
      IndexEntry(
        relPath: path,
        size: size,
        mtime: mtime,
        sha256: sha,
        version: version,
        sequence: 1,
      );

  test('indexDiff adds reasons without changing selected paths', () {
    final needs = indexDiff(
      localLive: [
        live('update.txt', sha: 'old', version: VersionVector({'peer': 1})),
      ],
      peerLive: [
        live('new.txt'),
        live('update.txt', sha: 'new', version: VersionVector({'peer': 2})),
      ],
    );
    expect(needs.map((need) => need.relPath), ['new.txt', 'update.txt']);
    expect(needs.map((need) => need.reason), [
      NeedReason.missingLocally,
      NeedReason.peerVersionNewer,
    ]);
  });

  test('preview swaps the same decision logic and filters pair direction', () {
    final pair = FolderPair(
      id: 'pair',
      name: 'Pair',
      localPath: 'root',
      direction: SyncDirection.twoWay,
      peerDeviceId: 'peer',
    );
    final preview = assembleSyncPreview(
      pair: pair,
      inputs: SyncPreviewInputs(
        localLive: [live('send.txt', size: 30)],
        peerLive: [live('receive.txt', size: 40)],
        localTombstones: const [],
        localGeneration: 1,
        peerGeneration: 1,
        peerUpdatedAt: DateTime.utc(2026),
        connected: true,
        transport: ConnectionTransport.lan,
      ),
      capturedAt: DateTime.utc(2026),
    );
    expect(preview.totals.receiveCount, 1);
    expect(preview.totals.receiveBytes, 40);
    expect(preview.totals.sendCount, 1);
    expect(preview.totals.sendBytes, 30);
  });

  test('Bluetooth defers files over the existing 10 MiB policy', () {
    final pair = FolderPair(
      id: 'pair',
      name: 'Pair',
      localPath: 'root',
      direction: SyncDirection.receiveOnly,
      peerDeviceId: 'peer',
    );
    final preview = assembleSyncPreview(
      pair: pair,
      inputs: SyncPreviewInputs(
        localLive: const [],
        peerLive: [
          live('large.bin', size: bluetoothLargeTransferLimitBytes + 1),
        ],
        localTombstones: const [],
        localGeneration: 0,
        peerGeneration: 1,
        peerUpdatedAt: DateTime.utc(2026),
        connected: true,
        transport: ConnectionTransport.bluetooth,
      ),
      capturedAt: DateTime.utc(2026),
    );
    expect(preview.totals.bluetoothDeferredCount, 1);
  });

  test('missing peer snapshot is unavailable, never empty up to date', () {
    final preview = assembleSyncPreview(
      pair: FolderPair(
        id: 'pair',
        name: 'Pair',
        localPath: 'root',
        direction: SyncDirection.twoWay,
        peerDeviceId: 'peer',
      ),
      inputs: SyncPreviewInputs(
        localLive: const [],
        peerLive: const [],
        localTombstones: const [],
        localGeneration: 0,
        peerGeneration: 0,
        peerUpdatedAt: null,
        connected: false,
        transport: null,
      ),
      capturedAt: DateTime.utc(2026),
    );
    expect(preview.freshness, SyncPreviewFreshness.unavailable);
  });
}
