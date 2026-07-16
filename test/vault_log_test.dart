import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:conduit/src/sync/vault_log.dart';

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('vault_log_test_');
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  test('a freshly-opened log (no file on disk yet) returns empty', () async {
    final log = await VaultLog.open('pairA', tempRoot);
    expect(await log.all(), isEmpty);
  });

  test('record() then all() round-trips every field exactly', () async {
    final log = await VaultLog.open('pairA', tempRoot);
    final entry = VaultLogEntry(
      relPath: 'docs/report.docx',
      vaultPath: '.syncversions/docs/report.2026-07-11T12-00-00.docx',
      timestamp: DateTime.utc(2026, 7, 11, 12),
      sizeBytes: 12345,
      reason: VaultReason.peerDelete,
      sourcePeerId: 'peer',
      originalSha256: 'abc',
      restoredAt: DateTime.utc(2026, 7, 12),
    );
    await log.record(entry);

    final all = await log.all();
    expect(all, hasLength(1));
    expect(all.single.relPath, entry.relPath);
    expect(all.single.vaultPath, entry.vaultPath);
    expect(all.single.timestamp, entry.timestamp);
    expect(all.single.sizeBytes, entry.sizeBytes);
    expect(all.single.reason, VaultReason.peerDelete);
    expect(all.single.sourcePeerId, 'peer');
    expect(all.single.originalSha256, 'abc');
    expect(all.single.restoredAt, DateTime.utc(2026, 7, 12));
  });

  test('old JSON without optional fields remains readable', () async {
    final log = await VaultLog.open('pairA', tempRoot);
    final file = File(p.join(tempRoot.path, 'vault_log', 'pairA.json'));
    await file.writeAsString(
      '[{"relPath":"a.txt","vaultPath":".syncversions/a.txt",'
      '"timestamp":"2026-07-11T12:00:00Z","sizeBytes":4}]',
    );
    final entry = (await log.all()).single;
    expect(entry.reason, VaultReason.incomingOverwrite);
    expect(entry.sourcePeerId, isNull);
  });

  test('markRestored keeps the catalog entry and source identity', () async {
    final log = await VaultLog.open('pairA', tempRoot);
    final entry = VaultLogEntry(
      relPath: 'a.txt',
      vaultPath: '.syncversions/a.txt',
      timestamp: DateTime.utc(2026, 7, 11),
      sizeBytes: 4,
      reason: VaultReason.peerDelete,
    );
    await log.record(entry);
    await log.markRestored(entry.entryId, DateTime.utc(2026, 7, 12));
    final restored = (await log.all()).single;
    expect(restored.entryId, entry.entryId);
    expect(restored.restoredAt, DateTime.utc(2026, 7, 12));
  });

  test('all() returns entries most-recent-first', () async {
    final log = await VaultLog.open('pairA', tempRoot);
    await log.record(VaultLogEntry(
      relPath: 'a.txt',
      vaultPath: '.syncversions/a.1.txt',
      timestamp: DateTime.utc(2026, 1, 1),
      sizeBytes: 1,
    ));
    await log.record(VaultLogEntry(
      relPath: 'a.txt',
      vaultPath: '.syncversions/a.2.txt',
      timestamp: DateTime.utc(2026, 6, 1),
      sizeBytes: 2,
    ));
    await log.record(VaultLogEntry(
      relPath: 'a.txt',
      vaultPath: '.syncversions/a.3.txt',
      timestamp: DateTime.utc(2026, 3, 1),
      sizeBytes: 3,
    ));

    final all = await log.all();
    expect(all.map((e) => e.vaultPath).toList(), [
      '.syncversions/a.2.txt', // June — newest
      '.syncversions/a.3.txt', // March
      '.syncversions/a.1.txt', // January — oldest
    ]);
  });

  test('remove() drops exactly the matching entry and leaves the rest',
      () async {
    final log = await VaultLog.open('pairA', tempRoot);
    final keep = VaultLogEntry(
      relPath: 'a.txt',
      vaultPath: '.syncversions/a.1.txt',
      timestamp: DateTime.utc(2026, 1, 1),
      sizeBytes: 1,
    );
    final drop = VaultLogEntry(
      relPath: 'b.txt',
      vaultPath: '.syncversions/b.1.txt',
      timestamp: DateTime.utc(2026, 2, 1),
      sizeBytes: 2,
    );
    await log.record(keep);
    await log.record(drop);

    await log.remove(drop);

    final all = await log.all();
    expect(all, hasLength(1));
    expect(all.single.relPath, 'a.txt');
  });

  test('remove() of an entry that is not present is a safe no-op', () async {
    final log = await VaultLog.open('pairA', tempRoot);
    final entry = VaultLogEntry(
      relPath: 'a.txt',
      vaultPath: '.syncversions/a.1.txt',
      timestamp: DateTime.utc(2026, 1, 1),
      sizeBytes: 1,
    );
    await log.record(entry);

    await log.remove(VaultLogEntry(
      relPath: 'does-not-exist.txt',
      vaultPath: '.syncversions/nope.txt',
      timestamp: DateTime.utc(2020, 1, 1),
      sizeBytes: 0,
    ));

    expect(await log.all(), hasLength(1));
  });

  test('a corrupt log file is treated as empty, not a crash', () async {
    final log = await VaultLog.open('pairA', tempRoot);
    final file = File(p.join(tempRoot.path, 'vault_log', 'pairA.json'));
    await file.writeAsString('{not valid json');

    expect(await log.all(), isEmpty);
  });

  test('two different pair ids get two separate log files', () async {
    final logA = await VaultLog.open('pairA', tempRoot);
    final logB = await VaultLog.open('pairB', tempRoot);
    await logA.record(VaultLogEntry(
      relPath: 'a.txt',
      vaultPath: '.syncversions/a.1.txt',
      timestamp: DateTime.utc(2026, 1, 1),
      sizeBytes: 1,
    ));

    expect(await logA.all(), hasLength(1));
    expect(await logB.all(), isEmpty); // unaffected
  });

  test('pair ids with unsafe filename characters are sanitized', () async {
    // Defends against a pairId containing path-hostile characters (mostly
    // theoretical since ids come from Uuid(), but cheap to guarantee).
    final log = await VaultLog.open('weird/id:with*chars', tempRoot);
    await log.record(VaultLogEntry(
      relPath: 'a.txt',
      vaultPath: '.syncversions/a.1.txt',
      timestamp: DateTime.utc(2026, 1, 1),
      sizeBytes: 1,
    ));
    final dir = Directory(p.join(tempRoot.path, 'vault_log'));
    final files = await dir.list().toList();
    expect(files, hasLength(1));
    expect(p.basename(files.single.path), isNot(contains('/')));
    expect(p.basename(files.single.path), isNot(contains(':')));
  });
}
