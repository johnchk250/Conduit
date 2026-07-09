import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart' as sqf;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:conduit/src/core/config_store.dart';
import 'package:conduit/src/net/peer_registry.dart';
import 'package:conduit/src/net/peer_session.dart';
import 'package:conduit/src/protocol/wire.dart';
import 'package:conduit/src/storage/db_factory.dart';
import 'package:conduit/src/storage/index_db.dart';
import 'package:conduit/src/sync/engine.dart';
import 'package:conduit/src/sync/manifest.dart';

/// Roadmap Phase 0 reliability/battery tests. Two concerns, both engine-safe:
///
///   - **0.1 — periodic reconcile safety-net must preserve the no-op
///     invariant.** The whole point of the periodic tick is that it costs
///     nothing on an idle folder. Repeatedly reconciling an already-in-sync
///     folder (exactly what the periodic Timer does) must burn ZERO sequences,
///     or the engine would re-advertise unchanged files forever (Bug #8
///     territory). This pins that property directly against the periodic-tick
///     path rather than against a hand-rolled loop.
///
///   - **0.1 — pause blocks reconcile, resume re-kicks.** The Pause control
///     (Phase 1) must stop new reconciles from starting without disturbing
///     in-flight ones.
///
///   - **0.5 — DB hardening.** `PRAGMA synchronous = NORMAL` is set on open,
///     `integrity_check` runs (and reports `ok`), and [IndexDb.backup] produces
///     a `.bak` whose rows round-trip.
///
/// These reuse the lightweight in-memory FakeFs + a fake session from the V2
/// engine tests (no sockets, no SAF, no hardware) — the same logic-only
/// discipline that caught the V2 bugs.

const _aliceDeviceId = 'AAAA-1111';
const _bobDeviceId = 'BBBB-2222';

void main() {
  group('Phase 0.1 — periodic reconcile no-op-invariant', () {
    late _Harness h;

    setUp(() async {
      DbFactory.init();
      h = await _Harness.create();
    });

    tearDown(() async {
      await h.dispose();
    });

    test('a periodic tick on an in-sync folder burns zero sequences', () async {
      // Seed Alice with one file and reconcile it once (no peer) so the DB is
      // the durable, in-sync source of truth.
      h.aliceFs.files['a.txt'] = utf8.encode('hello');
      await h.alice.startPair(h.pair);
      await h.alice.reconcile(h.pair, null);
      final db = await h.alice.openIndexDbFor(h.pair);
      final seqAfterFirst = await db.maxSequence();
      expect(seqAfterFirst, 1, reason: 'one seeded file → one sequence');
      await db.close();

      // Simulate N periodic ticks. Each calls reconcile(pair, session) exactly
      // as the periodic Timer does. On an idle folder upsertLocal is a no-op,
      // so the sequence counter must NOT move — this is the property that
      // makes the periodic safety-net free.
      h.connectAlice();
      for (var i = 0; i < 5; i++) {
        await h.alice.reconcile(h.pair, h.session);
        await h.pump();
      }

      final db2 = await h.alice.openIndexDbFor(h.pair);
      final seqAfterTicks = await db2.maxSequence();
      expect(
        seqAfterTicks,
        seqAfterFirst,
        reason: 'periodic reconcile on an idle folder must burn no sequence '
            '(the no-op-invariant; Bug #8 regression guard)',
      );
      await db2.close();
    });

    test('pause blocks new reconciles; resume clears the pause', () async {
      h.aliceFs.files['a.txt'] = utf8.encode('hello');
      await h.alice.startPair(h.pair);

      h.alice.pauseSync();
      expect(h.alice.isPaused, isTrue);

      h.connectAlice();
      h.session.sent.clear();
      await h.alice.reconcile(h.pair, h.session);
      await h.pump();

      // A paused reconcile must NOT advertise (the indexUpdate an advertise
      // would emit), proving the pause gate fired before any sync work.
      expect(
        h.session.sent.where((m) => m['t'] == Msg.indexUpdate),
        isEmpty,
        reason: 'a paused engine must not advertise its delta',
      );
      expect(h.alice.stateFor(h.pair.id)?.status, 'Paused');

      h.alice.resumeSync();
      expect(h.alice.isPaused, isFalse);
      // Resume kicks a reconcile on every live pair; let it run.
      await h.pump(const Duration(milliseconds: 100));
      expect(
        h.alice.stateFor(h.pair.id)?.status,
        isNot('Paused'),
        reason: 'resume must clear the Paused status',
      );
    });
  });

  group('Phase 0.5 — DB hardening', () {
    late Directory tmp;
    late Directory stateDir;

    setUp(() async {
      DbFactory.init();
      tmp = await Directory.systemTemp.createTemp('phase0_db_test_');
      stateDir = Directory(p.join(tmp.path, 'support'));
      await stateDir.create(recursive: true);
    });

    tearDown(() async {
      // Windows holds the sqlite file briefly after close; a delete here can
      // race with errno=32 (in use). Best-effort — the OS temp dir reaps it.
      try {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('synchronous = NORMAL is set on open (the documented WAL value)',
        () async {
      // SQLite's `PRAGMA synchronous` numeric codes are: 0=OFF, 1=NORMAL,
      // 2=FULL, 3=EXTRA. NORMAL (1) is the documented crash-safe companion to
      // WAL mode — and it is exactly what the production open() sets in
      // onConfigure. Read it back on the same handle to prove open() applied it.
      final db = await IndexDb.open('p', stateDir);
      final rows = await db.rawDb.rawQuery('PRAGMA synchronous');
      expect(rows.first.values.first, 1,
          reason: 'open() must set synchronous=NORMAL (1). '
              'Codes: 0=OFF, 1=NORMAL, 2=FULL, 3=EXTRA');
      await db.close();
    });

    test('integrity_check reports ok', () async {
      final db = await IndexDb.open('p', stateDir);
      final rows = await db.rawDb.rawQuery('PRAGMA integrity_check');
      expect(rows.first.values.first, 'ok');
      await db.close();
    });

    test('backup() writes a .bak whose rows round-trip unchanged', () async {
      final db = await IndexDb.open('p', stateDir);
      await db.upsertLocal(
          relPath: 'a.txt', size: 10, mtime: 1, sha256: 'aa', deviceId: 'A');
      await db.upsertLocal(
          relPath: 'b.txt', size: 20, mtime: 2, sha256: 'bb', deviceId: 'A');
      final liveBefore =
          (await db.liveSnapshot()).map((e) => e.relPath).toList();
      expect(liveBefore, ['a.txt', 'b.txt']);

      final wrote = await db.backup();
      expect(wrote, isTrue);
      final bakFile = File('${db.path}.bak');
      expect(await bakFile.exists(), isTrue);
      await db.close();

      // The .bak is a real SQLite file: open it and confirm the rows survived
      // (this is the recoverability guarantee — a corrupt main DB is restorable).
      final bak = await _openRaw(bakFile.path);
      final liveAfter =
          (await bak.rawQuery('SELECT path FROM files ORDER BY path'))
              .map((r) => r['path'])
              .toList();
      expect(liveAfter, ['a.txt', 'b.txt']);
      await bak.close();
    });
  });
}

int _msgCounter = 0;

/// Opens a raw SQLite db handle for a backup file (Phase 0.5 round-trip test).
Future<_RawDb> _openRaw(String path) async {
  DbFactory.init();
  final db = await databaseFactory.openDatabase(path);
  return _RawDb(db);
}

/// Thin wrapper around a raw sqflite [Database], for the backup round-trip
/// assertion (opening the `.bak` directly, not through [IndexDb]).
class _RawDb {
  _RawDb(this._db);
  final sqf.Database _db;
  Future<List<Map<String, Object?>>> rawQuery(String sql,
          [List<Object?>? args]) =>
      _db.rawQuery(sql, args ?? const <Object?>[]);
  Future<void> close() => _db.close();
}

// ---------------------------------------------------------------------------
// Minimal harness (engine + fake session, no sockets) — reuses the V2 test
// pattern but trimmed to exactly what the Phase 0.1 tests need.
// ---------------------------------------------------------------------------

class _Harness {
  _Harness._(this.tmp, this.alice, this.session, this.pair, this.aliceFs);
  final Directory tmp;
  final SyncEngine alice;
  final _FakeSession session;
  final FolderPair pair;
  final FakeFs aliceFs;

  static Future<_Harness> create() async {
    final tmp = await Directory.systemTemp.createTemp('phase0_engine_test_');
    final stateDir = Directory(p.join(tmp.path, 'alice', 'support'));
    await stateDir.create(recursive: true);

    final pair = FolderPair(
      id: 'pair-1',
      name: 'test',
      localPath: 'r',
      direction: SyncDirection.twoWay,
      peerDeviceId: _bobDeviceId,
    );
    final aliceFs = FakeFs();
    final cfg = ConfigStore.forTest(File(p.join(tmp.path, 'config.json')), {
      'folderPairs': [pair.toJson()],
      'pairedPeers': [
        PairedPeer(
                deviceId: _bobDeviceId,
                name: 'Bob',
                platform: 'test',
                publicKeyB64: '')
            .toJson(),
      ],
    });

    final registry = PeerConnectionRegistry();
    final alice = SyncEngine(
      fs: aliceFs,
      config: cfg,
      stateDir: stateDir,
      registry: registry,
      deviceId: _aliceDeviceId,
    );
    final session = _FakeSession(
        peer: PairedPeer(
      deviceId: _bobDeviceId,
      name: 'Bob',
      platform: 'test',
      publicKeyB64: '',
    ));
    registry.publish(_bobDeviceId, session);
    return _Harness._(tmp, alice, session, pair, aliceFs);
  }

  void connectAlice() => alice.onPeerConnected(session);

  Future<void> pump([Duration d = const Duration(milliseconds: 20)]) =>
      Future<void>.delayed(d);

  Future<void> dispose() async {
    await alice.dispose();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  }
}

class _FakeSession implements PeerSession {
  _FakeSession({required this.peer});
  @override
  final PairedPeer peer;
  @override
  final int generation = 1;
  final List<Map<String, dynamic>> sent = [];

  @override
  set onMessage(void Function(Map<String, dynamic> msg) handler) {}
  @override
  set onError(void Function(Object error) handler) {}
  @override
  set onDone(void Function() handler) {}
  @override
  bool get isClosed => false;

  bool _linkReady = true;

  @override
  bool get hasReceivedLinkReady => _linkReady;

  @override
  bool get isLinkReady => _linkReady && !isClosed;

  @override
  void Function()? onLinkReady;

  @override
  bool markLinkReady() {
    if (_linkReady) return false;
    _linkReady = true;
    onLinkReady?.call();
    return true;
  }

  @override
  void send(Map<String, dynamic> msg) {
    msg['msgId'] ??= 'test-${++_msgCounter}';
    sent.add(msg);
  }

  @override
  void startHeartbeat({required void Function() onDead}) {}
  @override
  void restartHeartbeat() {}
  @override
  void handlePong(String? hbId) {}
  @override
  void stopHeartbeat() {}
  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ---------------------------------------------------------------------------
// In-memory FileSystemAccess (minimal surface the engine touches in these
// logic-only tests). Mirrors the FakeFs in engine_v2_test.dart.
// ---------------------------------------------------------------------------

class FakeFs implements FileSystemAccess {
  FakeFs([Map<String, List<int>>? initial]) {
    if (initial != null) files.addAll(initial);
  }
  final Map<String, List<int>> files = {};

  @override
  bool get isAndroidSAF => false;

  @override
  Future<List<String>> listFiles(String rootPath) async =>
      files.keys.toList(growable: false);

  @override
  Future<FileEntry?> stat(String rootPath, String relPath) async {
    final data = files[relPath];
    if (data == null) return null;
    return FileEntry(relPath: relPath, size: data.length, mtime: 1, sha256: '');
  }

  @override
  Stream<List<int>> openRead(String rootPath, String relPath,
      [int offset = 0]) async* {
    final data = files[relPath];
    if (data == null) return;
    yield data.sublist(offset);
  }

  @override
  Future<void> write(String rootPath, String relPath, List<int> data) async =>
      files[relPath] = List<int>.of(data);

  @override
  Future<void> append(String rootPath, String relPath, List<int> data) async =>
      files[relPath] = [...?files[relPath], ...data];

  @override
  Future<bool> delete(String rootPath, String relPath) async =>
      files.remove(relPath) != null;

  @override
  Future<String> moveToVault(String rootPath, String relPath) async =>
      throw UnsupportedError('not used by Phase 0 tests');
}
