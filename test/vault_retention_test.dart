import 'dart:io';

import 'package:conduit/src/core/config_store.dart';
import 'package:conduit/src/net/peer_registry.dart';
import 'package:conduit/src/protocol/wire.dart';
import 'package:conduit/src/sync/engine.dart';
import 'package:conduit/src/sync/manifest.dart';
import 'package:conduit/src/sync/vault_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late Directory stateDir;
  late _FakeFs fs;
  late FolderPair pair;
  late SyncEngine engine;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vault_retention_test_');
    stateDir = Directory(p.join(tmp.path, 'state'));
    await stateDir.create(recursive: true);
    fs = _FakeFs();
    pair = FolderPair(
      id: 'pair-retention',
      name: 'Retention',
      localPath: 'root',
      direction: SyncDirection.twoWay,
    );
    engine = SyncEngine(
      fs: fs,
      config: ConfigStore.forTest(
        File(p.join(tmp.path, 'config.json')),
        {
          'folderPairs': [pair.toJson()],
          'pairedPeers': <Object>[]
        },
      ),
      stateDir: stateDir,
      registry: PeerConnectionRegistry(),
      deviceId: 'device',
    );
  });

  tearDown(() async {
    await engine.dispose();
    await tmp.delete(recursive: true);
  });

  Future<void> seed(List<VaultLogEntry> entries) async {
    final log = await VaultLog.open(pair.id, stateDir);
    await log.replaceAll(entries);
    for (final entry in entries) {
      if (entry.vaultPath.startsWith('.syncversions/')) {
        fs.files[entry.vaultPath] = [1];
      }
    }
  }

  test('retains versions newer than and exactly at the 14-day cutoff',
      () async {
    final now = DateTime.utc(2026, 7, 16, 12);
    await seed([
      _entry('newer', now.subtract(const Duration(days: 13, hours: 23))),
      _entry('boundary', now.subtract(vaultRetention)),
    ]);

    final result = await engine.enforceVaultRetention(pair, now: now);

    expect(result.expired, 0);
    expect((await engine.vaultEntries(pair)), hasLength(2));
  });

  test('deletes expired versions and removes missing catalog rows', () async {
    final now = DateTime.utc(2026, 7, 16, 12);
    final old = _entry('old', now.subtract(const Duration(days: 15)));
    final missing = _entry('missing', now.subtract(const Duration(days: 16)));
    await seed([old, missing]);
    fs.files.remove(missing.vaultPath);

    final result = await engine.enforceVaultRetention(pair, now: now);

    expect(result.deleted, 1);
    expect(result.missing, 1);
    expect(await engine.vaultEntries(pair), isEmpty);
  });

  test('failed deletion and malformed paths remain for retry', () async {
    final now = DateTime.utc(2026, 7, 16, 12);
    final failed = _entry('failed', now.subtract(const Duration(days: 15)));
    final malformed = VaultLogEntry(
      relPath: 'live.txt',
      vaultPath: '../live.txt',
      timestamp: now.subtract(const Duration(days: 15)),
      sizeBytes: 1,
    );
    await seed([failed, malformed]);
    fs.failDeletes.add(failed.vaultPath);

    final result = await engine.enforceVaultRetention(pair, now: now);

    expect(result.failed, 2);
    expect((await engine.vaultEntries(pair)), hasLength(2));
    expect(fs.deletedPaths, isNot(contains('../live.txt')));
  });

  test('cleanup is idempotent', () async {
    final now = DateTime.utc(2026, 7, 16, 12);
    await seed([_entry('old', now.subtract(const Duration(days: 15)))]);

    expect(
      (await engine.enforceVaultRetention(pair, now: now)).deleted,
      1,
    );
    expect(
      (await engine.enforceVaultRetention(pair, now: now)).expired,
      0,
    );
  });

  test('manual cleanup removes only deleted or missing archived versions',
      () async {
    final now = DateTime.utc(2026, 7, 16, 12);
    final remove = _entry('remove', now);
    final missing = _entry('missing', now);
    final failed = _entry('failed', now);
    final malformed = VaultLogEntry(
      relPath: 'live.txt',
      vaultPath: '../live.txt',
      timestamp: now,
      sizeBytes: 50,
    );
    await seed([remove, missing, failed, malformed]);
    fs.files.remove(missing.vaultPath);
    fs.failDeletes.add(failed.vaultPath);

    final result = await engine.deleteVaultEntries(
      pair,
      [remove, missing, failed, malformed],
    );

    expect(result.requested, 4);
    expect(result.deleted, 1);
    expect(result.missing, 1);
    expect(result.failed, 2);
    expect(result.reclaimedBytes, remove.sizeBytes);
    expect(fs.files.containsKey(remove.vaultPath), isFalse);
    expect(fs.deletedPaths, isNot(contains('../live.txt')));
    expect(
      (await engine.vaultEntries(pair)).map((entry) => entry.entryId),
      containsAll([failed.entryId, malformed.entryId]),
    );
  });
}

VaultLogEntry _entry(String name, DateTime timestamp) => VaultLogEntry(
      relPath: '$name.txt',
      vaultPath: '.syncversions/nested/$name.txt',
      timestamp: timestamp,
      sizeBytes: 1,
    );

class _FakeFs implements FileSystemAccess {
  final files = <String, List<int>>{};
  final failDeletes = <String>{};
  final deletedPaths = <String>[];

  @override
  bool get isAndroidSAF => false;

  @override
  Future<List<String>> listFiles(String rootPath) async => files.keys.toList();

  @override
  Future<FileEntry?> stat(String rootPath, String relPath) async {
    final bytes = files[relPath];
    return bytes == null
        ? null
        : FileEntry(relPath: relPath, size: bytes.length, mtime: 1, sha256: '');
  }

  @override
  Stream<List<int>> openRead(String rootPath, String relPath,
      [int offset = 0]) async* {
    final bytes = files[relPath];
    if (bytes != null) yield bytes.sublist(offset);
  }

  @override
  Future<void> write(String rootPath, String relPath, List<int> data) async {
    files[relPath] = List.of(data);
  }

  @override
  Future<void> append(String rootPath, String relPath, List<int> data) async {
    files[relPath] = [...?files[relPath], ...data];
  }

  @override
  Future<bool> delete(String rootPath, String relPath) async {
    deletedPaths.add(relPath);
    if (failDeletes.contains(relPath)) return false;
    return files.remove(relPath) != null;
  }

  @override
  Future<String> moveToVault(String rootPath, String relPath) async {
    throw UnsupportedError('not used');
  }
}
