import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:conduit/src/storage/db_factory.dart';
import 'package:conduit/src/storage/index_db.dart';
import 'package:conduit/src/sync/manifest.dart';
import 'package:conduit/src/sync/scanner.dart';
import 'package:conduit/src/sync/version_vector.dart';

/// Unit tests for [IndexScanner]. Uses a [FakeFs] so we can drive the exact
/// disk state (creates, modifies, deletes) without touching the real FS, and a
/// REAL [IndexDb] (FFI SQLite in a temp dir) so the upsert/tombstone/sequence
/// invariants the scanner relies on are exercised for real — not mocked.
///
/// The single most important invariant under test is the "no-op re-scan burns
/// no sequence" rule: a second scan of an unchanged folder must produce an
/// empty [ScanResult.changed]. Violating it would make peers re-fetch
/// unchanged files forever.
void main() {
  late Directory tempRoot;
  late Directory stateDir;
  late IndexDb db;
  final scanner = IndexScanner();

  setUp(() async {
    DbFactory.init();
    tempRoot = await Directory.systemTemp.createTemp('scanner_test_');
    stateDir = Directory(p.join(tempRoot.path, 'support'));
    await stateDir.create(recursive: true);
    db = await IndexDb.open('pair', stateDir);
  });

  tearDown(() async {
    await db.close();
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  test('first scan of a new folder records every file as changed', () async {
    final fs =
        FakeFs({'a.txt': utf8Bytes('hello'), 'b.txt': utf8Bytes('world')});
    final result =
        await scanner.scan(fs: fs, db: db, rootPath: 'r', deviceId: 'A');
    expect(result.changed.map((e) => e.relPath).toSet(), {'a.txt', 'b.txt'});
    expect(result.maxSequence, 2);
    // Each row got version {A:1} and a monotonic sequence.
    final a = await db.get('a.txt');
    expect(a!.version, VersionVector({'A': 1}));
    expect(a.sequence, greaterThanOrEqualTo(1));
  });

  test('a no-op re-scan burns zero sequences and reports nothing changed',
      () async {
    final fs = FakeFs({'a.txt': utf8Bytes('hello')});
    await scanner.scan(fs: fs, db: db, rootPath: 'r', deviceId: 'A');
    final firstMax = await db.maxSequence();
    expect(fs.openReadCalls, 1);

    final result =
        await scanner.scan(fs: fs, db: db, rootPath: 'r', deviceId: 'A');
    expect(result.changed, isEmpty); // THE key invariant
    expect(await db.maxSequence(), firstMax); // sequence unmoved
    expect(fs.openReadCalls, 1,
        reason: 'unchanged files must reuse their persisted digest');
  });

  test('a modified file bumps version + sequence and appears in changed',
      () async {
    final fs = FakeFs({'a.txt': utf8Bytes('hello')});
    await scanner.scan(fs: fs, db: db, rootPath: 'r', deviceId: 'A');

    fs.files['a.txt'] = utf8Bytes('hello world'); // content changed
    final result =
        await scanner.scan(fs: fs, db: db, rootPath: 'r', deviceId: 'A');
    expect(result.changed.map((e) => e.relPath), ['a.txt']);
    final row = await db.get('a.txt');
    expect(row!.version, VersionVector({'A': 2})); // our counter bumped
    expect(row.sequence, 2);
  });

  test('a deleted file becomes a tombstone with bumped version', () async {
    final fs = FakeFs({'a.txt': utf8Bytes('hello'), 'b.txt': utf8Bytes('x')});
    await scanner.scan(fs: fs, db: db, rootPath: 'r', deviceId: 'A');

    fs.files.remove('a.txt'); // vanished from disk
    final result =
        await scanner.scan(fs: fs, db: db, rootPath: 'r', deviceId: 'A');
    final tombstone = result.changed.singleWhere((e) => e.relPath == 'a.txt');
    expect(tombstone.deleted, isTrue);
    expect(tombstone.version, VersionVector({'A': 2}));
    // b.txt was unchanged → not in changed.
    expect(result.changed.where((e) => e.relPath == 'b.txt'), isEmpty);
  });

  test('a file matching an ignore glob is never indexed at all', () async {
    final fs = FakeFs({
      'a.txt': utf8Bytes('hello'),
      'node_modules/pkg/index.js': utf8Bytes('module.exports = {}'),
    });
    final result = await scanner.scan(
      fs: fs,
      db: db,
      rootPath: 'r',
      deviceId: 'A',
      ignoreGlobs: ['node_modules/**'],
    );
    expect(result.changed.map((e) => e.relPath), ['a.txt']);
    expect(await db.get('node_modules/pkg/index.js'), isNull);
  });

  test('a file matching an ignored extension is never indexed', () async {
    final fs = FakeFs({
      'a.txt': utf8Bytes('hello'),
      'debug.log': utf8Bytes('log output'),
    });
    final result = await scanner.scan(
      fs: fs,
      db: db,
      rootPath: 'r',
      deviceId: 'A',
      ignoreExtensions: ['.log'],
    );
    expect(result.changed.map((e) => e.relPath), ['a.txt']);
    expect(await db.get('debug.log'), isNull);
  });

  test('a file over the size cap is never indexed', () async {
    final fs = FakeFs({
      'small.bin': utf8Bytes('x' * 10),
      'big.bin': utf8Bytes('x' * 1000),
    });
    final result = await scanner.scan(
      fs: fs,
      db: db,
      rootPath: 'r',
      deviceId: 'A',
      maxFileSizeBytes: 100,
    );
    expect(result.changed.map((e) => e.relPath), ['small.bin']);
    expect(await db.get('big.bin'), isNull);
  });

  test(
      'retroactive ignore rule FREEZES an already-synced file — it is '
      'NOT reported as a tombstone/delete (confirmed with user 2026-07-11)',
      () async {
    final fs = FakeFs({'a.txt': utf8Bytes('hello'), 'b.txt': utf8Bytes('x')});
    // First scan: no ignore rules yet — a.txt is indexed normally.
    await scanner.scan(fs: fs, db: db, rootPath: 'r', deviceId: 'A');
    final before = await db.get('a.txt');
    expect(before, isNotNull);
    expect(before!.deleted, isFalse);

    // A rule now covers a.txt (nothing changed on disk).
    final result = await scanner.scan(
      fs: fs,
      db: db,
      rootPath: 'r',
      deviceId: 'A',
      ignoreGlobs: ['a.txt'],
    );

    // THE key invariant: a.txt must not appear as a change of any kind —
    // in particular, NOT as a tombstone. Only b.txt (unaffected) could
    // possibly appear, and it didn't change either.
    expect(result.changed, isEmpty);

    // The DB row is untouched: same version/sequence as before, still not
    // deleted. This is "frozen", not "silently re-synced" or "tombstoned".
    final after = await db.get('a.txt');
    expect(after!.version, before.version);
    expect(after.sequence, before.sequence);
    expect(after.deleted, isFalse);
  });

  test(
      'once frozen, further local edits to the file do not propagate '
      '(no version bump, not in changed)', () async {
    final fs = FakeFs({'a.txt': utf8Bytes('hello')});
    await scanner.scan(fs: fs, db: db, rootPath: 'r', deviceId: 'A');
    await scanner.scan(
      fs: fs,
      db: db,
      rootPath: 'r',
      deviceId: 'A',
      ignoreGlobs: ['a.txt'],
    ); // now frozen
    final frozen = await db.get('a.txt');

    fs.files['a.txt'] = utf8Bytes('hello world — edited after freeze');
    final result = await scanner.scan(
      fs: fs,
      db: db,
      rootPath: 'r',
      deviceId: 'A',
      ignoreGlobs: ['a.txt'],
    );

    expect(result.changed, isEmpty);
    final after = await db.get('a.txt');
    expect(after!.version, frozen!.version); // unchanged
    expect(after.sequence, frozen.sequence); // unchanged
  });

  test(
      'removing the ignore rule resumes normal tracking — the file is '
      'picked up again as if newly seen, not as a spurious delete/re-add',
      () async {
    final fs = FakeFs({'a.txt': utf8Bytes('hello')});
    await scanner.scan(fs: fs, db: db, rootPath: 'r', deviceId: 'A');
    await scanner.scan(
        fs: fs,
        db: db,
        rootPath: 'r',
        deviceId: 'A',
        ignoreGlobs: ['a.txt']); // frozen
    fs.files['a.txt'] = utf8Bytes('edited while frozen');

    // Rule removed — back to normal scanning.
    final result =
        await scanner.scan(fs: fs, db: db, rootPath: 'r', deviceId: 'A');

    // The edit-while-frozen is now visible, exactly like any other local
    // edit picked up on the next unrestricted scan — no special-casing,
    // no phantom delete/re-add pair.
    expect(result.changed.map((e) => e.relPath), ['a.txt']);
    final row = await db.get('a.txt');
    expect(row!.deleted, isFalse);
  });

  test(
      'ignore params default to empty/null — every existing caller and '
      'test above behaves byte-for-byte unchanged (no ignore rules passed)',
      () async {
    final fs = FakeFs({'a.txt': utf8Bytes('hello')});
    final result =
        await scanner.scan(fs: fs, db: db, rootPath: 'r', deviceId: 'A');
    expect(result.changed.map((e) => e.relPath), ['a.txt']);
  });
}

List<int> utf8Bytes(String s) => s.codeUnits;

/// Minimal in-memory [FileSystemAccess] for scanner tests. Backed by a map of
/// relPath → bytes; [stat] returns a [FileEntry] whose sha is the real digest
/// (so the scanner's "did content change" check is exercised truthfully).
class FakeFs implements FileSystemAccess {
  FakeFs(this.files);
  final Map<String, List<int>> files;
  int openReadCalls = 0;

  @override
  bool get isAndroidSAF => false;

  @override
  Future<List<String>> listFiles(String rootPath) async =>
      files.keys.toList(growable: false);

  @override
  Future<FileEntry?> stat(String rootPath, String relPath) async {
    final data = files[relPath];
    if (data == null) return null;
    // The scanner ignores stat.sha (it recomputes via hashFile → openRead), so
    // we leave it blank here; only size/mtime matter to the scanner's caller.
    return FileEntry(relPath: relPath, size: data.length, mtime: 1, sha256: '');
  }

  @override
  Stream<List<int>> openRead(String rootPath, String relPath,
      [int offset = 0]) async* {
    openReadCalls++;
    final data = files[relPath];
    if (data == null) return;
    yield data.sublist(offset);
  }

  @override
  Future<void> write(String rootPath, String relPath, List<int> data) async {
    files[relPath] = data;
  }

  @override
  Future<void> append(String rootPath, String relPath, List<int> data) async {
    files[relPath] = [...?files[relPath], ...data];
  }

  @override
  Future<bool> delete(String rootPath, String relPath) async =>
      files.remove(relPath) != null;

  @override
  Future<String> moveToVault(String rootPath, String relPath) async =>
      throw UnsupportedError('not needed in scanner tests');
}
