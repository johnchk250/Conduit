import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';

import '../core/config_store.dart';
import '../diag.dart';
import '../net/peer_registry.dart';
import '../net/peer_session.dart';
import '../protocol/wire.dart';
import '../storage/index_db.dart';
import 'block_transfer.dart';
import 'file_send.dart';
import 'index_diff.dart';
import 'manifest.dart';
import 'scanner.dart';
import 'watcher.dart';

/// Conservative folder-sync transfer pipeline. This changes only block request
/// scheduling; reconciliation, index state, and conflict resolution stay as-is.
const int _syncPipelineDepth = 4;

/// A folder-pair invite received from a peer, surfaced to the UI for the user
/// to accept (by picking a local folder) or decline.
class FolderPairInvite {
  final String pairId;
  final String name;
  final SyncDirection direction;
  final String peerDeviceId;
  final String peerName;

  FolderPairInvite({
    required this.pairId,
    required this.name,
    required this.direction,
    required this.peerDeviceId,
    required this.peerName,
  });
}

/// One unit of work the engine reports back to the UI.
class SyncEvent {
  final DateTime time;
  final String pairId;
  final String message;
  final SyncEventLevel level;

  SyncEvent(this.time, this.pairId, this.message, this.level);

  @override
  String toString() =>
      '[${time.toIso8601String()}] ${level.name.toUpperCase()} $pairId: $message';
}

enum SyncEventLevel { info, warn, error }

/// Outcome of the receive-time delete-vs-edit decision (Bug #6). See
/// [SyncEngine._applyRemoteTombstone] for the rule. The caller
/// ([SyncEngine._handleIndexFrame]) uses this to decide whether to store the
/// inbound tombstone (deleteWins / nothingToDecide) or discard it (editWins).
enum DeleteDecision {
  /// The delete's version dominates-or-equals our live version → bytes removed
  /// from disk; store the tombstone (deleted=1).
  deleteWins,

  /// Our concurrent local edit wins → bytes KEPT; do NOT store deleted=1 (a
  /// later sweep would then delete our edit). The peer's counter was merged
  /// into our live row so future dominance comparisons are accurate.
  editWins,

  /// No live prior row on disk (we never had the file) → nothing to delete;
  /// store the tombstone as-is.
  nothingToDecide,
}

/// Per-pair sync state surfaced to the UI.
class PairSyncState {
  final String pairId;
  bool scanning;
  bool transferring;
  double? progress; // 0..1 for current op
  String? status;
  DateTime? lastSyncedAt;

  PairSyncState({
    required this.pairId,
    this.scanning = false,
    this.transferring = false,
    this.progress,
    this.status,
    this.lastSyncedAt,
  });
}

/// The sync engine coordinates, per folder pair:
///   - watching the local folder for changes
///   - exchanging index snapshots with connected peers
///   - computing the needs-queue and applying version-vector ordering
///   - executing block-level fetch/push/delete transfers
class SyncEngine {
  SyncEngine({
    required this.fs,
    required this.config,
    required this.stateDir,
    required this.registry,
    required this.deviceId,
    this.onFolderInvite,
    this.onTransferState,
    this.onClipboardPush,
    this.onRunCommand,
    this.batchListWithStat,
  });

  final FileSystemAccess fs;
  final ConfigStore config;

  /// App-private directory for sync metadata (Index DBs). NEVER inside the
  /// synced folder — on Android that's a SAF `content://` URI that dart:io
  /// can't touch.
  final Directory stateDir;

  /// Shared with AppState. THE single source of truth for "which session is
  /// live for peer X". Step 4: this replaces the old mutable
  /// `_connectedSessionForPeer` field, which was a second bookkeeping source
  /// that disagreed with AppState's and got overwritten by churn reconnects.
  final PeerConnectionRegistry registry;

  /// THIS device's fingerprint (e.g. "7534-8B2A"). Used to bump the correct
  /// per-device counter in [VersionVector]s written by the scanner and Index DB.
  final String deviceId;

  /// Callback to the UI layer when a folder-pair invite arrives from a peer.
  /// The UI shows an accept/decline dialog; on accept it calls
  /// [acceptFolderInvite] with the user-picked local path.
  final void Function(FolderPairInvite invite)? onFolderInvite;

  /// Notifies the host whenever the engine enters/leaves an active transfer
  /// (Roadmap Phase 0.4). The host uses this to acquire a short, renewable
  /// Android wake lock only while bytes are actually moving, so Doze is free to
  /// take over on an idle folder. Engine-safe by construction: this callback is
  /// invoked OUTSIDE the sync critical path and only flips a host-owned flag —
  /// it touches none of the V2 engine's load-bearing invariants.
  final void Function(bool transferring)? onTransferState;

  /// Notifies the host when a peer pushes its clipboard (Roadmap Phase 2).
  /// The host writes its own clipboard via Flutter `Clipboard.setData`. This is
  /// engine-safe by construction: it is invoked from a single appended branch of
  /// `_handlePeerMessage`, OUTSIDE the reconcile/needs-queue path, and touches
  /// none of the V2 load-bearing invariants. The text never enters the Index DB
  /// or the version-vector machinery.
  final void Function(String peerId, String text)? onClipboardPush;

  /// Notifies the host when a peer sends a remote-control command (Roadmap
  /// Phase 4). The host validates the name against the allowlist and executes
  /// the OS action (Windows only). Engine-safe: invoked from a single appended
  /// branch of `_handlePeerMessage`, never touches the Index DB, version
  /// vectors, or the needs-queue. Silently ignored on Android.
  final void Function(String peerId, String name)? onRunCommand;

  /// Optional fast-path metadata lister (Roadmap Phase 0.6 — battery). Passed
  /// straight through to every [FolderWatcher] this engine starts and to
  /// every [IndexScanner.scan] call. On Android, [AppState] wires this to
  /// [SafFileSystemAccess.listFilesWithStat] — one ContentResolver query per
  /// directory instead of one [FileSystemAccess.stat] round trip per file.
  /// Null on every other platform, which leaves [FolderWatcher] and
  /// [IndexScanner] behaving exactly as they did before this field existed.
  final Future<List<FileEntry>> Function(String rootPath)? batchListWithStat;

  /// Ad-hoc file send / auto-receive handler (Roadmap Phase 3a). Set by
  /// [AppState] after construction. Null until initialised. The three
  /// [Msg.fileOffer] / [Msg.fileOfferBlock] / [Msg.fileOfferData] cases in
  /// [_handlePeerMessage] route to this; [onPeerSessionLost] cancels any
  /// in-flight offers for the lost peer. Never touches the Index DB or any
  /// V2 sync invariant.
  AdHocFileSend? adHocSend;

  final _watchers = <String, FolderWatcher>{}; // pairId -> watcher
  final _states = <String, PairSyncState>{};
  final _events = <SyncEvent>[];
  final _stateController = StreamController<PairSyncState>.broadcast();
  final _eventController = StreamController<SyncEvent>.broadcast();

  /// pairIds that the peer has accepted via folderAccept. Reconciliation is
  /// gated on this — we won't exchange indexes for a pair until the peer
  /// has confirmed it.
  final _peerAcceptedPairs = <String>{};

  /// Pending invites keyed by pairId, so the UI can re-display them and so
  /// we don't surface the same invite twice.
  final _pendingInvites = <String, FolderPairInvite>{};

  /// Recently-seen message ids, for idempotent handling. A reconnect or a
  /// retry can deliver a message we already processed (e.g. a duplicate
  /// manifest or chunk re-sent because an ACK was lost). Without this guard,
  /// such duplicates double-apply side effects — worst case, a duplicate
  /// chunk deserializes a fetch that's already complete. With it, the second
  /// delivery is dropped silently and logged via [Diag].
  ///
  /// Bounded by both a hard cap (evict oldest on overflow) and a TTL sweep
  /// (entries older than [_recentTtl] are evicted opportunistically). Handshake
  /// messages (hello/welcome) bypass this — they're handled before the engine
  /// takes ownership and are inherently single-use via Completer.
  final _recent = RecentMsgIds();

  // ---- Index DB engine (REDESIGN.md Phase 2) ------------------------------
  //
  // The V2 model (REDESIGN.md §"Target architecture"): a persistent SQLite
  // Index DB per folder is the source of truth; Index/IndexUpdate frames carry
  // deltas filtered by monotonic sequence; Request/Response frames move blocks
  // with terminal-error semantics (a single Response{error} drops a file from
  // the needs-queue — no retry storm, kills flaw #2).

  /// Cached open Index DBs, keyed by pairId. One DB file per folder pair under
  /// `<stateDir>/index/<safePairId>.db`. Opened lazily by [_indexDbFor] and
  /// closed in [stopPair] / [dispose]. Surviving a reconnect is the whole
  /// point — the durable index survives across sessions.
  final _indexDbs = <String, IndexDb>{};

  /// Filesystem scanner (decoupled from sync — REDESIGN.md §(4)). One shared
  /// instance; the scanner is stateless across pairs (all per-folder state lives
  /// in the Index DB it writes to).
  final _scanner = IndexScanner();

  /// Highest peer-sequence we have APPLIED, per (peer, pair). Keyed
  /// `"$peerId|$pairId"`. Drives the response to an `indexRequest`
  /// (`db.changesSince(watermark)`) AND guards `indexUpdate` dedup
  /// (`IndexDb.applyRemote` already drops stale rows, but we keep the watermark
  /// so the advertised `fromSequence` we echo is honest).
  final _peerSeq = <String, int>{};

  /// Highest local-sequence we have ADVERTISED to a peer, per (peer, pair).
  /// Keyed `"$peerId|$pairId"`. So an `IndexUpdate` only carries rows whose
  /// sequence is past what that peer has already seen — no re-sending the whole
  /// folder on every reconcile.
  final _sentSeq = <String, int>{};

  /// Live peer snapshot per pair, materialized from received Index/IndexUpdate
  /// frames. Keyed by pairId → {relPath: IndexEntry}. Drives [indexDiff] on the
  /// receiver side. In-memory only — the durable record of "what does my peer
  /// have" is also written into our own Index DB via `applyRemote`, but the diff
  /// wants a flat live map keyed by path, which is cheaper to keep here than to
  /// rebuild from a SQLite query on every reconcile.
  final _peerLive = <String, Map<String, IndexEntry>>{};

  /// Active block-fetch sinks, keyed by `"$pairId|$name"`. The `Msg.response`
  /// handler routes each incoming response into the sink for the file it's a
  /// reply to; [fetchFileBlockLevel]'s `sendRequest` pulls the next response
  /// out of it. Closed by [onPeerSessionLost] so a mid-fetch reconnect makes
  /// `next()` return null → `fetchFileBlockLevel` throws StateError → reconcile
  /// catch → ends.
  final _blockSinks = <String, _BlockSink>{};

  /// Serve-side request streams, keyed by `"$pairId|$name"`. The first
  /// `Msg.request` for a (pair, file) opens one and spawns a
  /// [serveFileBlockLevel] that drains it; subsequent requests for the same
  /// file flow into the SAME stream so the serve loop responds in order. Closed
  /// on session loss. Keyed per-file rather than per-pair so two concurrent
  /// fetches of different files don't interleave on one stream.
  final _serveStreams = <String, StreamController<Map<String, dynamic>>>{};

  Stream<PairSyncState> get stateChanges => _stateController.stream;
  Stream<SyncEvent> get events => _eventController.stream;
  List<SyncEvent> get eventLog => List.unmodifiable(_events);
  PairSyncState? stateFor(String pairId) => _states[pairId];
  List<FolderPairInvite> get pendingInvites =>
      _pendingInvites.values.toList(growable: false);

  bool _disposed = false;

  // ---- Roadmap Phase 0 + Phase 1 (additive wiring) --------------------------
  //
  // The fields below are NEW state added by the reliability/battery/background
  // work. None of them flow through indexDiff / _applyRemoteTombstone /
  // upsertLocal / confirmLocalObservation / VersionVector — the three
  // load-bearing invariants (§0 of Roadmap.md / §9.2 of ARCHITECTURE.md) are
  // untouched. Everything is wiring: timers that call the existing
  // [reconcile], flags that gate the periodic tick, and callbacks that flip a
  // host-owned wake lock.

  /// Per-pair periodic reconcile safety-net timers (Roadmap Phase 0.1).
  ///
  /// Sync is otherwise 100% event-driven (a watcher tick, a peer connect, or
  /// an inbound IndexUpdate). If a watcher tick misses an edit — possible on a
  /// rapid edit that lands with an identical size/colliding mtime, or a lost
  /// SAF tick — the drift would sit until the next reconnect, which can be
  /// hours. This map holds one long-interval (30 min) Timer per pair that
  /// calls [reconcile] while a session is live, closing that hole. Relies on
  /// the existing re-entrancy guard (`if (st.scanning) return;` at the top of
  /// [reconcile]) and the no-op-invariant (idle folder burns zero sequences),
  /// so a periodic tick on an already-in-sync pair is free.
  final _periodicTimers = <String, Timer>{};
  static const _periodicInterval = Duration(minutes: 30);

  /// True while ANY pair is actively transferring bytes. Drives the
  /// [onTransferState] callback so the host can hold a wake lock only during a
  /// real transfer (Roadmap Phase 0.4).
  int _activeTransferCount = 0;

  /// When true, the engine refuses to run a reconcile (Roadmap Phase 1 —
  /// "Pause sync"). The tray menu / Android UI flip this so the user can stop
  /// syncing without quitting the app. Idle-only: in-flight transfers are
  /// allowed to complete; the pause takes effect on the NEXT reconcile.
  bool _paused = false;
  bool get isPaused => _paused;

  /// Hourly DB backup timer (Roadmap Phase 0.5). Runs [IndexDb.backup] on every
  /// open Index DB so a corrupt main file can be recovered from `.bak`.
  Timer? _backupTimer;

  /// Watcher poll intervals (Roadmap Phase 0.2 + Battery-Saver Polish).
  ///
  /// Battery-saver mode replaces both the fast and slow intervals with a
  /// 1-hour cadence. The Phase 0.1 30-min periodic reconcile continues to run
  /// independently, catching peer-side changes regardless of local watcher
  /// frequency. In battery-saver mode the watcher's sole remaining job is to
  /// seed the index on startup (done once) and then provide one "something
  /// changed locally" signal per hour — an adequate safety net for users who
  /// prioritise battery over real-time local-change latency.
  bool _batterySaverMode = false;

  static const _watcherIntervalFast = Duration(seconds: 4);
  static const _watcherIntervalSlow = Duration(seconds: 30);
  static const _watcherIntervalBatterySaver = Duration(hours: 1);

  /// The interval to use for a peer that is currently ONLINE, accounting for
  /// battery-saver mode.
  Duration get _onlineInterval =>
      _batterySaverMode ? _watcherIntervalBatterySaver : _watcherIntervalFast;

  /// The interval to use for a peer that is currently OFFLINE, accounting for
  /// battery-saver mode.
  Duration get _offlineInterval =>
      _batterySaverMode ? _watcherIntervalBatterySaver : _watcherIntervalSlow;

  /// Toggle battery-saver mode at runtime (called from [AppState] when the
  /// user flips the setting). Immediately re-applies watcher intervals to all
  /// running watchers so the change takes effect without a restart.
  void setBatterySaverMode(bool enabled) {
    if (_batterySaverMode == enabled) return;
    _batterySaverMode = enabled;
    // Re-apply intervals to every running watcher.
    for (final pair in config.folderPairs) {
      final peerId = pair.peerDeviceId;
      final isOnline = peerId != null &&
          registry.openSessionFor(peerId)?.isLinkReady == true;
      _watchers[pair.id]
          ?.setInterval(isOnline ? _onlineInterval : _offlineInterval);
    }
  }

  /// Start watching a folder pair. Initial full scan happens immediately.
  Future<void> startPair(FolderPair pair) async {
    if (_watchers.containsKey(pair.id)) return;
    _states[pair.id] = PairSyncState(pairId: pair.id, status: 'Idle');

    final w = FolderWatcher(
      fs: fs,
      rootPath: pair.localPath,
      batchListWithStat: batchListWithStat,
    );
    w.changes.listen((_) => _onLocalChange(pair));
    _watchers[pair.id] = w;
    // Phase 0.2 + Battery-Saver: start in the appropriate poll state. In
    // battery-saver mode both online/offline use the 1-hour cadence. In normal
    // mode: start fast if online (peer connected), slow if offline.
    final startsOffline = pair.peerDeviceId == null ||
        registry.openSessionFor(pair.peerDeviceId!)?.isLinkReady != true;
    w.setInterval(startsOffline ? _offlineInterval : _onlineInterval);
    w.start();

    // Phase 0.1: arm the periodic reconcile safety-net for this pair. It only
    // fires while a live session exists (see _periodicTick) and is a no-op on an
    // already-in-sync folder (reconcile's re-entrancy guard + no-op-invariant).
    _periodicTimers.remove(pair.id)?.cancel();
    _periodicTimers[pair.id] = Timer.periodic(_periodicInterval, (_) {
      _periodicTick(pair);
    });

    log(pair.id, 'Watching "${pair.localPath}"', SyncEventLevel.info);
    // Open the Index DB eagerly and seed it with one full scan so the
    // durable source of truth exists before any peer connects.
    final db = await _indexDbFor(pair);
    await _scanner.scan(
      fs: fs,
      db: db,
      rootPath: pair.localPath,
      deviceId: deviceId,
      batchListWithStat: batchListWithStat,
    );
    log(pair.id, 'Index seeded', SyncEventLevel.info);
    // If a peer is already connected, kick the first reconcile; otherwise
    // the next onPeerConnected (or local change) will.
    final peerId = pair.peerDeviceId;
    final session = peerId == null ? null : registry.openSessionFor(peerId);
    if (session != null && session.isLinkReady) {
      await reconcile(pair, session);
    }
  }

  /// One tick of the periodic reconcile safety-net (Roadmap Phase 0.1).
  ///
  /// Fires every [_periodicInterval] per pair while a session is live. It is a
  /// no-op when (a) no session exists (nothing to reconcile toward), (b) the
  /// engine is paused, or (c) a reconcile is already running (the re-entrancy
  /// guard inside [reconcile] also catches this). On an in-sync folder the
  /// resulting reconcile burns zero sequences (the no-op-invariant), so this
  /// closes the watcher-miss hole at effectively zero cost.
  void _periodicTick(FolderPair pair) {
    if (_disposed) return;
    final peerId = pair.peerDeviceId;
    if (peerId == null) return;
    final session = registry.openSessionFor(peerId);
    if (session == null || !session.isLinkReady) return;
    if (_paused) return;
    reconcile(pair, session);
  }

  Future<void> stopPair(String pairId) async {
    final w = _watchers.remove(pairId);
    await w?.stop();
    _periodicTimers.remove(pairId)?.cancel();
    // V2: close the Index DB and drop per-pair V2 bookkeeping so a re-added
    // pair reopens cleanly. Closing is best-effort — the file stays on disk
    // and survives a restart; this just releases the SQLite handle.
    final db = _indexDbs.remove(pairId);
    if (db != null) {
      try {
        await db.close();
      } catch (_) {}
    }
    _peerLive.remove(pairId);
    _peerSeq.removeWhere((k, _) => k.endsWith('|$pairId'));
    _sentSeq.removeWhere((k, _) => k.endsWith('|$pairId'));
    // Drop any in-flight block fetches/serve streams for this pair.
    final blockKeys =
        _blockSinks.keys.where((k) => k.startsWith('$pairId|')).toList();
    for (final k in blockKeys) {
      _blockSinks.remove(k)?.close();
    }
    final serveKeys =
        _serveStreams.keys.where((k) => k.startsWith('$pairId|')).toList();
    for (final k in serveKeys) {
      await _serveStreams.remove(k)?.close();
    }
  }

  /// Open (or return the cached) Index DB for [pair]. Cached in [_indexDbs] so
  /// repeated calls during a reconcile don't reopen the file. Closed in
  /// [stopPair] / [dispose]. Idempotent — [IndexDb.open] itself upgrades an
  /// existing file's schema if needed.
  Future<IndexDb> _indexDbFor(FolderPair pair) async {
    return _indexDbs[pair.id] ??= await IndexDb.open(pair.id, stateDir);
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final id in _watchers.keys.toList()) {
      await stopPair(id);
    }
    // Phase 0.1 / 0.5: cancel the periodic reconcile + backup timers.
    for (final t in _periodicTimers.values) {
      t.cancel();
    }
    _periodicTimers.clear();
    _backupTimer?.cancel();
    _backupTimer = null;
    // V2: release any block sinks / serve streams still outstanding (e.g. a
    // serve loop spawned for a peer whose pair had no local watcher, or one
    // still draining when dispose was called). stopPair covers the per-pair
    // case; this is the whole-engine sweep so nothing leaks a handle or tries
    // to session.send after the engine is gone.
    for (final sink in _blockSinks.values.toList()) {
      sink.close();
    }
    _blockSinks.clear();
    for (final ctrl in _serveStreams.values.toList()) {
      await ctrl.close();
    }
    _serveStreams.clear();
    await _stateController.close();
    await _eventController.close();
  }

  void log(String pairId, String msg, SyncEventLevel level) {
    final e = SyncEvent(DateTime.now(), pairId, msg, level);
    _events.insert(0, e);
    if (_events.length > 500) _events.removeRange(500, _events.length);
    _eventController.add(e);
  }

  void _setStatus(String pairId, String s) {
    final st = _states[pairId];
    if (st == null) return;
    st.status = s;
    _stateController.add(st);
  }

  Future<void> _onLocalChange(FolderPair pair) async {
    log(pair.id, 'Local change detected', SyncEventLevel.info);
    final session = registry.openSessionFor(pair.peerDeviceId ?? '');
    if (session == null || !session.isLinkReady) {
      _setStatus(pair.id, 'Waiting for peer');
      return;
    }
    await reconcile(pair, session);
  }

  /// Called by the app layer when a session becomes available.
  ///
  /// Step 2 fix: take ownership of incoming messages by setting
  /// `session.onMessage` — a synchronous reassignment. There is no
  /// "subscribe after publish" race because the codec has exactly one
  /// callback slot and we are now it. Every subsequent message flows
  /// straight into `_handlePeerMessage` with zero drop window.
  ///
  /// Step 1 fix: start the heartbeat so a half-dead peer is detected within
  /// ~72s (6 x 12s intervals) instead of waiting for TCP keepalive.
  void onPeerConnected(PeerSession session) {
    Diag.session('session_established',
        peer: session.peer.deviceId, session: session.generation);
    // Take ownership of this session's incoming messages.
    session.onMessage = (msg) => _handlePeerMessage(session, msg);
    session.onError = (e) {
      final currentGen = registry.generationOf(session.peer.deviceId);
      if (currentGen != null && currentGen != session.generation) {
        Diag.session('stale_session_error',
            peer: session.peer.deviceId,
            session: session.generation,
            fields: {'currentGen': currentGen, 'error': e.toString()});
        return;
      }
      log('', 'Session error (${session.peer.deviceId}): $e',
          SyncEventLevel.error);
    };
    session.onDone = () {
      final currentGen = registry.generationOf(session.peer.deviceId);
      if (currentGen != null && currentGen != session.generation) {
        Diag.session('stale_socket_done',
            peer: session.peer.deviceId,
            session: session.generation,
            fields: {'currentGen': currentGen});
        return;
      }
      // socket.done fired (clean close, crash, or network drop). The bye
      // message path handles intentional disconnects faster; this is the
      // fallback for everything else.
      log('', 'Socket closed for ${session.peer.deviceId}',
          SyncEventLevel.warn);
    };
    // Heartbeat: drop the session if the peer stops responding.
    //
    // Generation guard: a heartbeat death-notice is asynchronous (it fires
    // from a Timer ~72s after the session went silent). By the time it fires,
    // a NEW session for this peer may already be live (reconnect). The guard
    // compares the generation of the session that died against the registry's
    // current generation for this peer — if they differ, the dead session
    // was already superseded and we must NOT close its replacement.
    final deadGen = session.generation;
    final peerId = session.peer.deviceId;
    session.startHeartbeat(onDead: () {
      if (registry.generationOf(peerId) != deadGen) {
        Diag.session('gen_mismatch',
            peer: peerId,
            session: deadGen,
            fields: {'currentGen': registry.generationOf(peerId)});
        return; // this session was superseded — leave the new one alone
      }
      log('', 'Heartbeat timeout for $peerId — closing', SyncEventLevel.warn);
      session.close();
    });
  }

  void _onPeerLinkReady(PeerSession session) {
    log('', 'Connected to ${session.peer.name} (${session.peer.deviceId})',
        SyncEventLevel.info);

    // Reconcile every pair that the peer has already accepted. Pairs we've
    // invited but the peer hasn't accepted yet are skipped.
    for (final pair in config.folderPairs) {
      if (_peerAcceptedPairs.contains(pair.id) ||
          pair.peerDeviceId == session.peer.deviceId) {
        reconcile(pair, session);
      } else {
        _setStatus(pair.id, 'Waiting for peer to accept');
      }
    }
    // Phase 0.2: a peer just came online: restore the snappy watcher cadence
    // for every pair bound to it, so a real edit is caught quickly.
    _setWatcherBackoffForPeer(session.peer.deviceId, online: true);
  }

  void onPeerDisconnected(String deviceId) {
    log('', 'Peer disconnected ($deviceId)', SyncEventLevel.warn);
    for (final pair in config.folderPairs) {
      _setStatus(pair.id, 'Peer offline');
    }
    // Phase 0.2: the peer went offline — stretch that peer's watchers back to
    // the slow cadence (nothing to sync toward right now). Idempotent and safe:
    // when the last peer for a pair leaves, the watcher slows; the next connect
    // speeds it up again.
    _setWatcherBackoffForPeer(deviceId, online: false);
  }

  /// Flip the watcher cadence for every pair bound to [deviceId] (Roadmap
  /// Phase 0.2 + Battery-Saver Polish). In battery-saver mode the interval
  /// never changes — both online/offline use the 1-hour cadence, so
  /// `online: true` and `online: false` are equivalent. In normal mode:
  /// `online: true` restores the fast 4s poll; `online: false` stretches it
  /// to 30s (a detected change has nowhere to go until the peer reconnects,
  /// so the extra SAF scans are pure battery waste).
  ///
  /// Safe against partial states: a pair whose peer matches [deviceId] but has
  /// no watcher yet is a no-op, as is a watcher whose interval is already the
  /// target (see [FolderWatcher.setInterval]).
  void _setWatcherBackoffForPeer(String deviceId, {required bool online}) {
    final target = online ? _onlineInterval : _offlineInterval;
    for (final pair in config.folderPairs) {
      if (pair.peerDeviceId != deviceId) continue;
      _watchers[pair.id]?.setInterval(target);
    }
  }

  // ---- Phase 1 pause/quit (background survival) ----------------------------
  //
  // Pause is an idle-only stop: in-flight transfers finish, but no NEW
  // reconcile starts while paused. Resume immediately kicks a reconcile on
  // every live pair so any drift accumulated during the pause is caught up.

  /// Pause all sync activity (Roadmap Phase 1). Future [reconcile] calls
  /// return immediately until [resumeSync] is called. Serving inbound block
  /// requests is unaffected — a paused device still honors a peer's pull.
  void pauseSync() {
    if (_paused) return;
    _paused = true;
    log('', 'Sync paused', SyncEventLevel.info);
    for (final pair in config.folderPairs) {
      _setStatus(pair.id, 'Paused');
    }
  }

  /// Resume sync activity after [pauseSync]. Kicks a reconcile on every pair
  /// with a live session so any drift accrued while paused is caught up.
  void resumeSync() {
    if (!_paused) return;
    _paused = false;
    log('', 'Sync resumed', SyncEventLevel.info);
    for (final pair in config.folderPairs) {
      final peerId = pair.peerDeviceId;
      final session = peerId == null ? null : registry.openSessionFor(peerId);
      if (session != null && session.isLinkReady) {
        reconcile(pair, session);
      } else {
        _setStatus(pair.id, 'Idle');
      }
    }
  }

  /// Cancel in-flight sync work owned by a session that's being torn down
  /// (user disconnect, socket drop, or replacement by a newer session).
  ///
  /// Closes block-fetch sinks and serve streams so in-flight transfers unwind
  /// cleanly and the replacement session can reconcile immediately.
  void onPeerSessionLost(String peerDeviceId) {
    final affectedPairs = config.folderPairs
        .where((p) => p.peerDeviceId == peerDeviceId)
        .map((p) => p.id)
        .toSet();
    if (affectedPairs.isEmpty) return;

    // Close block sinks so any in-flight fetchFileBlockLevel's `next()`
    // returns null → it throws StateError → _processNeeds' catch logs + moves
    // on → `scanning` clears via reconcile's finally.
    // Closing serve streams ends any serveFileBlockLevel we're running for the
    // peer. We also drop _peerLive so the next reconcile re-issues an
    // indexRequest against the fresh session instead of diffing against a
    // snapshot from the dead one (and _peerSeq is reset so a re-request
    // starts from 0 if we never confirmed an apply on the new session).
    final blockKeys = _blockSinks.keys
        .where((k) => affectedPairs.any((p) => k.startsWith('$p|')))
        .toList();
    for (final key in blockKeys) {
      _blockSinks.remove(key)?.close();
    }
    final serveKeys = _serveStreams.keys
        .where((k) => affectedPairs.any((p) => k.startsWith('$p|')))
        .toList();
    for (final key in serveKeys) {
      _serveStreams.remove(key)?.close();
    }
    for (final pairId in affectedPairs) {
      _peerLive.remove(pairId);
    }
    _peerSeq.removeWhere((k, _) =>
        affectedPairs.any((p) => k.endsWith('|$p')) &&
        k.startsWith('$peerDeviceId|'));
    _sentSeq.removeWhere((k, _) =>
        affectedPairs.any((p) => k.endsWith('|$p')) &&
        k.startsWith('$peerDeviceId|'));

    // Phase 3a: cancel any in-flight ad-hoc file offers for this peer.
    // AdHocFileSend.onSessionLost closes their sinks/streams so the receive
    // and serve coroutines terminate cleanly without lingering memory.
    adHocSend?.onSessionLost(peerDeviceId);

    Diag.session('session_lost',
        peer: peerDeviceId, fields: {'pairs': affectedPairs.length});
  }

  // ---- Reconciliation ----------------------------------------------------

  Future<void> reconcile(FolderPair pair, PeerSession? session) async {
    final st = _states[pair.id] ??= PairSyncState(pairId: pair.id);
    if (st.scanning) return; // already busy
    // Phase 1 pause: don't START a new reconcile while paused. In-flight work
    // is allowed to finish (this returns before taking the scanning lock only
    // when nothing is running). Serving inbound block requests is unaffected —
    // that path doesn't go through reconcile, so a paused device still honors
    // a peer's pull without re-syncing its own side.
    if (_paused) {
      st.status = 'Paused';
      if (!_disposed) _stateController.add(st);
      return;
    }
    st.scanning = true;
    st.status = 'Scanning';
    _stateController.add(st);
    try {
      await _reconcileV2(pair, session, st);
    } catch (e) {
      st.status = 'Error';
      log(pair.id, 'Sync error: $e', SyncEventLevel.error);
    } finally {
      st.scanning = false;
      st.transferring = false;
      if (!_disposed) _stateController.add(st);
    }
  }

  // ---- Reconciliation (REDESIGN.md Phase 2) -----------------------------
  //
  // The V2 reconcile is transport-driven and stateless across reconnects:
  //   - The Index DB is the durable source of truth (no per-reconcile rebuild).
  //   - We ADVERTISE our delta once per reconcile (IndexUpdate past the peer's
  //     watermark) instead of exchanging full manifests every time. This kills
  //     the legacy manifest race (flaw #1) structurally.
  //   - Needs are derived by sha comparison (Phase 4 will use version vectors).
  //   - Fetches are block-level with terminal-error semantics — one
  //     Response{error} drops the file from the queue, no retry storm (flaw #2).
  //
  // No 15s manifest-timeout await, no "last synced" snapshot, no
  // generation-guarded waiters: every V2 frame either applies to the DB
  // (idempotent via sequence) or routes to a keyed sink. Reconnect = "send me
  // past my watermark", answered by the peer's stored Index DB — no rebuild.

  /// V2 reconcile. [st] is the pair's state (already `scanning = true`, set by
  /// the [reconcile] wrapper). The wrapper's finally clears `scanning`, so this
  /// method must NOT clear it itself — only set human-readable status.
  Future<void> _reconcileV2(
    FolderPair pair,
    PeerSession? session,
    PairSyncState st,
  ) async {
    final db = await _indexDbFor(pair);

    // 1. Scan local → DB. upsertLocal/markDeletedLocal are no-ops on unchanged
    //    files, so this burns no sequence on an idle folder (the key invariant
    //    that keeps a no-op reconcile from re-advertising the whole folder).
    // 1. Delete-propagation sweep (Bug #6). Runs FIRST, before the scan, so a
    //    tombstoned file still on disk is removed before the scanner can see its
    //    bytes and re-live the row. (A tombstone with localSha='' and bytes on
    //    disk would otherwise be re-resurrected by upsertLocal.) This also
    //    cleans the pre-fix backlog of orphan files whose tombstones were stored
    //    by the old Phase 2 path. Idempotent — fs.stat returns null once the file
    //    is gone, so subsequent passes are no-ops.
    await _propagateRemoteDeletes(pair);

    // 2. Scan local → DB. upsertLocal/markDeletedLocal are no-ops on unchanged
    //    files, so this burns no sequence on an idle folder (the key invariant
    //    that keeps a no-op reconcile from re-advertising the whole folder).
    final scan = await _scanner.scan(
      fs: fs,
      db: db,
      rootPath: pair.localPath,
      deviceId: deviceId,
      batchListWithStat: batchListWithStat,
    );

    if (session == null) {
      // No peer: the DB is now current. Needs/fetch can't run without a peer.
      st.lastSyncedAt = DateTime.now();
      st.status = 'Idle (no peer)';
      _stateController.add(st);
      log(pair.id, 'V2 scan complete (${scan.changed.length} changed), no peer',
          SyncEventLevel.info);
      return;
    }

    // 2. Advertise our delta to the peer. `_sentSeq` records the watermark
    //    we've already told THIS peer about, so this is usually a small (often
    //    empty) IndexUpdate. On the very first exchange the watermark is 0 and
    //    the peer treats it as a full Index.
    await _advertiseDelta(pair, session, db);

    // 3. If we don't yet have the peer's live snapshot for this pair, ask for
    //    it. Needs can't be computed without it, and fetch can't run without
    //    needs. The peer's `indexRequest` handler replies with an `index`/
    //    `indexUpdate` frame; that handler computes needs + fetches. So this
    //    reconcile ends here — work resumes when the index arrives.
    final peerKey = _peerKey(session.peer.deviceId, pair.id);
    if (!_peerLive.containsKey(pair.id)) {
      session.send({
        't': Msg.indexRequest,
        'pairId': pair.id,
        'fromSequence': _peerSeq[peerKey] ?? 0,
      });
      st.status = 'Requesting peer index';
      _stateController.add(st);
      Diag.log('v2_index_request',
          peer: session.peer.deviceId, pairId: pair.id);
      return;
    }

    // 4. We have a peer snapshot → compute needs and fetch. This is the only
    //    step that moves bytes in this reconcile; the advertise above let the
    //    peer compute ITS needs symmetrically.
    await _processNeeds(pair, session, db, st);
  }

  /// Send an `indexUpdate` carrying every local row past the watermark we've
  /// already advertised to this peer. Updates [_sentSeq] to the new watermark
  /// (the DB's max sequence) on success. Empty deltas are still sent so the
  /// peer learns we're alive and can correlate — but a peer receiving an empty
  /// IndexUpdate just advances its watermark and does nothing else.
  Future<void> _advertiseDelta(
    FolderPair pair,
    PeerSession session,
    IndexDb db,
  ) async {
    final peerKey = _peerKey(session.peer.deviceId, pair.id);
    final isFirstAdvertise = !_sentSeq.containsKey(peerKey);
    final fromSeq = _sentSeq[peerKey] ?? 0;
    // Only advertise rows WE wrote — rows from applyRemote belong to the peer
    // and re-advertising them is wasteful.
    final delta = await db.changesSinceLocal(fromSeq, deviceId);
    if (delta.isEmpty && !isFirstAdvertise) {
      // Already advertised up to this watermark and no new changes. Skip!
      return;
    }
    final maxSeq = delta.isEmpty ? await db.maxSequence() : delta.last.sequence;
    session.send({
      't': Msg.indexUpdate,
      'pairId': pair.id,
      'folderId': pair.id,
      'entries': delta.map((e) => e.toJson()).toList(),
      'fromSequence': fromSeq,
    });
    _sentSeq[peerKey] = maxSeq;
    Diag.log('v2_advertise',
        peer: session.peer.deviceId,
        pairId: pair.id,
        fields: {'sent': delta.length, 'fromSeq': fromSeq, 'toSeq': maxSeq});
  }

  /// Compute needs from the live snapshots and fetch each one block-by-block.
  /// A [TerminalFetchError] (peer's source file vanished) drops that one file
  /// from the queue without retry — the next IndexUpdate re-adds it if the file
  /// reappears (REDESIGN.md §(5), kills flaw #2).
  Future<void> _processNeeds(
    FolderPair pair,
    PeerSession session,
    IndexDb db,
    PairSyncState st,
  ) async {
    // Use localSnapshot (not liveSnapshot) so that rows we haven't fetched yet
    // are excluded from "what WE have": a freshly-applied peer entry has
    // localSha == '' and no local counter, so localSnapshot keeps it out and
    // indexDiff correctly needs it. Once we fetch it, confirmLocalObservation
    // stamps localSha and the row enters localSnapshot — indexDiff then sees
    // mineDiskSha == peer.sha256 and skips it (Bug #8: before localSnapshot
    // also admitted localSha-confirmed rows, a fetched file stayed excluded
    // forever because a pure fetch never adds our counter, so it was re-
    // fetched every reconcile — the WAL-churn / watcher loop).
    final localLive = await db.localSnapshot(deviceId);
    final peerLive = _peerLive[pair.id]?.values.toList(growable: false) ??
        const <IndexEntry>[];
    final needs = indexDiff(localLive: localLive, peerLive: peerLive);
    if (needs.isEmpty) {
      st.lastSyncedAt = DateTime.now();
      st.status = 'Idle';
      st.progress = null;
      _stateController.add(st);
      log(pair.id, 'V2 in sync (${localLive.length} files)',
          SyncEventLevel.info);
      return;
    }

    st.transferring = true;
    st.progress = 0;
    _stateController.add(st);
    _beginTransfer(); // Phase 0.4: hold a wake lock only while bytes move
    var done = 0;
    final total = needs.length;
    try {
      for (final need in needs) {
        // Skip if this direction never pulls. sendOnly = push only; receiveOnly
        // = pull only; twoWay = both. (Push happens implicitly: our advertise
        // above lets the peer compute its own need for the same file.)
        if (pair.direction == SyncDirection.sendOnly) break;
        try {
          log(pair.id, 'V2 fetching ${need.relPath}', SyncEventLevel.info);
          final sha = await fetchFileBlockLevel(
            fs: fs,
            rootPath: pair.localPath,
            relPath: need.relPath,
            expectedSize: need.peer.size,
            expectedSha: need.peer.sha256,
            blockHashes: need.peer.blockHashes,
            sendRequest: (req) =>
                _sendBlockRequest(session, pair.id, need.relPath, req),
            pipelineDepth: _syncPipelineDepth,
            onProgress: (recv, tot) {
              st.progress = total == 0 ? null : (done + recv / tot) / total;
              if (!_disposed) _stateController.add(st);
            },
          );
          // After a successful fetch the bytes on disk are guaranteed to hash to
          // `sha` (fetchFileBlockLevel verified the whole-file sha before
          // returning). Record that as a CONFIRMED on-disk observation: stamp
          // localSha so the next scanner pass sees disk == baseline and does NOT
          // mistake the just-fetched bytes for a local edit (which would bump a
          // spurious version and feed the re-advertise loop). This never bumps
          // the version — the authoritative sha already matches (the peer
          // advertised it and we just verified it).
          await db.confirmLocalObservation(relPath: need.relPath, sha: sha);
        } on TerminalFetchError catch (e) {
          // Peer's source is gone (or refused). Drop the need — DO NOT retry.
          // The file will be re-added by a future IndexUpdate if it reappears.
          log(pair.id, 'V2 drop ${need.relPath}: ${e.reason}',
              SyncEventLevel.warn);
        } catch (e) {
          // Non-terminal error (session died mid-fetch, hash mismatch, ...).
          // Log and move on; the next reconcile (reconnect / local change)
          // retries.
          log(pair.id, 'V2 fetch ${need.relPath} failed: $e',
              SyncEventLevel.error);
        } finally {
          // Release the per-file block sink regardless of outcome so a retry
          // opens a fresh one (no stale responses queued from the prior
          // attempt).
          _blockSinks.remove(_blockKey(pair.id, need.relPath))?.close();
        }
        done++;
        st.progress = total == 0 ? null : done / total;
        if (!_disposed) _stateController.add(st);
      }
    } finally {
      // Phase 0.4: release the wake lock the moment no fetch is in flight, so
      // Doze is free to take over on an idle folder.
      _endTransfer();
    }
    st.transferring = false;
    st.progress = null;
    st.lastSyncedAt = DateTime.now();
    st.status = 'Idle';
    if (!_disposed) _stateController.add(st);
    log(pair.id, 'V2 synced: $done/$total fetched', SyncEventLevel.info);
  }

  /// Reference-counted transfer tracking for the wake lock (Roadmap Phase 0.4).
  /// Each reconcile that moves bytes calls [_beginTransfer] before its loop and
  /// [_endTransfer] in a `finally`; the host callback fires only on the 0→1 and
  /// 1→0 transitions so a wake lock is held for the whole burst, not toggled
  /// per file.
  void _beginTransfer() {
    _activeTransferCount += 1;
    if (_activeTransferCount == 1) {
      onTransferState?.call(true);
    }
  }

  void _endTransfer() {
    if (_activeTransferCount == 0) return;
    _activeTransferCount -= 1;
    if (_activeTransferCount == 0) {
      onTransferState?.call(false);
    }
  }

  /// Hourly DB backup sweep (Roadmap Phase 0.5). Backs up every open Index DB
  /// to `<path>.bak`. Idempotent and best-effort — a failure skips that DB and
  /// logs, never interrupting sync.
  Future<void> backupAllDbs() async {
    for (final db in _indexDbs.values.toList(growable: false)) {
      try {
        await db.backup();
      } catch (_) {
        // backup() already logged; swallow to keep the sweep going.
      }
    }
  }

  /// Start the hourly DB backup timer (Roadmap Phase 0.5). Called once after
  /// the engine is wired. Safe to call repeatedly — it replaces the timer.
  void startBackupTimer() {
    _backupTimer?.cancel();
    _backupTimer = Timer.periodic(const Duration(hours: 1), (_) {
      if (_disposed) return;
      backupAllDbs();
    });
  }

  /// Send one block `request` and await the matching `response`. Routes through
  /// the per-file [_BlockSink]: the `Msg.response` handler pushes into it, this
  /// pulls the next reply out. Returns null when the sink is closed (session
  /// lost / cancelled) so [fetchFileBlockLevel] throws StateError cleanly.
  Future<Map<String, dynamic>?> _sendBlockRequest(
    PeerSession session,
    String pairId,
    String name,
    Map<String, dynamic> req,
  ) async {
    final key = _blockKey(pairId, name);
    final sink = _blockSinks.putIfAbsent(key, () => _BlockSink());
    final frame = <String, dynamic>{
      ...req,
      't': Msg.request,
      'pairId': pairId,
      'folderId': pairId,
      'name': name,
    };
    session.send(frame);
    return sink.next();
  }

  String _peerKey(String peerId, String pairId) => '$peerId|$pairId';
  String _blockKey(String pairId, String name) => '$pairId|$name';

  /// Route an inbound `Msg.request` (a block fetch) into the serve loop for
  /// this (pair, file). The FIRST request for a file opens a fresh
  /// [StreamController] and spawns a [serveFileBlockLevel] that drains it;
  /// subsequent requests for the SAME file land in the same controller so the
  /// serve loop responds in request order (block_transfer.dart reads the file
  /// once and serves every block from the cache). Keying per-file (not per
  /// pair) keeps two concurrent fetches of different files from interleaving
  /// on one stream.
  ///
  /// The serve loop ends when the controller is closed ([stopPair] /
  /// [onPeerSessionLost] / session loss). Its `whenComplete` self-unregisters
  /// the entry, so no idle reaper is needed — the stream's natural end is the
  /// lifecycle bound.
  Future<void> _routeServeRequest(
    PeerSession session,
    FolderPair pair,
    Map<String, dynamic> req,
  ) async {
    if (_disposed) return;
    final name = req['name'] as String?;
    if (name == null) return;
    final key = _blockKey(pair.id, name);
    var ctrl = _serveStreams[key];
    if (ctrl == null || ctrl.isClosed) {
      ctrl = StreamController<Map<String, dynamic>>();
      _serveStreams[key] = ctrl;
      // Spawn the serve loop. It owns the file cache for this fetch and
      // responds to each request. `respond` echoes the V2 envelope fields the
      // peer's _BlockSink correlates on (pairId/folderId/name) so a response
      // is self-describing on the wire.
      unawaited(
        serveFileBlockLevel(
          fs: fs,
          rootPath: pair.localPath,
          relPath: name,
          requests: ctrl.stream,
          respond: (resp) {
            session.send({
              ...resp,
              't': Msg.response,
              'pairId': pair.id,
              'folderId': pair.id,
              'name': name,
            });
          },
        ).whenComplete(() {
          // Self-unregister on completion (normal end / error / stream close).
          final c = _serveStreams.remove(key);
          c?.close();
        }),
      );
    }
    ctrl.add(req);
  }

  // ---- Folder-pair contract (invite/accept) -----------------------------

  /// Send a folder-pair invite to the connected peer. The peer will surface
  /// an accept/decline dialog; on accept, both sides persist a FolderPair
  /// with this SAME pairId and reconciliation can begin.
  ///
  /// Call this AFTER [addFolderPair] has persisted the pair locally — we send
  /// the pair's id/name/direction so the peer can join it.
  void sendFolderInvite(FolderPair pair) {
    final peerId = pair.peerDeviceId;
    if (peerId == null) {
      log(pair.id, 'Cannot invite: pair has no peerDeviceId',
          SyncEventLevel.warn);
      return;
    }
    final session = registry.openSessionFor(peerId);
    if (session == null || !session.isLinkReady) {
      log(pair.id, 'Cannot invite: peer $peerId not connected',
          SyncEventLevel.warn);
      return;
    }
    session.send({
      't': Msg.folderInvite,
      'pairId': pair.id,
      'name': pair.name,
      'direction': pair.direction.name,
    });
    _setStatus(pair.id, 'Invite sent, waiting for peer');
    log(pair.id, 'Sent folder invite "${pair.name}" to ${session.peer.name}',
        SyncEventLevel.info);
  }

  /// Locally accept a folder-pair invite that the UI surfaced via
  /// [onFolderInvite]. [localPath] is the folder the user picked on this
  /// device. Persists the pair (with the SHARED pairId from the invite) and
  /// notifies the peer via folderAccept so it can start reconciling.
  ///
  /// Direction is INVERTED from the initiator's point of view: if A picks
  /// "Send only" (push to B), then B must be "Receive only" (pull from A).
  /// Two-way stays two-way. Without this inversion, one-way sync was
  /// structurally impossible — both sides ended up with the same direction
  /// and neither side ever fetched.
  Future<void> acceptFolderInvite(
      FolderPairInvite invite, String localPath) async {
    _pendingInvites.remove(invite.pairId);
    final pair = FolderPair(
      id: invite.pairId, // SAME id as the initiator — this is the whole point
      name: invite.name,
      localPath: localPath,
      direction: _invertDirection(invite.direction),
      peerDeviceId: invite.peerDeviceId,
    );
    await config.upsertPair(pair);
    _peerAcceptedPairs.add(invite.pairId);
    await startPair(pair);
    // Tell the initiator we've joined, so it stops gating and reconciles.
    final session = registry.openSessionFor(invite.peerDeviceId);
    if (session != null && session.isLinkReady) {
      session.send({
        't': Msg.folderAccept,
        'pairId': invite.pairId,
      });
    }
    log(invite.pairId, 'Accepted folder invite "${invite.name}"',
        SyncEventLevel.info);
    // Kick off a reconcile WITH the session so the first exchange happens now
    // (startPair above only reconciles with session=null, which just persists
    // the local manifest; without this, the first sync waits for the next
    // local change or discovery beacon).
    if (session != null && session.isLinkReady) {
      await reconcile(pair, session);
    }
  }

  /// Flip a direction so the accepting peer plays the opposite role.
  ///   twoWay      -> twoWay      (symmetric)
  ///   sendOnly    -> receiveOnly (A pushes, B pulls)
  ///   receiveOnly -> sendOnly    (A pulls, B pushes)
  SyncDirection _invertDirection(SyncDirection d) => switch (d) {
        SyncDirection.twoWay => SyncDirection.twoWay,
        SyncDirection.sendOnly => SyncDirection.receiveOnly,
        SyncDirection.receiveOnly => SyncDirection.sendOnly,
      };

  /// Decline a pending invite (UI "Cancel" button). Just drops it locally.
  void declineFolderInvite(String pairId) {
    _pendingInvites.remove(pairId);
  }

  /// Forget a peer-accepted pair (used when the user disconnects a device or
  /// removes a pair) so reconciliation stops trying it.
  void forgetPeerAccepted(String pairId) {
    _peerAcceptedPairs.remove(pairId);
  }

  // ---- Incoming peer messages --------------------------------------------

  /// Safe pair lookup: returns null if no local pair matches (instead of the
  /// old `firstWhere(orElse: first)` which silently misrouted fetch/delete
  /// operations to an arbitrary folder when pairIds didn't match).
  FolderPair? _pairById(String pairId) {
    for (final p in config.folderPairs) {
      if (p.id == pairId) return p;
    }
    return null;
  }

  Future<void> _handlePeerMessage(
      PeerSession session, Map<String, dynamic> msg) async {
    final type = msg['t'] as String?;
    // Generation guard: if this session has been superseded in the registry
    // (a newer session is now live for this peer), ignore the frame — UNLESS
    // it's a keyed request/reply pair that always lands on the exact session
    // that issued the request (direct TCP reply on that socket).
    final peerId = session.peer.deviceId;
    final curGen = registry.generationOf(peerId);
    final bypassesGenGuard = type == Msg.response ||
        type == Msg.index ||
        type == Msg.indexUpdate ||
        type == Msg.indexRequest ||
        type == Msg.request;
    if (!bypassesGenGuard && curGen != null && curGen != session.generation) {
      Diag.session('gen_mismatch',
          peer: peerId,
          session: session.generation,
          fields: {'currentGen': curGen, 't': type});
      return;
    }
    // ANY incoming message is proof of life — reset the heartbeat miss count.
    // This means a peer actively syncing never gets dropped; only a truly
    // silent peer (no traffic for ~72s) triggers the dead path.
    session.restartHeartbeat();
    // Idempotency guard: drop a message we've already processed. Heartbeat
    // control messages (ping/pong) are excluded — they're cheap, idempotent
    // in effect (a re-delivered ping just yields another pong), and deduping
    // them would add noise without value. Everything else carries real side
    // effects and must not be applied twice.
    if (type != Msg.ping && type != Msg.pong) {
      final msgId = msg['msgId'] as String?;
      if (msgId != null && _recent.saw(msgId)) {
        Diag.log('dup_drop',
            peer: peerId,
            session: session.generation,
            msgId: msgId,
            msgType: type);
        return;
      }
    }
    switch (type) {
      case Msg.ready:
        final readyDeviceId = msg['deviceId'] as String?;
        if (readyDeviceId != null && readyDeviceId != peerId) {
          Diag.session('link_ready_wrong_peer',
              peer: peerId,
              session: session.generation,
              fields: {'deviceId': readyDeviceId});
          break;
        }
        final isAck = msg['ack'] == true;
        if (!isAck) {
          // Responder path: peer sent {ready, ack:false}. Send the ack back.
          //
          // IMPORTANT: do NOT break here. Fall through to markLinkReady below.
          //
          // Root-cause fix for the "peer shows offline" bug:
          // Both sides call _onSessionReady and BOTH immediately send
          // {ready, ack:false}. On the TCP level the responder's {ready} frame
          // is sent in the same write as welcome, so both frames arrive in one
          // _onData() batch on the initiator. FrameCodec._drain() processes
          // welcome first (completing waitForMessage), restores onMessage=null,
          // then processes the {ready} frame in the same synchronous loop —
          // with onMessage null it is silently dropped. The responder therefore
          // never receives its own ack, markLinkReady() is never called, and
          // the 10-second link-ready timer fires, sends bye, and tears the
          // connection down.
          //
          // Fix: the responder marks link-ready upon receiving the initiator's
          // {ready, ack:false} (proving mutual reachability) rather than waiting
          // for an ack to its own {ready} that may have been dropped.
          // markLinkReady() is idempotent, so if the ack does arrive later it
          // is a harmless no-op.
          try {
            session.send({'t': Msg.ready, 'deviceId': deviceId, 'ack': true});
          } catch (e) {
            Diag.session('link_ready_ack_send_failed',
                peer: peerId,
                session: session.generation,
                fields: {'error': e.toString()});
          }
          // Fall through to markLinkReady.
        }
        // Both ack:false (responder) and ack:true (initiator) paths land here.
        if (session.markLinkReady()) {
          _onPeerLinkReady(session);
        }
        break;
      case Msg.pong:
        // The peer answered our heartbeat probe. Correlate by id if present
        // (records RTT); a bare pong from an older peer just clears the slot.
        session.handlePong(msg['hb'] as String?);
        break;
      case Msg.bye:
        // The peer is disconnecting intentionally (user tapped Disconnect /
        // Quit, or is shutting down). Handle it PROMPTLY rather than waiting
        // for TCP's FIN or the ~72s heartbeat timeout, so this side's
        // connected-state flips to "disconnected" in lockstep with the peer's
        // — this is the symmetric-disconnect half of the connection-state
        // mismatch fix. Closing our socket here fires socket.done, which runs
        // AppState._onSessionReady's identity-guarded teardown (registry.drop,
        // onPeerSessionLost, onPeerDisconnected, supervisor reconnect). So we
        // reuse the EXISTING, proven teardown path and add no new state.
        //
        // The generation guard at the top of this method already bails if this
        // session was superseded, so a stray bye from an OLD socket can't tear
        // down a newer one. Engine-safe: this touches none of the V2
        // invariants — it is a connection-lifecycle concern only.
        log('', 'Peer ${session.peer.deviceId} sent bye — disconnecting',
            SyncEventLevel.info);
        Diag.session('bye_recv', peer: peerId, session: session.generation);
        await session.close();
        break;
      case Msg.ping:
        // Ping serves two purposes: (a) the peer's heartbeat probe — answer
        // with pong so it doesn't drop us; (b) a reconcile nudge when the
        // peer has a file to push (the push step sends ping for that). Both
        // are handled here.
        session.send({'t': Msg.pong});
        final pairId = msg['pairId'] as String?;
        if (pairId != null) {
          final pair = _pairById(pairId);
          if (pair == null) {
            session.send({'t': Msg.error, 'message': 'no such pair: $pairId'});
            break;
          }
          await reconcile(pair, session);
        }
        break;
      case Msg.folderInvite:
        // Peer is offering to sync a folder with us. Surface to the UI so the
        // user can pick a local folder and accept — we never auto-accept.
        final pairId = msg['pairId'] as String;
        final name = msg['name'] as String;
        final direction =
            SyncDirection.values.byName(msg['direction'] as String);
        if (_pairById(pairId) != null) {
          // Already have this pair (e.g. re-invite after a reconnect) — just
          // mark it peer-accepted and reconcile, no UI prompt needed.
          _peerAcceptedPairs.add(pairId);
          final pair = _pairById(pairId)!;
          reconcile(pair, session);
          break;
        }
        if (_pendingInvites.containsKey(pairId)) break; // already shown
        final invite = FolderPairInvite(
          pairId: pairId,
          name: name,
          direction: direction,
          peerDeviceId: session.peer.deviceId,
          peerName: session.peer.name,
        );
        _pendingInvites[pairId] = invite;
        log(pairId, 'Folder invite from ${session.peer.name}: "$name"',
            SyncEventLevel.info);
        onFolderInvite?.call(invite);
        break;
      case Msg.folderAccept:
        // Peer accepted one of our invites — ungate reconciliation for it.
        final pairId = msg['pairId'] as String;
        _peerAcceptedPairs.add(pairId);
        _setStatus(pairId, 'Peer accepted');
        log(pairId, 'Peer accepted folder invite', SyncEventLevel.info);
        final pair = _pairById(pairId);
        if (pair != null) {
          reconcile(pair, session);
        }
        break;
      case Msg.error:
        log('', 'Peer error: ${msg['message']}', SyncEventLevel.warn);
        break;
      // ---- Index sync message handlers (REDESIGN.md Phase 2) ---------------
      //
      // Each lands on the exact session that issued the request (direct TCP
      // reply) and is exempt from the generation guard at the top of this method.
      case Msg.index:
      case Msg.indexUpdate:
        // Peer advertised (full Index or delta Update) its rows for this pair.
        // Apply each into our Index DB (applyRemote drops stale/dup by
        // sequence), merge the live ones into _peerLive, and advance our
        // peer-watermark so the next indexRequest we send is honest.
        await _handleIndexFrame(session, msg);
        break;
      case Msg.indexRequest:
        // Peer wants everything past its watermark. Reply with the delta from
        // our Index DB and advance our sent-watermark for this peer so we
        // don't re-send it. (This is the symmetric half of _advertiseDelta.)
        await _handleIndexRequest(session, msg);
        break;
      case Msg.request:
        // Peer requests one block of a file we have. Feed it to the per-file
        // serve loop (spawns one on first request, responds in order).
        final pairId = msg['pairId'] as String?;
        final pair = pairId == null ? null : _pairById(pairId);
        if (pair == null) {
          // Unknown pair — terminal-error so the peer drops the need instead
          // of retrying a fetch against a pair we no longer know about.
          session.send({
            't': Msg.response,
            'pairId': pairId,
            'folderId': pairId,
            'name': msg['name'],
            'error': 'no such pair: $pairId',
          });
          break;
        }
        await _routeServeRequest(session, pair, msg);
        break;
      case Msg.response:
        // A block reply to OUR _sendBlockRequest. Route to the per-file
        // _BlockSink the fetcher is pulling from. No sink = the fetch already
        // ended (terminal error / completion / cancel) → drop the late reply.
        final respPairId = msg['pairId'] as String?;
        final respName = msg['name'] as String?;
        if (respPairId != null && respName != null) {
          final sink = _blockSinks[_blockKey(respPairId, respName)];
          if (sink != null && !sink.isClosed) {
            sink.add(msg);
          }
        }
        break;
      // ---- Clipboard sync (Roadmap Phase 2) --------------------------------
      //
      // Appended last and deliberately segregated from the V2 cases: this only
      // hands the text to the host callback, never touches the Index DB / the
      // needs-queue / any version vector. A clipboardPush carries no msgId, so
      // it bypasses the dedup guard (re-applying the current clipboard is a
      // harmless no-op). Subject to the generation guard at the top of this
      // method, so a late push from a superseded session is dropped — the fresh
      // session carries the peer's current clipboard anyway.
      case Msg.clipboardPush:
        final text = msg['text'] as String? ?? '';
        onClipboardPush?.call(session.peer.deviceId, text);
        break;
      // ---- Remote command (Roadmap Phase 4) --------------------------------
      //
      // Appended last; entirely segregated from sync, clipboard, and ad-hoc
      // cases. The command name is forwarded to the host; all allowlist
      // enforcement happens there so the engine stays dependency-free.
      case Msg.runCommand:
        final name = msg['name'] as String? ?? '';
        if (name.isNotEmpty) onRunCommand?.call(session.peer.deviceId, name);
        break;
      // ---- Ad-hoc file send (Roadmap Phase 3a) -----------------------------
      //
      // Appended last, fully segregated from sync and clipboard cases. These
      // three cases route to AdHocFileSend which owns all ad-hoc transfer
      // state (separate sink maps keyed by offerId). The Index DB / indexDiff /
      // the needs-queue are NEVER consulted. Subject to the generation guard so
      // stale frames from a superseded session are dropped.
      case Msg.fileOffer:
        adHocSend?.handleFileOffer(session, msg);
        break;
      case Msg.fileOfferBlock:
        adHocSend?.handleFileOfferBlock(session, msg);
        break;
      case Msg.fileOfferData:
        adHocSend?.handleFileOfferData(session, msg);
        break;
      case Msg.fileOfferControl:
        adHocSend?.handleFileOfferControl(session, msg);
        break;
    }
  }

  /// Apply an inbound `index` / `indexUpdate` frame (same shape — `index` is
  /// the full first advertisement, `index_update` is a delta; we treat them
  /// identically since [IndexDb.applyRemote] is idempotent and sequence-gated).
  ///
  /// Steps:
  ///   1. Parse each entry, applyRemote it into our Index DB.
  ///   2. Merge live entries into `_peerLive[pairId]` (the flat map the diff
  ///      reads). Tombstones are removed from the live map (resurrection /
  ///      delete propagation is Phase 4; for Phase 2 a tombstone just means
  ///      "peer no longer offers this" so we drop it from the needs source).
  ///   3. Advance `_peerSeq` to the max sequence seen (so our next
  ///      indexRequest's fromSequence is honest, and so the loop below can
  ///      detect "did we actually learn anything new?").
  ///   4. If we DID learn something new, kick a reconcile — that's where needs
  ///      get computed and fetches run. We only kick on a real advance to
  ///      avoid an infinite advertise↔kick ping-pong (both peers otherwise
  ///      re-advertise empty deltas forever in response to each other's kicks).
  Future<void> _handleIndexFrame(
    PeerSession session,
    Map<String, dynamic> msg,
  ) async {
    final pairId = msg['pairId'] as String?;
    if (pairId == null) return;
    final pair = _pairById(pairId);
    if (pair == null) return; // unknown pair — nothing to apply
    final entriesRaw = msg['entries'];
    if (entriesRaw is! List) return;
    final peerKey = _peerKey(session.peer.deviceId, pairId);
    final priorSeq = _peerSeq[peerKey] ?? 0;
    var maxSeq = priorSeq;
    final wasLiveEmpty = !_peerLive.containsKey(pairId);
    final live = _peerLive.putIfAbsent(pairId, () => <String, IndexEntry>{});
    var learned = 0;
    for (final raw in entriesRaw) {
      if (raw is! Map) continue;
      final entry = IndexEntry.fromJson(raw.cast<String, dynamic>());
      // DELETE-TO-DISK (Bug #6, REDESIGN.md Phase 4): the peer tombstoned this
      // file. Phase 2 only DROPPED the tombstone from the live map (so the diff
      // stopped offering it as a need) and never removed the bytes from disk —
      // so deletes on side A stayed forever on side B's disk. We now decide
      // delete-vs-edit at receive time, BEFORE applyRemote merges the peer's
      // delete-counter into our row (after the merge the dominance test would
      // no longer be clean). See [_applyRemoteTombstone] for the full rule.
      if (entry.deleted) {
        final decision = await _applyRemoteTombstone(pairId, entry);
        if (decision == DeleteDecision.editWins) {
          // Concurrent local edit won: do NOT store deleted=1 (a later sweep
          // would then delete our edit). The counter was already merged into our
          // LIVE row by _applyRemoteTombstone; just drop the tombstone from the
          // live map and advance the watermark. The peer resurrects on its next
          // reconcile.
          live.remove(entry.relPath);
          if (entry.sequence > maxSeq) maxSeq = entry.sequence;
          learned++;
          continue;
        }
        // deleteWins OR nothingToDecide: store the tombstone via applyRemote.
      }
      await _indexDbs[pairId]?.applyRemote(entry);
      if (entry.sequence > maxSeq) maxSeq = entry.sequence;
      if (entry.deleted) {
        // Peer's tombstone: drop from the live map so the diff stops offering
        // it as a need (and so a later resurrection fetch is re-added cleanly).
        live.remove(entry.relPath);
      } else {
        live[entry.relPath] = entry;
      }
      learned++;
    }
    _peerSeq[peerKey] = maxSeq;
    Diag.log('v2_index_recv',
        peer: session.peer.deviceId,
        pairId: pairId,
        fields: {
          'entries': learned,
          'fromSeq': msg['fromSequence'],
          'toSeq': maxSeq,
          'first': entriesRaw.isEmpty,
        });
    if (maxSeq > priorSeq || wasLiveEmpty) {
      await reconcile(pair, session);
    }
  }

  /// Answer an `indexRequest` from the peer: send every local row past the
  /// peer's watermark as an `indexUpdate`, and advance our sent-watermark for
  /// this peer. Symmetric to [_advertiseDelta] but driven by an inbound pull
  /// rather than our outbound push. Empty deltas are still sent so the peer
  /// learns we're alive and can correlate (its handler no-ops on an empty
  /// delta because `maxSeq` doesn't advance past `priorSeq`).
  Future<void> _handleIndexRequest(
    PeerSession session,
    Map<String, dynamic> msg,
  ) async {
    final pairId = msg['pairId'] as String?;
    if (pairId == null) return;
    final pair = _pairById(pairId);
    if (pair == null) return;
    final fromSeq = (msg['fromSequence'] as num?)?.toInt() ?? 0;
    final db = await _indexDbFor(pair);
    // Only send rows WE wrote — the peer already has its own.
    final delta = await db.changesSinceLocal(fromSeq, deviceId);
    final maxSeq = delta.isEmpty ? await db.maxSequence() : delta.last.sequence;
    session.send({
      't': Msg.indexUpdate,
      'pairId': pairId,
      'folderId': pairId,
      'entries': delta.map((e) => e.toJson()).toList(),
      'fromSequence': fromSeq,
    });
    final peerKey = _peerKey(session.peer.deviceId, pairId);
    _sentSeq[peerKey] = maxSeq;
    Diag.log('v2_index_reply',
        peer: session.peer.deviceId,
        pairId: pairId,
        fields: {'sent': delta.length, 'fromSeq': fromSeq, 'toSeq': maxSeq});
  }

  // ---- Delete propagation to disk (Bug #6 / REDESIGN.md Phase 4) ----------
  //
  // Two cooperating mechanisms remove a peer-tombstoned file from THIS device's
  // disk, with version-vector dominance deciding delete-vs-edit:
  //
  //   1. [_applyRemoteTombstone] runs at RECEIVE time, the instant a tombstone
  //      arrives in an index/indexUpdate. It compares the tombstone's version
  //      against our PRIOR live row (before applyRemote merges the delete's
  //      counter into it) and either deletes the disk file (delete wins) or
  //      leaves it (concurrent edit wins). This is the latency-optimal path.
  //
  //   2. [_propagateRemoteDeletes] runs at RECONCILE time (in _reconcileV2,
  //      right after the scan): for any tombstone row whose file is STILL on
  //      disk, remove it. This (a) cleans up the pre-fix backlog of orphan
  //      files the user already has, and (b) is the retry if a receive-time
  //      fs.delete threw or the file was re-created out of band. It is
  //      idempotent — fs.stat returns null once the file is gone.
  //
  // Together they guarantee: a file the peer deleted is removed from our disk,
  // UNLESS we concurrently edited it (in which case our edit resurrects it and
  // the peer's next reconcile fetches it back — the symmetric half of the same
  // dominance rule). Device-agnostic: no Platform. branches, so phone→PC and
  // PC→phone delete-to-disk work identically.

  /// Decide delete-vs-edit for one inbound tombstone [entry] and act on it.
  /// Called from [_handleIndexFrame] BEFORE the generic [IndexDb.applyRemote],
  /// while our row still holds the clean pre-delete version (after the merge
  /// our row's vector would absorb the delete's counter and the dominance test
  /// would no longer be a clean comparison).
  ///
  /// Returns the [DeleteDecision] so the caller knows how to record the row:
  ///   - [DeleteDecision.deleteWins]: delete is authoritative; bytes removed
  ///     from disk; caller should `applyRemote` the tombstone (store deleted=1).
  ///   - [DeleteDecision.editWins]: we concurrently edited; bytes KEPT; caller
  ///     must NOT store deleted=1 (it would make a later sweep delete our edit).
  ///     The caller instead merges the peer's counter into our LIVE row.
  ///   - [DeleteDecision.nothingToDecide]: no live prior row (nothing on disk);
  ///     caller stores the tombstone as-is.
  Future<DeleteDecision> _applyRemoteTombstone(
      String pairId, IndexEntry entry) async {
    final pair = _pairById(pairId);
    if (pair == null) return DeleteDecision.nothingToDecide;
    final db = _indexDbs[pairId];
    if (db == null) return DeleteDecision.nothingToDecide;

    final prior = await db.get(entry.relPath);
    // No prior row, or a prior that's itself already a tombstone: nothing on
    // disk to delete (a prior tombstone means disk was already cleared on an
    // earlier pass). Caller stores the tombstone as-is.
    if (prior == null || prior.deleted) {
      return DeleteDecision.nothingToDecide;
    }

    // Concurrent-edit guard: if our prior LIVE version has a counter the
    // tombstone doesn't know about, we edited the file at the same time the
    // peer deleted it. Our edit WINS — the delete must NOT remove our bytes,
    // and (critically) we must NOT record the row as deleted, or the
    // reconcile-time sweep would later remove our edit. The caller merges the
    // peer's delete-counter into our LIVE row so future dominance comparisons
    // are accurate, then drops the tombstone. The peer learns of our edit on
    // its next reconcile and resurrects the file.
    //
    // We use concurrentWith (neither dominates) rather than `prior dominates
    // entry`: a tombstone always carries the deleter's bumped counter, so a
    // same-second edit on our side yields genuinely-concurrent vectors (each
    // side has a counter the other lacks), which is exactly the conflict case
    // the VV design defers to the editing side for a delete-vs-edit tie.
    if (prior.version.concurrentWith(entry.version)) {
      await db.resolveEditWinsDelete(
          relPath: entry.relPath, remoteVersion: entry.version);
      Diag.log('delete_concurrent_edit_kept',
          pairId: pairId,
          fields: {'path': entry.relPath, 'prior': '${prior.version}'});
      log(
          pairId,
          'Kept ${entry.relPath} (concurrent local edit wins over peer delete)',
          SyncEventLevel.info);
      return DeleteDecision.editWins;
    }

    // Delete is authoritative (its version dominates-or-equals ours). Remove
    // the bytes from disk. fs.delete is a no-op if the file is already gone,
    // so this is safe to repeat. A failure is non-fatal: the reconcile-time
    // sweep [_propagateRemoteDeletes] retries every pass.
    try {
      await fs.delete(pair.localPath, entry.relPath);
      Diag.log('delete_to_disk',
          peer: '', pairId: pairId, fields: {'path': entry.relPath});
      log(pairId, 'Removed ${entry.relPath} (peer deleted it)',
          SyncEventLevel.info);
    } catch (e) {
      log(pairId, 'Delete-to-disk failed for ${entry.relPath}: $e',
          SyncEventLevel.warn);
    }
    return DeleteDecision.deleteWins;
  }

  /// Reconcile-time sweep: remove from disk any file whose DB row is a
  /// tombstone but whose bytes are still present. This is the backlog cleaner
  /// (orphans left by the pre-fix Phase 2 path) AND the retry path for a
  /// receive-time delete that failed. Idempotent — once a file is gone, the
  /// next fs.stat returns null and the row is skipped.
  ///
  /// Safe by construction: a row is only `deleted=1` if the delete already won
  /// its version-vector duel (the concurrent-edit case never stored a
  /// tombstone — see [_applyRemoteTombstone]), so every tombstone here is an
  /// authoritative delete whose bytes we are contractually allowed to remove.
  Future<void> _propagateRemoteDeletes(FolderPair pair) async {
    final db = _indexDbs[pair.id];
    if (db == null) return;
    final tombstones = await db.tombstones();
    for (final t in tombstones) {
      final stat = await fs.stat(pair.localPath, t.relPath);
      if (stat == null) continue; // already gone — nothing to do
      try {
        await fs.delete(pair.localPath, t.relPath);
        log(
            pair.id,
            'Removed orphan ${t.relPath} (tombstoned, was still on disk)',
            SyncEventLevel.info);
      } catch (e) {
        log(pair.id, 'Orphan delete failed for ${t.relPath}: $e',
            SyncEventLevel.warn);
      }
    }
  }

  // ---- Test-only accessors ------------------------------------------------
  //
  // The V2 engine tests (REDESIGN.md Phase 2 handoff §10 #3) need to assert on
  // internal V2 state — the live peer snapshot, the sequence watermarks — that
  // has no business reason to be public. These narrow, read-only getters are
  // the escape hatch: they expose exactly what the assertions need and nothing
  // mutable. All are `@visibleForTesting`; production code never calls them.
  @visibleForTesting
  Map<String, IndexEntry>? peerLiveFor(String pairId) => _peerLive[pairId];

  @visibleForTesting
  int? peerSeqFor(String key) => _peerSeq[key];

  @visibleForTesting
  int? sentSeqFor(String key) => _sentSeq[key];

  /// Open a fresh, independent read handle to the Index DB for [pair]. The
  /// engine keeps its own handle open; SQLite (WAL) allows concurrent readers,
  /// so this is safe and lets tests query rows the engine wrote without
  /// reaching into private fields.
  @visibleForTesting
  Future<IndexDb> openIndexDbFor(FolderPair pair) =>
      IndexDb.open(pair.id, stateDir);

  /// Test-only message entry: invoke the engine's inbound handler as if a frame
  /// arrived from [session]. Exposed so tests can inject hand-built frames
  /// (e.g. a simulated peer indexUpdate) without a full two-engine loopback
  /// when a test only cares about ONE side's reaction.
  @visibleForTesting
  Future<void> handlePeerMessageForTest(
          PeerSession session, Map<String, dynamic> msg) =>
      _handlePeerMessage(session, msg);
}

/// A bounded queue of incoming `Msg.response` frames for one in-flight
/// block-level fetch. The engine's `Msg.response` handler pushes;
/// [SyncEngine._sendBlockRequest] pulls via [next]. Closing marks the fetch
/// done so any late stray responses are dropped instead of buffered forever
/// (used by [SyncEngine.onPeerSessionLost] and the fetch's finally block).
class _BlockSink {
  final _queue = <Map<String, dynamic>>[];
  bool _closed = false;
  final _waiters = <Completer<Map<String, dynamic>?>>[];
  DateTime _lastActivity = DateTime.now();

  bool get isClosed => _closed;

  /// Push one response. If a fetcher is already awaiting via [next], it is
  /// woken and handed the response; otherwise the response buffers until the
  /// next [next] call.
  void add(Map<String, dynamic> resp) {
    if (_closed) return;
    _lastActivity = DateTime.now();
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(resp);
    } else {
      _queue.add(resp);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    // Wake any stranded awaiters with null so they unwind instead of hanging.
    for (final w in _waiters) {
      w.complete(null);
    }
    _waiters.clear();
  }

  /// Await the next response, or null if the sink is closed (session lost /
  /// cancelled) before one arrives. A closed sink with buffered responses
  /// still drains them — close only stops NEW responses, it doesn't discard
  /// already-received ones (the file may be one block from complete).
  Future<Map<String, dynamic>?> next() async {
    if (_queue.isNotEmpty) {
      return _queue.removeAt(0);
    }
    if (_closed) return null;
    final c = Completer<Map<String, dynamic>?>();
    _waiters.add(c);
    // Stall backstop: if nothing arrives for this long, self-close so the
    // fetcher unwinds. onPeerSessionLost usually closes us first; this is the
    // backstop for any failure mode that doesn't.
    Future.delayed(const Duration(seconds: 45), () {
      if (!c.isCompleted) {
        _waiters.remove(c);
        c.complete(null);
      }
    });
    return c.future;
  }
}

/// A bounded, TTL-evicting set of recently-seen message ids, for idempotent
/// message handling (Priority 5 of the hardening plan).
///
/// Two eviction mechanisms, both cheap:
///   - Hard cap ([maxEntries]): when full, the oldest entry is evicted on
///     insert (LinkedHashMap preserves insertion order, so "oldest" = first).
///   - TTL sweep ([ttl]): entries older than the TTL are evicted
///     opportunistically on each [saw] call — we check the front of the map
///     and drop it if stale, repeating a bounded number of times. This avoids
///     a dedicated sweep timer while still keeping the map from holding
///     long-dead ids forever.
///
/// Both bounds are deliberately generous: the cost of an extra id in memory
/// is trivial, the cost of a false-positive dedup (dropping a genuinely new
/// message) is a silent sync stall.
class RecentMsgIds {
  static const int maxEntries = 4096;
  // Default TTL for production callers. Injectable via the constructor so the
  // TTL-sweep path is testable without real-time waits.
  static const Duration defaultTtl = Duration(seconds: 60);

  final Duration ttl;
  final _seen = <String, DateTime>{};

  RecentMsgIds({this.ttl = defaultTtl});

  /// Returns true if [msgId] was already recorded (i.e. this is a duplicate),
  /// false if it's new (and now recorded). A null [msgId] is never a dup —
  /// callers use that path for messages that predate msgId stamping.
  bool saw(String msgId) {
    final now = DateTime.now();
    // Opportunistic TTL sweep from the front — LinkedHashMap is insertion-
    // ordered, so stale entries cluster at the head. Bound the work so a
    // pathological burst can't make one [saw] call expensive.
    //
    // CRITICAL: collect the stale keys out-of-band and remove them ONLY after
    // the iterator has closed. Mutating `_seen` (via remove) while iterating
    // it throws ConcurrentModificationError — which used to fire on every
    // inbound manifest/folder_invite/chunk as soon as any single entry aged
    // past the TTL, crashing `_handlePeerMessage` before the manifest handler
    // could complete the peer's waiter and producing a deterministic 15s
    // "manifest exchange timed out". (Regression test: recent_msg_ids_test.)
    final staleKeys = <String>[];
    var swept = 0;
    for (final entry in _seen.entries) {
      if (swept >= 64) break;
      if (now.difference(entry.value) > ttl) {
        staleKeys.add(entry.key);
        swept++;
      } else {
        break; // oldest remaining is still fresh → so are all later ones
      }
    }
    for (final key in staleKeys) {
      _seen.remove(key);
    }
    if (_seen.containsKey(msgId)) return true;
    if (_seen.length >= maxEntries) {
      _seen.remove(_seen.keys.first);
    }
    _seen[msgId] = now;
    return false;
  }
}
