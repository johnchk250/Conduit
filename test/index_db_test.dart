import 'dart:io';

import 'package:conduit/src/storage/db_factory.dart';
import 'package:conduit/src/storage/index_db.dart';
import 'package:conduit/src/sync/version_vector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Integration tests for [IndexDb]. These hit a REAL SQLite file (via the FFI
/// factory) in a temp directory — they exercise the actual schema, WAL mode,
/// transaction semantics, and round-tripping of [VersionVector]s through JSON.
///
/// Because `databaseFactoryFfi` is process-local (no platform channel), these
/// run as plain unit tests on the host — no Android emulator required. This is
/// the whole reason we picked `sqflite_common_ffi` over the mobile-only
/// `sqflite` plugin (see [DbFactory]).
void main() {
  late Directory tempRoot;
  late Directory stateDir;

  setUp(() async {
    DbFactory.init(); // idempotent
    tempRoot = await Directory.systemTemp.createTemp('indexdb_test_');
    stateDir = Directory(p.join(tempRoot.path, 'support'));
    await stateDir.create(recursive: true);
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  group('open / schema', () {
    test('creates a fresh DB file on first open', () async {
      final db = await IndexDb.open('pair-1', stateDir);
      expect(await db.liveCount(), 0);
      expect(await db.maxSequence(), 0);
      await db.close();
      expect(File(p.join(stateDir.path, 'index', 'pair-1.db')).existsSync(),
          isTrue);
    });

    test('reopening an existing DB does not lose rows', () async {
      final first = await IndexDb.open('pair-1', stateDir);
      await first.upsertLocal(
          relPath: 'a.txt', size: 10, mtime: 1, sha256: 'aa', deviceId: 'A');
      await first.close();

      final second = await IndexDb.open('pair-1', stateDir);
      expect(await second.liveCount(), 1);
      final row = await second.get('a.txt');
      expect(row, isNotNull);
      expect(row!.sha256, 'aa');
      await second.close();
    });

    test('pairId with special chars is sanitized in the filename', () async {
      final db = await IndexDb.open('pair/with:bad*chars', stateDir);
      await db.close();
      final dir = Directory(p.join(stateDir.path, 'index'));
      final names = dir
          .listSync()
          .whereType<File>()
          .map((f) => p.basename(f.path))
          .toList();
      expect(names, anyOf(contains('pair_with_bad_chars.db')));
    });
  });

  group('upsertLocal', () {
    test('inserts a new row with version {deviceId:1} and sequence 1',
        () async {
      final db = await IndexDb.open('p', stateDir);
      final changed = await db.upsertLocal(
          relPath: 'a.txt', size: 10, mtime: 1, sha256: 'aa', deviceId: 'A');
      expect(changed, isTrue);
      final row = await db.get('a.txt');
      expect(row!.size, 10);
      expect(row.version, VersionVector({'A': 1}));
      expect(row.sequence, 1);
      expect(row.deleted, isFalse);
      await db.close();
    });

    test('a second different write bumps version and sequence', () async {
      final db = await IndexDb.open('p', stateDir);
      await db.upsertLocal(
          relPath: 'a.txt', size: 10, mtime: 1, sha256: 'aa', deviceId: 'A');
      final changed = await db.upsertLocal(
          relPath: 'a.txt', size: 20, mtime: 2, sha256: 'bb', deviceId: 'A');
      expect(changed, isTrue);
      final row = await db.get('a.txt');
      expect(row!.version, VersionVector({'A': 2}));
      expect(row.sequence, 2);
      expect(row.size, 20);
      await db.close();
    });

    test('an UNCHANGED write is a no-op (no version/sequence burn)', () async {
      final db = await IndexDb.open('p', stateDir);
      await db.upsertLocal(
          relPath: 'a.txt', size: 10, mtime: 1, sha256: 'aa', deviceId: 'A');
      final changed = await db.upsertLocal(
          relPath: 'a.txt', size: 10, mtime: 1, sha256: 'aa', deviceId: 'A');
      expect(changed, isFalse);
      expect(await db.maxSequence(), 1);
      final row = await db.get('a.txt');
      expect(row!.version, VersionVector({'A': 1}));
      await db.close();
    });

    test('a different deviceId only bumps its own counter', () async {
      final db = await IndexDb.open('p', stateDir);
      await db.upsertLocal(
          relPath: 'a.txt', size: 10, mtime: 1, sha256: 'aa', deviceId: 'A');
      await db.upsertLocal(
          relPath: 'a.txt', size: 20, mtime: 2, sha256: 'bb', deviceId: 'B');
      final row = await db.get('a.txt');
      expect(row!.version, VersionVector({'A': 1, 'B': 1}));
      expect(row.sequence, 2);
      await db.close();
    });

    test('sequence is monotonic across DIFFERENT files', () async {
      final db = await IndexDb.open('p', stateDir);
      await db.upsertLocal(
          relPath: 'a.txt', size: 1, mtime: 1, sha256: 'a', deviceId: 'A');
      await db.upsertLocal(
          relPath: 'b.txt', size: 1, mtime: 1, sha256: 'b', deviceId: 'A');
      final a = await db.get('a.txt');
      final b = await db.get('b.txt');
      expect(a!.sequence, 1);
      expect(b!.sequence, 2);
      expect(await db.maxSequence(), 2);
      await db.close();
    });

    test('block hashes round-trip through JSON', () async {
      final db = await IndexDb.open('p', stateDir);
      await db.upsertLocal(
        relPath: 'a.txt',
        size: 10,
        mtime: 1,
        sha256: 'aa',
        deviceId: 'A',
        blockHashes: const ['b1', 'b2', 'b3'],
      );
      final row = await db.get('a.txt');
      expect(row!.blockHashes, ['b1', 'b2', 'b3']);
      await db.close();
    });

    test('resurrects a previously-deleted file (tombstone → live)', () async {
      final db = await IndexDb.open('p', stateDir);
      await db.upsertLocal(
          relPath: 'a.txt', size: 10, mtime: 1, sha256: 'aa', deviceId: 'A');
      await db.markDeletedLocal(relPath: 'a.txt', deviceId: 'A');
      // File reappears on disk — scanner sees it again.
      final changed = await db.upsertLocal(
          relPath: 'a.txt', size: 15, mtime: 5, sha256: 'cc', deviceId: 'A');
      expect(changed, isTrue);
      final row = await db.get('a.txt');
      expect(row!.deleted, isFalse);
      expect(row.size, 15);
      expect(row.version, VersionVector({'A': 3}));
      expect(await db.liveCount(), 1);
      await db.close();
    });
  });

  group('markDeletedLocal', () {
    test('records a tombstone with bumped version, keeping size/mtime/sha',
        () async {
      final db = await IndexDb.open('p', stateDir);
      await db.upsertLocal(
          relPath: 'a.txt', size: 10, mtime: 1, sha256: 'aa', deviceId: 'A');
      final deleted =
          await db.markDeletedLocal(relPath: 'a.txt', deviceId: 'A');
      expect(deleted, isTrue);
      final row = await db.get('a.txt');
      expect(row!.deleted, isTrue);
      expect(row.version, VersionVector({'A': 2}));
      expect(row.size, 10); // preserved for diff/debugging
      expect(await db.liveCount(), 0);
      await db.close();
    });

    test('deleting an already-deleted file is a no-op', () async {
      final db = await IndexDb.open('p', stateDir);
      await db.upsertLocal(
          relPath: 'a.txt', size: 10, mtime: 1, sha256: 'aa', deviceId: 'A');
      await db.markDeletedLocal(relPath: 'a.txt', deviceId: 'A');
      final seqBefore = await db.maxSequence();
      final deleted =
          await db.markDeletedLocal(relPath: 'a.txt', deviceId: 'A');
      expect(deleted, isFalse);
      expect(await db.maxSequence(), seqBefore);
      await db.close();
    });

    test('deleting a never-seen file still records a tombstone', () async {
      // A delete can arrive for a path we've never observed (e.g. peer deleted
      // before we ever scanned). We must still record version {us:1} so a
      // later-arriving live copy from someone else can win.
      final db = await IndexDb.open('p', stateDir);
      final deleted =
          await db.markDeletedLocal(relPath: 'ghost.txt', deviceId: 'A');
      expect(deleted, isTrue);
      final row = await db.get('ghost.txt');
      expect(row!.deleted, isTrue);
      expect(row.version, VersionVector({'A': 1}));
      await db.close();
    });
  });

  group('changesSince / liveSnapshot', () {
    test('changesSince returns only entries past the watermark, ascending',
        () async {
      final db = await IndexDb.open('p', stateDir);
      await db.upsertLocal(
          relPath: 'a.txt', size: 1, mtime: 1, sha256: 'a', deviceId: 'A');
      await db.upsertLocal(
          relPath: 'b.txt', size: 1, mtime: 1, sha256: 'b', deviceId: 'A');
      await db.upsertLocal(
          relPath: 'c.txt', size: 1, mtime: 1, sha256: 'c', deviceId: 'A');

      final since1 = await db.changesSince(1);
      expect(since1.map((e) => e.relPath), ['b.txt', 'c.txt']);
      expect(since1.first.sequence, 2);
      expect(since1.last.sequence, 3);

      final since0 = await db.changesSince(0);
      expect(since0.length, 3);
      final sinceAll = await db.changesSince(3);
      expect(sinceAll, isEmpty);
      await db.close();
    });

    test('changesSince INCLUDES tombstones (deletes must propagate)', () async {
      final db = await IndexDb.open('p', stateDir);
      await db.upsertLocal(
          relPath: 'a.txt', size: 1, mtime: 1, sha256: 'a', deviceId: 'A');
      await db.markDeletedLocal(relPath: 'a.txt', deviceId: 'A');
      final since1 = await db.changesSince(1);
      expect(since1.length, 1);
      expect(since1.first.deleted, isTrue);
      await db.close();
    });

    test('liveSnapshot excludes tombstones', () async {
      final db = await IndexDb.open('p', stateDir);
      await db.upsertLocal(
          relPath: 'a.txt', size: 1, mtime: 1, sha256: 'a', deviceId: 'A');
      await db.upsertLocal(
          relPath: 'b.txt', size: 1, mtime: 1, sha256: 'b', deviceId: 'A');
      await db.markDeletedLocal(relPath: 'a.txt', deviceId: 'A');
      final live = await db.liveSnapshot();
      expect(live.map((e) => e.relPath), ['b.txt']);
      await db.close();
    });
  });

  group('applyRemote', () {
    test('stores a remote row as-is', () async {
      final db = await IndexDb.open('p', stateDir);
      await db.applyRemote(IndexEntry(
        relPath: 'remote.txt',
        size: 42,
        mtime: 7,
        sha256: 'deadbeef',
        version: VersionVector({'REMOTE': 5}),
        sequence: 5,
      ));
      final row = await db.get('remote.txt');
      expect(row, isNotNull);
      expect(row!.size, 42);
      expect(row.version, VersionVector({'REMOTE': 5}));
      await db.close();
    });

    test(
        'a dominating remote resurrection is staged until local bytes are fetched',
        () async {
      final db = await IndexDb.open('p', stateDir);
      await db.upsertLocal(
          relPath: 'restored.txt',
          size: 10,
          mtime: 1,
          sha256: 'old',
          deviceId: 'Peer');
      await db.markDeletedLocal(relPath: 'restored.txt', deviceId: 'Peer');
      final tombstone = (await db.get('restored.txt'))!;
      expect(tombstone.deleted, isTrue);
      expect(tombstone.sequence, 2);

      await db.applyRemote(IndexEntry(
        relPath: 'restored.txt',
        size: 12,
        mtime: 2,
        sha256: 'restored',
        version: tombstone.version.bump('Restorer'),
        sequence: 1,
      ));

      final staged = (await db.get('restored.txt'))!;
      expect(staged.deleted, isFalse);
      expect(staged.sha256, 'restored');
      expect(staged.sequence, tombstone.sequence,
          reason: 'per-device sequences must not block the resurrection');
      expect(staged.localSize, -1);
      expect(await db.localSnapshot('Peer'), isEmpty,
          reason: 'metadata alone is not proof that local bytes exist');
      expect(await db.localLivePaths('Peer'), isEmpty,
          reason: 'the scanner must not re-tombstone before the fetch');

      await db.confirmLocalObservation(
          relPath: 'restored.txt', sha: 'restored');
      expect(
        (await db.localSnapshot('Peer')).single.relPath,
        'restored.txt',
      );
      expect(await db.localLivePaths('Peer'), {'restored.txt'});
      await db.close();
    });

    test('a LOWER-sequence remote does not overwrite a higher one', () async {
      final db = await IndexDb.open('p', stateDir);
      await db.applyRemote(IndexEntry(
          relPath: 'r.txt',
          size: 10,
          mtime: 1,
          sha256: 'new',
          version: VersionVector({'R': 3}),
          sequence: 3));
      await db.applyRemote(IndexEntry(
          relPath: 'r.txt',
          size: 99,
          mtime: 1,
          sha256: 'stale',
          version: VersionVector({'R': 1}),
          sequence: 1));
      final row = await db.get('r.txt');
      expect(row!.size, 10); // the higher-seq row won
      expect(row.sha256, 'new');
      await db.close();
    });

    // Regression: hardware smoke #3 edit-reversion (2026-06-24). When a peer
    // re-advertises a path we authored with a DIFFERENT sha, the version vectors
    // are CONCURRENT (independently created content). Under the new LWW conflict
    // resolution in indexDiff, we skip the version merge here so the vectors
    // remain concurrent and LWW can fire. The transport fields (our sha/size)
    // are protected by the sequence guard as before. The LWW outcome is decided
    // by mtime in indexDiff — our edit (newer mtime) wins there.
    test(
        'a LOWER-sequence remote with DIFFERENT sha keeps vectors concurrent '
        '(no merge; LWW in indexDiff decides)', () async {
      final db = await IndexDb.open('p', stateDir);
      // This device's own authored row, version {Me:2}.
      await db.upsertLocal(
          relPath: 'smoke.txt',
          size: 35,
          mtime: 10, // our edit is NEWER
          sha256: 'edit2',
          deviceId: 'Me');
      await db.upsertLocal(
          relPath: 'smoke.txt',
          size: 35,
          mtime: 20, // latest edit — newest mtime
          sha256: 'edit3',
          deviceId: 'Me');
      final before = await db.get('smoke.txt');
      expect(before!.version, VersionVector({'Me': 2}));

      // Peer re-advertises at a LOWER sequence with different sha and OLDER
      // mtime (their old content).
      await db.applyRemote(IndexEntry(
          relPath: 'smoke.txt',
          size: 41,
          mtime: 5, // peer's content is OLDER
          sha256: 'peerbytes',
          version: VersionVector({'Peer': 1}),
          sequence: 1));

      final row = await db.get('smoke.txt');
      // Transport fields: the higher-seq (our) row must still win.
      expect(row!.size, 35);
      expect(row.sha256, 'edit3');
      expect(row.sequence, 2);
      // Version: vectors remain SEPARATE (concurrent) — no merge when sha
      // differs. indexDiff LWW will decide based on mtime (our newer mtime wins).
      expect(row.version, VersionVector({'Me': 2}));
      await db.close();
    });

    // SAME sha case: peer re-advertises a file we authored with the SAME content
    // but carrying their origin counter. The merge MUST run so our vector absorbs
    // their counter and we keep dominance (original smoke #3 fix).
    test(
        'a LOWER-sequence remote with SAME sha still merges its origin counter',
        () async {
      final db = await IndexDb.open('p', stateDir);
      await db.upsertLocal(
          relPath: 'smoke.txt',
          size: 35,
          mtime: 1,
          sha256: 'shared_sha',
          deviceId: 'Me');

      // Peer re-advertises with the SAME sha but lower sequence.
      await db.applyRemote(IndexEntry(
          relPath: 'smoke.txt',
          size: 35,
          mtime: 1,
          sha256: 'shared_sha',
          version: VersionVector({'Peer': 1}),
          sequence: 1));

      final row = await db.get('smoke.txt');
      // Transport fields unchanged.
      expect(row!.sha256, 'shared_sha');
      expect(row.sequence, 1);
      // Same-sha merge fires: peer's counter absorbed.
      expect(row.version, VersionVector({'Me': 1, 'Peer': 1}));
      await db.close();
    });

    // Same concurrent-sha scenario at an EQUAL sequence: vectors remain
    // concurrent when shas differ. Transport fields (our sha) wins.
    test('an EQUAL-sequence remote with DIFFERENT sha keeps vectors concurrent',
        () async {
      final db = await IndexDb.open('p', stateDir);
      for (var i = 0; i < 10; i++) {
        await db.upsertLocal(
            relPath: 'smoke.txt',
            size: 35 + i,
            mtime: i,
            sha256: 'edit$i',
            deviceId: 'Me');
      }
      final before = await db.get('smoke.txt');
      expect(before!.version, VersionVector({'Me': 10}));
      expect(before.sequence, 10);

      // Peer advertises at an EQUAL sequence with different sha.
      await db.applyRemote(IndexEntry(
          relPath: 'smoke.txt',
          size: 41,
          mtime: 9,
          sha256: 'peerbytes',
          version: VersionVector({'Peer': 1}),
          sequence: 10));

      final row = await db.get('smoke.txt');
      // Our transport fields win (equal does not count as strictly newer).
      expect(row!.sha256, 'edit9');
      expect(row.sequence, 10);
      // Vectors left concurrent (no merge when sha differs).
      expect(row.version, VersionVector({'Me': 10}));
      await db.close();
    });

    // The unconditional merge must also fire on the FORWARD (newer-remote)
    // path — not just the dedup path — so a fresh remote carrying extra origin
    // counters still lands them when it wins the sequence race.
    test('a HIGHER-sequence remote merges origin counters on replace',
        () async {
      final db = await IndexDb.open('p', stateDir);
      await db.upsertLocal(
          relPath: 'smoke.txt',
          size: 35,
          mtime: 1,
          sha256: 'mine',
          deviceId: 'Me');
      final before = await db.get('smoke.txt');
      expect(before!.version, VersionVector({'Me': 1}));

      await db.applyRemote(IndexEntry(
          relPath: 'smoke.txt',
          size: 41,
          mtime: 2,
          sha256: 'theirs',
          version: VersionVector({'Me': 1, 'Peer': 2}),
          sequence: 5));

      final row = await db.get('smoke.txt');
      expect(row!.sha256, 'theirs'); // newer remote won transport fields
      // Version is the per-device MAX of both — our Me:1 preserved, not lost.
      expect(row.version, VersionVector({'Me': 1, 'Peer': 2}));
      await db.close();
    });
  });
}
