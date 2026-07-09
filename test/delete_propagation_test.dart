import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:conduit/src/core/config_store.dart';
import 'package:conduit/src/net/peer_registry.dart';
import 'package:conduit/src/net/peer_session.dart';
import 'package:conduit/src/protocol/wire.dart';
import 'package:conduit/src/storage/db_factory.dart';
import 'package:conduit/src/storage/index_db.dart';
import 'package:conduit/src/sync/engine.dart';
import 'package:conduit/src/sync/manifest.dart';
import 'package:conduit/src/sync/version_vector.dart';

/// Regression tests for Bug #6: a delete on side A created a tombstone that
/// travelled to side B and landed in B's DB, but B NEVER removed the file from
/// disk. Delete-to-disk was unimplemented ("Phase 4" in the comments) and
/// stubbed with `continue`. These tests pin the four now-wired behaviors:
///
///   1. An authoritative peer tombstone (its version dominates-or-equals our
///      live row) → the file is REMOVED from our disk at receive time.
///   2. A CONCURRENT local edit (our version has a counter the delete lacks)
///      → the file is KEPT and the tombstone is not stored as authoritative
///      (edit wins over delete — the edge case a naive sweep would get wrong).
///   3. An orphan file whose DB row is already a tombstone but whose bytes are
///      still on disk → removed by the reconcile-time sweep (backlog cleanup).
///   4. The live map still drops the tombstone so a later resurrection fetch
///      can re-add it.
///
/// The engine is fully real (V2 path, FFI SQLite). Only the transport is faked
/// (a `_FakeSession` that captures sends and accepts injected frames), reusing
/// the proven harness shape from engine_v2_test.dart.
const _me = 'AAAA-1111';
const _peer = 'BBBB-2222';

void main() {
  late _Harness h;

  setUp(() async {
    DbFactory.init();
    h = await _Harness.create();
  });

  tearDown(() async {
    await h.dispose();
  });

  test('authoritative peer tombstone removes the file from disk', () async {
    // We have a live file; the peer deletes it (tombstone version dominates).
    // After delivery the bytes MUST be gone from disk.
    h.aliceFs.files['doomed.txt'] = utf8.encode('bye bye');
    await h.alice.startPair(h.pair);
    // startPair seeds the row with version {me:1}; read the real row so the
    // tombstone we build genuinely dominates it (me-counter equal, peer bumped).
    final aliceRow = (await h.aliceDb.get('doomed.txt'))!;

    h.connectAlice();

    final tombstone = IndexEntry(
      relPath: 'doomed.txt',
      size: 0,
      mtime: 0,
      sha256: '',
      version: aliceRow.version.bump(_peer), // {me:1, peer:1} dominates {me:1}
      sequence: aliceRow.sequence + 1,
      deleted: true,
    );
    await h.deliverToAlice({
      't': Msg.indexUpdate,
      'pairId': h.pair.id,
      'folderId': h.pair.id,
      'entries': [tombstone.toJson()],
      'fromSequence': 0,
    });
    await h.pump();

    expect(h.aliceFs.files.containsKey('doomed.txt'), isFalse,
        reason: 'Bug #6: the peer tombstoned the file; it must be deleted from '
            'disk, not just recorded in the DB.');
    final row = await h.aliceDb.get('doomed.txt');
    expect(row!.deleted, isTrue);
  });

  test('concurrent local edit WINS over the delete (file is kept)', () async {
    // The critical edge case: our live row has a counter the tombstone lacks
    // (we edited it at the same instant the peer deleted it). The vectors are
    // CONCURRENT → our edit must win → the file stays on disk.
    h.aliceFs.files['edited.txt'] = utf8.encode('my new content');
    await h.alice.startPair(h.pair);
    // Our live row: {me:3} (we edited twice). Peer tombstone only knows {peer:2}
    // and lacks our me-counter → concurrent.
    final aliceRow = IndexEntry(
      relPath: 'edited.txt',
      size: 14,
      mtime: 0,
      sha256: sha256.convert(utf8.encode('my new content')).toString(),
      version: VersionVector({_me: 3}),
      sequence: 5,
      localSha: sha256.convert(utf8.encode('my new content')).toString(),
    );
    await h.aliceDb.applyRemote(aliceRow);

    h.connectAlice();

    final tombstone = IndexEntry(
      relPath: 'edited.txt',
      size: 0,
      mtime: 0,
      sha256: '',
      version:
          VersionVector({_peer: 2}), // no me-counter → concurrent with {me:3}
      sequence: 6,
      deleted: true,
    );
    await h.deliverToAlice({
      't': Msg.indexUpdate,
      'pairId': h.pair.id,
      'folderId': h.pair.id,
      'entries': [tombstone.toJson()],
      'fromSequence': 0,
    });
    await h.pump();

    expect(h.aliceFs.files.containsKey('edited.txt'), isTrue,
        reason: 'A concurrent local edit must WIN over a peer delete; the file '
            'must not be removed. A naive tombstone-sweep would wrongly delete '
            'this user edit.');
    // The peer learns of our edit on its next reconcile and resurrects the file.
  });

  test(
      'orphan backlog: a tombstoned DB row whose file is still on disk is '
      'removed by the reconcile sweep', () async {
    // Reproduce the exact pre-fix state: the DB has a tombstone but disk still
    // holds the bytes (this is what every phone orphan looked like before the
    // fix). The reconcile-time sweep must clean it even with no fresh wire
    // message.
    h.aliceFs.files['orphan.txt'] = utf8.encode('leftover');
    await h.alice.startPair(h.pair);
    // Inject the tombstone row directly (as if it arrived in an earlier run
    // before the delete-to-disk code existed). Sequence must exceed the seed
    // row's (1) so applyRemote's sequence guard stores it as deleted.
    await h.aliceDb.applyRemote(IndexEntry(
      relPath: 'orphan.txt',
      size: 0,
      mtime: 0,
      sha256: '',
      version: VersionVector({_peer: 1}),
      sequence: 2,
      deleted: true,
    ));
    final injected = await h.aliceDb.get('orphan.txt');
    expect(injected!.deleted, isTrue,
        reason: 'tombstone injected for the test');
    expect(h.aliceFs.files.containsKey('orphan.txt'), isTrue); // the orphan

    // A reconcile with no peer runs the scan + sweep. The sweep sees the
    // tombstone row + file-on-disk and deletes it.
    await h.alice.reconcile(h.pair, null);
    await h.pump();

    expect(h.aliceFs.files.containsKey('orphan.txt'), isFalse,
        reason: 'Bug #6 backlog: the reconcile sweep must remove a file whose '
            'DB row is a tombstone even when no fresh wire message drove it.');
  });

  test('live map drops the tombstone so a later resurrection can re-fetch',
      () async {
    // After a tombstone lands, _peerLive must no longer offer the path (so the
    // diff doesn't treat a deleted file as something we still have), AND a
    // subsequent live advertisement for the same path re-adds it (resurrection).
    h.aliceFs.files['x.txt'] = utf8.encode('content');
    await h.alice.startPair(h.pair);
    final aliceRow = (await h.aliceDb.get('x.txt'))!; // startPair seeds {me:1}

    h.connectAlice();

    final tombstone = IndexEntry(
      relPath: 'x.txt',
      size: 0,
      mtime: 0,
      sha256: '',
      version: aliceRow.version.bump(_peer), // dominates {me:1} → deleteWins
      sequence: aliceRow.sequence + 1,
      deleted: true,
    );
    await h.deliverToAlice({
      't': Msg.indexUpdate,
      'pairId': h.pair.id,
      'folderId': h.pair.id,
      'entries': [tombstone.toJson()],
      'fromSequence': 0,
    });
    await h.pump();
    expect(h.alice.peerLiveFor(h.pair.id)?.containsKey('x.txt'), isFalse,
        reason: 'tombstone must drop the path from the live map');

    // Now the peer brings it back (resurrection): a live entry for the same
    // path. _handleIndexFrame must re-add it to the live map.
    final resurrected = IndexEntry(
      relPath: 'x.txt',
      size: 7,
      mtime: 0,
      sha256: sha256.convert(utf8.encode('content')).toString(),
      version: VersionVector({_me: 1, _peer: 3}),
      sequence: tombstone.sequence + 1,
      deleted: false,
    );
    await h.deliverToAlice({
      't': Msg.indexUpdate,
      'pairId': h.pair.id,
      'folderId': h.pair.id,
      'entries': [resurrected.toJson()],
      'fromSequence': 0,
    });
    await h.pump();
    expect(h.alice.peerLiveFor(h.pair.id)?.containsKey('x.txt'), isTrue,
        reason: 'a live advertisement for a previously-tombstoned path must '
            're-add it to the live map (resurrection path)');
  });
}

// ---------------------------------------------------------------------------
// Harness: one real engine + a fake peer session (no real sockets)
// ---------------------------------------------------------------------------

class _Harness {
  _Harness._(
    this.tmp,
    this.alice,
    this.session,
    this.pair,
    this.aliceFs,
    this.aliceDb,
  );

  final Directory tmp;
  final SyncEngine alice;
  final _FakeSession session;
  final FolderPair pair;
  final FakeFs aliceFs;
  final IndexDb aliceDb;

  late DateTime _deliverDeadline;

  static Future<_Harness> create() async {
    final tmp = await Directory.systemTemp.createTemp('del_prop_test_');
    final stateDir = Directory(p.join(tmp.path, 'alice', 'support'));
    await stateDir.create(recursive: true);

    final pair = FolderPair(
      id: 'pair-del',
      name: 'test',
      localPath: 'r',
      direction: SyncDirection.twoWay,
      peerDeviceId: _peer,
    );

    final aliceFs = FakeFs();
    final cfgFile = File(p.join(tmp.path, 'alice', 'config.json'));
    final cfg = ConfigStore.forTest(cfgFile, {
      'folderPairs': [pair.toJson()],
      'pairedPeers': [
        PairedPeer(
                deviceId: _peer,
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
      deviceId: _me,
    );
    final aliceDb = await IndexDb.open(pair.id, stateDir);

    final session = _FakeSession(
        peer: PairedPeer(
      deviceId: _peer,
      name: 'Bob',
      platform: 'test',
      publicKeyB64: '',
    ));
    registry.publish(_peer, session);

    return _Harness._(tmp, alice, session, pair, aliceFs, aliceDb);
  }

  void connectAlice() => alice.onPeerConnected(session);

  Future<void> deliverToAlice(Map<String, dynamic> frame) async {
    _deliverDeadline = DateTime.now().add(const Duration(seconds: 8));
    var handlerDone = false;
    final pending = alice.handlePeerMessageForTest(session, frame);
    pending.whenComplete(() => handlerDone = true);
    // A tombstone delivery may kick a reconcile that holds `scanning`; pump
    // until the handler settles and the pair goes idle.
    while (true) {
      await pump();
      final stillScanning = alice.stateFor(pair.id)?.scanning ?? false;
      if (handlerDone && !stillScanning) break;
      if (DateTime.now().isAfter(_deliverDeadline)) break;
    }
    try {
      await pending.timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  Future<void> pump([Duration d = const Duration(milliseconds: 20)]) =>
      Future<void>.delayed(d);

  Future<void> dispose() async {
    await aliceDb.close();
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
    msg['msgId'] ??= 'test-${sent.length}';
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

/// In-memory FileSystemAccess (same minimal surface as the engine V2 test FakeFs).
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
      throw UnsupportedError('not used by delete-propagation tests');
}
