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
import 'package:conduit/src/sync/block_transfer.dart';
import 'package:conduit/src/sync/engine.dart';
import 'package:conduit/src/sync/manifest.dart';

/// V2 engine integration tests (REDESIGN.md Phase 2, handoff §10).
///
/// These drive the REAL [SyncEngine] against a REAL
/// [IndexDb] (FFI SQLite) and the REAL inbound message router
/// ([SyncEngine._handlePeerMessage] via [SyncEngine.handlePeerMessageForTest]).
/// The only fake is the transport: a [_FakeSession] that captures sends and
/// accepts injected frames, instead of a real TCP socket.
///
/// ## Why a fake session, not a loopback
///
/// The previous harness wired two real engines over a real TCP socket pair.
/// That was over-engineered for what these tests verify (the V2 reconcile +
/// message-handler integration) and introduced three unrelated failure modes:
///   - real [PeerSession]s start 12s heartbeat timers that kept the zone alive
///     past the 30s test timeout,
///   - tearing the sockets down after `dispose()` fired `log()` into an
///     already-closed event controller ("Bad state"),
///   - frame-tap wiring + stream-naming that depended on delivery timing.
///
/// None of those are V2-engine bugs. A fake session isolates exactly the
/// behaviour under test: the advertise → indexRequest → indexUpdate →
/// processNeeds → block fetch chain, the empty-delta ping-pong guard, the
/// unknown-pair terminal error, and the session-lost cleanup.
///
/// The serve side of the block fetch (test 3) is itself mocked at the frame
/// level: when Alice emits a `Msg.request`, the test plays Bob by building the
/// matching `Msg.response` from a second [FakeFs] and feeding it back through
/// the real message router. This still exercises Alice's real
/// `_sendBlockRequest` → `_BlockSink` → `Msg.response` → `fetchFileBlockLevel`
/// path — the part these tests exist to cover.

const _aliceDeviceId = 'AAAA-1111';
const _bobDeviceId = 'BBBB-2222';

void main() {
  late _Harness h;

  setUp(() async {
    DbFactory.init();
    h = await _Harness.create();
  });

  tearDown(() async {
    await h.dispose();
  });

  test('ready handshake: ack:false marks connected immediately (responder path)',
      () async {
    // Fix for the "peer shows offline" race condition:
    // Both sides send {ready, ack:false} immediately after the TCP handshake.
    // On the initiator (client), those two frames arrive in one _onData batch;
    // FrameCodec._drain() processes welcome first (completing waitForMessage
    // and setting onMessage=null), then processes {ready, ack:false} with
    // onMessage=null → silently dropped. The responder (server/Android) then
    // never gets an ack for its own {ready}, markLinkReady() is never called,
    // and the 10-second link-ready timer fires, sends bye, and tears the
    // connection down.
    //
    // The fix: markLinkReady() is called on BOTH ack:false (responder) and
    // ack:true (initiator) paths. The responder marks link-ready as soon as it
    // receives the initiator's {ready, ack:false} — that message proves mutual
    // reachability. markLinkReady() is idempotent, so a subsequent ack:true
    // from the initiator (if it arrives) is a harmless no-op.
    h.connectAlice();
    h.session.sent.clear();
    final events = <SyncEvent>[];
    final sub = h.alice.events.listen(events.add);

    // Responder receives the initiator's {ready, ack:false}.
    // Expected new behaviour: send ack AND mark link ready immediately.
    await h.alice.handlePeerMessageForTest(h.session, {
      't': Msg.ready,
      'deviceId': _bobDeviceId,
      'ack': false,
    });
    await h.pump();
    await h.pumpUntil(() => h.alice.stateFor(h.pair.id)?.scanning != true);

    expect(h.session.isLinkReady, isTrue,
        reason: 'responder must be link-ready immediately on ack:false');
    expect(
      h.session.sent.any((m) =>
          m['t'] == Msg.ready &&
          m['deviceId'] == _aliceDeviceId &&
          m['ack'] == true),
      isTrue,
      reason: 'responder must still send the ack:true back to the initiator',
    );
    expect(
      events.any((e) => e.message == 'Connected to Bob ($_bobDeviceId)'),
      isTrue,
      reason: 'Connected event must fire on ack:false, not deferred to ack:true',
    );

    // A subsequent ack:true (if the initiator's own ready was NOT dropped) is
    // a harmless no-op — markLinkReady() is idempotent.
    final connectedEventsBefore = events
        .where((e) => e.message.startsWith('Connected to'))
        .length;
    await h.alice.handlePeerMessageForTest(h.session, {
      't': Msg.ready,
      'deviceId': _bobDeviceId,
      'ack': true,
    });
    await h.pump();
    expect(
      events.where((e) => e.message.startsWith('Connected to')).length,
      equals(connectedEventsBefore),
      reason: 'no duplicate Connected event on idempotent ack:true',
    );
    expect(h.session.isLinkReady, isTrue);
    await sub.cancel();
  });

  test('reconcile with no peer: scans and seeds the DB, reports idle',
      () async {
    // Alice has a file, no peer connected. reconcile must scan it into her
    // Index DB and report "Idle (no peer)".
    h.aliceFs.files['a.txt'] = utf8.encode('hello');
    await h.alice.startPair(h.pair);
    await h.alice.reconcile(h.pair, null);

    final st = h.alice.stateFor(h.pair.id)!;
    expect(st.status, 'Idle (no peer)');
    final db = await h.alice.openIndexDbFor(h.pair);
    expect(await db.liveCount(), 1);
    expect((await db.liveSnapshot()).single.relPath, 'a.txt');
    await db.close();
  });

  test('reconcile with peer but no snapshot: advertises then requests index',
      () async {
    // First reconcile with a live session must (step 2) advertise the delta as
    // an indexUpdate and (step 3) request Bob's index.
    h.aliceFs.files['a.txt'] = utf8.encode('hello');
    await h.alice.startPair(h.pair);

    h.connectAlice(); // wires session.onMessage → _handlePeerMessage
    await h.alice.reconcile(h.pair, h.session);
    await h.pump();

    final types = h.session.sent.map((m) => m['t'] as String).toSet();
    expect(types, contains(Msg.indexUpdate)); // step 2: advertise
    expect(types, contains(Msg.indexRequest)); // step 3: request
  });

  test(
      '_handleIndexFrame merges a peer index, advances the watermark, and ' +
          'kicks a reconcile that fetches the file', () async {
    // Bob has a file Alice lacks. Delivering Bob's advertisement to Alice must
    // merge it into _peerLive, advance _peerSeq, and kick a reconcile that
    // fetches the block from Bob. This is the full V2 happy path on one side.
    final content = utf8.encode('peer-content');
    h.bobFs.files['shared.txt'] = content;

    // Seed Alice's DB (startPair), then build a real IndexEntry for Bob's file
    // by scanning it through a throwaway IndexDb — exactly what a real peer
    // would advertise.
    await h.alice.startPair(h.pair);
    final bobEntry = await _scanOne(h.bobFs, h.pair, 'shared.txt', content);

    h.connectAlice();

    // Deliver Bob's advertisement as if it arrived on the wire.
    await h.deliverToAlice({
      't': Msg.indexUpdate,
      'pairId': h.pair.id,
      'folderId': h.pair.id,
      'entries': [bobEntry.toJson()],
      'fromSequence': 0,
    });
    // The kick → processNeeds → block fetch chain is async and the block
    // request/response round-trips through the mock serve below; pump until the
    // file materializes on Alice.
    await h.pumpUntil(() => h.aliceFs.files.containsKey('shared.txt'));

    // Content matches AND the whole-file sha was verified by the fetch.
    expect(h.aliceFs.files['shared.txt'], content);
    final aliceDb = await h.alice.openIndexDbFor(h.pair);
    final row = await aliceDb.get('shared.txt');
    expect(row, isNotNull);
    expect(row!.sha256, sha256.convert(content).toString());
    await aliceDb.close();
    // Alice issued a block request to Bob.
    expect(
      h.session.sent
          .any((m) => m['t'] == Msg.request && m['name'] == 'shared.txt'),
      isTrue,
    );
  });

  test('an empty indexUpdate does NOT kick a reconcile (no ping-pong)',
      () async {
    // The flaw-#1 guard: an empty delta doesn't advance maxSeq past priorSeq,
    // so no reconcile is kicked. Without it, both peers re-advertise empty
    // deltas forever in response to each other's kicks.
    h.connectAlice();
    await h.alice.startPair(h.pair);
    await h.alice.reconcile(h.pair, h.session);
    await h.pump();
    final updatesBefore =
        h.session.sent.where((m) => m['t'] == Msg.indexUpdate).length;

    // Empty delta: maxSeq stays at priorSeq → no kick.
    await h.deliverToAlice({
      't': Msg.indexUpdate,
      'pairId': h.pair.id,
      'folderId': h.pair.id,
      'entries': const [],
      'fromSequence': 0,
    });
    await h.pump(const Duration(milliseconds: 80)); // give a spurious kick room

    expect(
      h.session.sent.where((m) => m['t'] == Msg.indexUpdate).length,
      updatesBefore,
      reason: 'empty delta must not trigger a re-advertise',
    );
  });

  test('onPeerSessionLost clears V2 peer state so a reconnect re-requests',
      () async {
    // After session loss, _peerLive for the pair must be gone, so the next
    // reconcile re-requests the full index instead of diffing against a stale
    // snapshot.
    h.connectAlice();
    await h.alice.startPair(h.pair);

    // Simulate having received (and merged) an index — _peerLive is created.
    await h.deliverToAlice({
      't': Msg.indexUpdate,
      'pairId': h.pair.id,
      'folderId': h.pair.id,
      'entries': const [],
      'fromSequence': 0,
    });
    expect(h.alice.peerLiveFor(h.pair.id), isNotNull);

    h.alice.onPeerSessionLost(_bobDeviceId);
    expect(h.alice.peerLiveFor(h.pair.id), isNull,
        reason:
            'onPeerSessionLost must drop _peerLive for reconnect to refetch');
  });

  test('Msg.request for an unknown pair yields a terminal-error response',
      () async {
    // A request for a pair we don't know must reply with a single
    // response{error} so the fetcher treats it as terminal and drops the need
    // instead of looping.
    h.connectAlice();
    h.session.sent.clear();

    await h.deliverToAlice({
      't': Msg.request,
      'pairId': 'no-such-pair',
      'folderId': 'no-such-pair',
      'name': 'whatever.txt',
      'offset': 0,
      'size': 10,
    });
    await h.pump();

    final err = h.session.sent.lastWhere(
      (m) => m['t'] == Msg.response,
      orElse: () => <String, dynamic>{},
    );
    expect(err['error'], isNotNull);
    expect(err['name'], 'whatever.txt');
  });
}

// ---------------------------------------------------------------------------
// Harness: one engine + a fake peer session (no real sockets)
// ---------------------------------------------------------------------------

/// One [SyncEngine] (Alice) with a fake peer session standing in for Bob.
///
/// The engine is fully real (V2 path, FFI SQLite, FakeFs). The session captures
/// every `send` into [session.sent] and accepts injected frames via
/// [deliverToAlice], which routes them through the real
/// `_handlePeerMessage`. A second [FakeFs] (`bobFs`) backs the mocked serve
/// side for the fetch happy-path test.
class _Harness {
  _Harness._(
    this.tmp,
    this.alice,
    this.session,
    this.pair,
    this.aliceFs,
    this.bobFs,
  );

  final Directory tmp;
  final SyncEngine alice;
  final _FakeSession session;
  final FolderPair pair;
  final FakeFs aliceFs;
  final FakeFs bobFs;

  /// Per-deliver deadline so the serve loop can't spin forever if the handler
  /// never settles (a bug, not a normal path). Reset at the top of each
  /// [deliverToAlice] call.
  late DateTime _deliverDeadline;

  static Future<_Harness> create() async {
    final tmp = await Directory.systemTemp.createTemp('engine_v2_test_');

    final aliceStateDir = Directory(p.join(tmp.path, 'alice', 'support'));
    await aliceStateDir.create(recursive: true);

    final pair = FolderPair(
      id: 'pair-1',
      name: 'test',
      localPath: 'r',
      direction: SyncDirection.twoWay,
      peerDeviceId: _bobDeviceId,
    );

    final aliceFs = FakeFs();
    final bobFs = FakeFs();

    final cfgFile = File(p.join(tmp.path, 'alice', 'config.json'));
    // The pair MUST be in config.folderPairs — _pairById (used by every V2
    // handler) scans it, and the harness that pre-dated this one passed an
    // empty list, which silently no-op'd every V2 code path.
    final cfg = ConfigStore.forTest(cfgFile, {
      'folderPairs': [pair.toJson()],
      'pairedPeers': [
        PairedPeer(
          deviceId: _bobDeviceId,
          name: 'Bob',
          platform: 'test',
          publicKeyB64: '',
        ).toJson(),
      ],
    });

    final registry = PeerConnectionRegistry();
    final alice = SyncEngine(
      fs: aliceFs,
      config: cfg,
      stateDir: aliceStateDir,
      registry: registry,
      deviceId: _aliceDeviceId,
    );

    final session = _FakeSession(
      peer: PairedPeer(
        deviceId: _bobDeviceId,
        name: 'Bob',
        platform: 'test',
        publicKeyB64: '',
      ),
      bobFs: bobFs,
    );
    // Publish so the engine's registry lookups (generationOf / sessionFor)
    // resolve to this session, exactly as a real onPeerConnected would see.
    registry.publish(_bobDeviceId, session);

    return _Harness._(tmp, alice, session, pair, aliceFs, bobFs);
  }

  /// Run Alice's onPeerConnected so her engine owns the message handler. Must
  /// be called before [deliverToAlice]. (In a real run this is wired by the
  /// connection manager after the handshake.)
  void connectAlice() {
    alice.onPeerConnected(session);
  }

  /// Deliver a frame to Alice as if it arrived on the wire — invokes the
  /// engine's real inbound handler for [session]. Exercises the identical
  /// routing (gen-guard bypass, dedup, switch) the wire would.
  ///
  /// If the frame (or the reconcile it kicks) drives a block fetch, this also
  /// plays the serve side: it drains any `Msg.request`s Alice emits and feeds
  /// back matching `Msg.response`s from [bobFs], so the block-fetch happy path
  /// completes end-to-end.
  ///
  /// The handler and the serve loop run CONCURRENTLY. This is deliberate: a
  /// delivered `indexUpdate` that kicks a reconcile runs
  /// `_handleIndexFrame → reconcile(unawaited) → _processNeeds →
  /// _sendBlockRequest → _BlockSink.next()`, which blocks until a response
  /// arrives. If we awaited the handler, the serve loop that produces that
  /// response would never run — a single-thread deadlock. Instead we race
  /// them: each serve round pumps the event loop so the blocked handler
  /// advances.
  ///
  /// The subtle part is the EXIT condition. `_handleIndexFrame` returns almost
  /// immediately (its kick is fire-and-forget), so "the outer handler is done"
  /// is NOT "the work is done". The kicked reconcile runs concurrently, holds
  /// the pair's `scanning` lock until it finishes, and only reaches
  /// `_sendBlockRequest` some pumps after the outer handler returns. If the
  /// serve loop bailed as soon as the outer handler settled, the request would
  /// sit unanswered in `session.sent` and `_BlockSink.next()` would return
  /// null — the exact failure this used to hit. So the loop keeps serving while
  /// the pair is still scanning (the kicked reconcile holds that lock for its
  /// whole lifetime) OR a request is outstanding, and only exits once BOTH the
  /// outer handler is done AND the pair has gone idle AND nothing is pending.
  Future<void> deliverToAlice(Map<String, dynamic> frame) async {
    _deliverDeadline = DateTime.now().add(const Duration(seconds: 8));
    var handlerDone = false;
    final pending = alice.handlePeerMessageForTest(session, frame);
    pending.whenComplete(() => handlerDone = true);
    // Requests we've already answered. Tracked SEPARATELY from [session.sent]
    // (which we leave intact) so a test can still assert "Alice asked Bob for
    // this block" after delivery — the serve side playing Bob shouldn't erase
    // the evidence of the request. Identity is (name, offset): a fetch sends at
    // most one request per (file, offset), so this dedupes correctly.
    final served = <String>{};
    String reqKey(Map<String, dynamic> r) => '${r['name']}@${r['offset']}';
    // Serve loop: keep answering requests as long as work may still arrive —
    // the outer handler, any kicked reconcile (signalled by `scanning`), or a
    // request already on the wire. We only stop once everything has settled.
    while (true) {
      final req = _firstWhereOrNull(
        session.sent,
        (m) => m['t'] == Msg.request && !served.contains(reqKey(m)),
      );
      if (req != null) {
        served.add(reqKey(req));
        final resp = await _serveBlock(bobFs, req);
        // Feed the response through the real router so it hits _BlockSink.add.
        alice.handlePeerMessageForTest(session, resp);
      }
      await pump();
      // Done only when ALL of: outer handler settled, pair no longer scanning
      // (no kicked reconcile in flight), and no outstanding request to answer.
      final stillScanning = alice.stateFor(pair.id)?.scanning ?? false;
      final unserved = _firstWhereOrNull(
        session.sent,
        (m) => m['t'] == Msg.request && !served.contains(reqKey(m)),
      );
      if (handlerDone && !stillScanning && unserved == null) break;
      if (DateTime.now().isAfter(_deliverDeadline)) break;
    }
    try {
      await pending.timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  Future<void> pump([Duration d = const Duration(milliseconds: 20)]) =>
      Future<void>.delayed(d);

  Future<void> pumpUntil(bool Function() predicate,
      {Duration timeout = const Duration(seconds: 3)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (predicate()) return;
      await pump(const Duration(milliseconds: 15));
    }
    throw TimeoutException('pumpUntil timed out');
  }

  Future<void> dispose() async {
    // No real sockets and no heartbeat timers to cancel — just release the
    // engine. Closing the engine's controllers first means any lingering
    // serve-stream close can't fire log() into a closed controller (the crash
    // the loopback harness hit).
    await alice.dispose();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {
      // Windows sometimes holds the sqlite file briefly; the OS temp reaps it.
    }
  }
}

// ---------------------------------------------------------------------------
// Fake peer session
// ---------------------------------------------------------------------------

/// A [PeerSession] stand-in that captures sends and discards heartbeats.
///
/// Implements [PeerSession] and overrides only the members the V2 path touches
/// (peer, generation, send, onMessage, restartHeartbeat, handlePong). Anything
/// else would only be reached by the legacy path, which these tests don't run.
class _FakeSession implements PeerSession {
  _FakeSession({required this.peer, required this.bobFs});

  @override
  final PairedPeer peer;

  /// Fixed generation. The engine's gen-guard compares this against the
  /// registry's published generation; since we publish THIS session, they match.
  @override
  final int generation = 1;

  /// Every frame the engine asked this session to send. Tests assert on this
  /// directly — no stream taps, no delivery-timing races.
  final List<Map<String, dynamic>> sent = [];

  final FakeFs bobFs;

  /// Set by [SyncEngine.onPeerConnected] to the real `_handlePeerMessage`.
  /// Unused here (we inject via handlePeerMessageForTest), but onPeerConnected
  /// assigns it, so it must exist as a writable property.
  @override
  set onMessage(void Function(Map<String, dynamic> msg) handler) {}

  /// onPeerConnected assigns these (error/done channels for the socket). The
  /// fake has no socket, so they're no-op setters — present only so the engine
  /// can wire them without hitting noSuchMethod.
  @override
  set onError(void Function(Object error) handler) {}
  @override
  set onDone(void Function() handler) {}

  @override
  bool get isClosed => false;

  bool _linkReady = false;

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
    // Stamp a msgId the same way the real codec does (FrameCodec.send), so the
    // engine's idempotency guard (RecentMsgIds.saw) sees well-formed ids and
    // the dedup path behaves like the wire.
    msg['msgId'] ??= _nextMsgId();
    sent.add(msg);
  }

  // Heartbeat / lifecycle: all no-ops. The real session starts a 12s
  // Timer.periodic here; with these stubbed, no timer keeps the test zone
  // alive past the test body.
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

int _msgCounter = 0;
String _nextMsgId() => 'test-${++_msgCounter}';

// ---------------------------------------------------------------------------
// Serve-side helper (plays Bob for the block fetch)
// ---------------------------------------------------------------------------

/// Build the `Msg.response` for one `Msg.request` by reading the requested
/// slice from [fs]. Mirrors what `serveFileBlockLevel` would emit, so the
/// receiver's `fetchFileBlockLevel` verifies it identically.
Future<Map<String, dynamic>> _serveBlock(
  FakeFs fs,
  Map<String, dynamic> req,
) async {
  final name = req['name'] as String;
  final offset = (req['offset'] as num).toInt();
  final want = (req['size'] as num).toInt();
  final data = fs.files[name];
  if (data == null) {
    return {
      't': Msg.response,
      'pairId': req['pairId'],
      'folderId': req['folderId'],
      'name': name,
      'error': 'no such file',
    };
  }
  final end = (offset + want > data.length) ? data.length : offset + want;
  final block = data.sublist(offset, end);
  return {
    't': Msg.response,
    'pairId': req['pairId'],
    'folderId': req['folderId'],
    'name': name,
    'offset': offset,
    'length': block.length,
    'sha256': sha256.convert(block).toString(),
    'data': base64.encode(block),
  };
}

/// Scan exactly one file into a throwaway IndexDb and return its IndexEntry —
/// the wire shape a real peer would advertise. Gives the test a real (sha +
/// sequence + version) entry to deliver.
Future<IndexEntry> _scanOne(
  FakeFs fs,
  FolderPair pair,
  String relPath,
  List<int> content,
) async {
  final db = await IndexDb.open(
      '${pair.id}-bob',
      Directory(p.join(Directory.systemTemp.path,
          'engine_v2_bob_${DateTime.now().microsecondsSinceEpoch}')));
  try {
    await db.upsertLocal(
      relPath: relPath,
      size: content.length,
      mtime: 1,
      sha256: sha256.convert(content).toString(),
      deviceId: _bobDeviceId,
      blockHashes: _blockHashesFor(content),
    );
    return (await db.liveSnapshot()).single;
  } finally {
    await db.close();
  }
}

/// Per-block SHA-256 list for [content], split at [blockSize]. Same split the
/// fetch path verifies against.
List<String> _blockHashesFor(List<int> content) {
  final out = <String>[];
  for (var i = 0; i < content.length; i += blockSize) {
    final end =
        (i + blockSize > content.length) ? content.length : i + blockSize;
    out.add(sha256.convert(content.sublist(i, end)).toString());
  }
  return out;
}

T? _firstWhereOrNull<T>(Iterable<T> it, bool Function(T) test) {
  for (final e in it) {
    if (test(e)) return e;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Fake filesystem (same minimal surface as the block_transfer test FakeFs)
// ---------------------------------------------------------------------------

/// In-memory [FileSystemAccess]. Backs the engine's scan / read / write calls.
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
      throw UnsupportedError('not used by engine V2 tests');
}
