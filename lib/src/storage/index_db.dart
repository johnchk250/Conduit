import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart' as sqf;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../storage/db_factory.dart';
import '../sync/version_vector.dart';

/// One row in the per-folder Index DB — the durable record of a file's state
/// (REDESIGN.md §(1)).
///
/// This is the new-engine analogue of the legacy [FileEntry] in
/// `manifest.dart`, but richer: it carries the [versionVector] and monotonic
/// [sequence] that drive ordering and transport-driven delta exchange, plus a
/// [deleted] flag (a delete is just an entry with `deleted: true` and a bumped
/// version, never a row removal — see Phase 4).
///
/// [blockHashes] is optional in Phase 1 — populated in Phase 3 when
/// block-level transfer lands. Stored as a JSON array of hex SHA-256 strings;
/// NULL or empty means "not yet computed".
class IndexEntry {
  final String relPath;
  final int size;
  final int mtime; // ms since epoch
  final String sha256; // whole-file hash ('' if unhashed)
  final VersionVector version;
  final int sequence; // monotonic per-folder counter (this device's view)
  final bool deleted;
  final List<String> blockHashes; // empty when not computed
  /// The sha of the bytes THIS device last confirmed on its own disk, '' until
  /// observed. DB-LOCAL ONLY — never serialized on the wire (it is meaningless
  /// to a peer). It is the scanner's baseline for distinguishing a GENUINE local
  /// edit (disk sha changed since our last observation → bump) from STALE disk
  /// (a peer's newer row landed in the DB but our disk hasn't fetched it yet →
  /// do NOT bump, or we'd stamp stale bytes as authorship and revert the peer's
  /// edit).
  final String localSha;
  final int localSize;
  final int localMtime;

  IndexEntry({
    required this.relPath,
    required this.size,
    required this.mtime,
    required this.sha256,
    required this.version,
    required this.sequence,
    this.deleted = false,
    this.blockHashes = const <String>[],
    this.localSha = '',
    this.localSize = 0,
    this.localMtime = 0,
  });

  /// Copy with an updated [localSha] (preserving everything else). Used by the
  /// scanner/post-fetch path to record what we just observed on disk.
  IndexEntry withLocalSha(String sha) => IndexEntry(
        relPath: relPath,
        size: size,
        mtime: mtime,
        sha256: sha256,
        version: version,
        sequence: sequence,
        deleted: deleted,
        blockHashes: blockHashes,
        localSha: sha,
        localSize: localSize,
        localMtime: localMtime,
      );

  /// Copy with an updated [version] (preserving everything else). Used by
  /// [IndexDb.applyRemote]'s origin-counter merge path, which must be able to
  /// advance a row's version WITHOUT also rewriting its transport fields (size/
  /// mtime/sha/sequence) — see [applyRemote] for why that distinction matters.
  IndexEntry withVersion(VersionVector v) => IndexEntry(
        relPath: relPath,
        size: size,
        mtime: mtime,
        sha256: sha256,
        version: v,
        sequence: sequence,
        deleted: deleted,
        blockHashes: blockHashes,
        localSha: localSha,
        localSize: localSize,
        localMtime: localMtime,
      );

  /// True if this entry has a usable whole-file digest. The legacy
  /// [Manifest]/[FileEntry] always hashed; the Index DB can defer hashing
  /// until needed (e.g. only when the file actually differs by size/mtime
  /// from its prior row — the same fast path the scanner uses).
  bool get hasSha => sha256.isNotEmpty;

  /// Wire form for Index/IndexUpdate frames (REDESIGN.md Phase 2). Round-trips
  /// through [fromJson]. Carries the FULL state needed to reconstruct the row
  /// on the peer side: path, size, mtime, sha, version, sequence, deleted, and
  /// blockHashes (NULL-coalesced to empty on the wire to keep frames small for
  /// the common case where blocks aren't computed yet).
  ///
  /// [localSha] is INTENTIONALLY excluded — it is per-device, meaningless to a
  /// peer, and must never cross the wire.
  Map<String, dynamic> toJson() => {
        'path': relPath,
        'size': size,
        'mtime': mtime,
        'sha256': sha256,
        'version': version.toJson(),
        'sequence': sequence,
        'deleted': deleted,
        if (blockHashes.isNotEmpty) 'blocks': blockHashes,
      };

  /// Inverse of [toJson]. Defensive against missing fields — the wire format
  /// will evolve across versions, and a missing `blocks` (older peer) must
  /// degrade to "no per-block hashes" rather than throwing.
  factory IndexEntry.fromJson(Map<String, dynamic> j) {
    final blocksRaw = j['blocks'];
    final blocks = blocksRaw is List
        ? blocksRaw.map((b) => b.toString()).toList(growable: false)
        : const <String>[];
    return IndexEntry(
      relPath: j['path'] as String,
      size: (j['size'] as num).toInt(),
      mtime: (j['mtime'] as num).toInt(),
      sha256: (j['sha256'] as String?) ?? '',
      version: VersionVector.fromJson(
          (j['version'] as Map<String, dynamic>).cast<String, dynamic>()),
      sequence: (j['sequence'] as num).toInt(),
      deleted: (j['deleted'] as bool?) ?? false,
      blockHashes: blocks,
    );
  }

  @override
  String toString() =>
      'IndexEntry($relPath, ${size}B, sha=${sha256.isNotEmpty ? sha256.substring(0, 8) : "-"}, '
      'v=$version, seq=$sequence${deleted ? ", DELETED" : ""})';
}

class LocalFileObservation {
  const LocalFileObservation({
    required this.relPath,
    required this.size,
    required this.mtime,
    required this.sha256,
  });

  final String relPath;
  final int size;
  final int mtime;
  final String sha256;
}

/// Per-folder SQLite index — the durable source of truth for the new engine
/// (REDESIGN.md §(1)).
///
/// ONE database FILE per folder pair, stored under
/// `<appSupportDir>/index/<pairId>.db`. Replacing the legacy on-disk JSON
/// manifest, which was rebuilt and re-exchanged on every reconcile and could
/// not survive a reconnect. SQLite gives us atomic writes, indexed lookups by
/// path or by sequence, and a single durable file that the engine reopens on
/// reconnect — no "rebuild on every reconcile", no vanish window.
///
/// ## Schema (Phase 1)
///
/// ```sql
/// CREATE TABLE files (
///   path        TEXT PRIMARY KEY,   -- forward-slash relative path
///   size        INTEGER NOT NULL,
///   mtime       INTEGER NOT NULL,   -- ms since epoch
///   sha256      TEXT NOT NULL,      -- '' if unhashed
///   version     TEXT NOT NULL,      -- JSON form of VersionVector
///   sequence    INTEGER NOT NULL,   -- monotonic per-folder counter
///   deleted     INTEGER NOT NULL,   -- 0/1
///   block_hashes TEXT               -- NULL or JSON array of hex digests
/// );
/// CREATE INDEX seq_index ON files(sequence);
/// ```
///
/// `sequence` is monotonic ACROSS all writes to this folder (not per-file),
/// assigned by [upsertLocal] when we observe a change. IndexUpdates from a
/// peer are filtered by "give me everything with sequence > myMax" — the index
/// on `sequence` makes that lookup O(log n).
///
/// ## Concurrency
///
/// Each [IndexDb] holds a single open [Database] handle. SQLite serializes
/// writes; we wrap multi-statement mutations (e.g. a scanner pass that bumps
/// many rows) in [Database.transaction] so they apply atomically.
class IndexDb {
  IndexDb._(this._pairId, this._db, this._path);

  final String _pairId;
  final Database _db;
  final String _path;

  /// The pairId this index belongs to. Exposed for diagnostics/logging — the
  /// engine prints it when emitting Index/IndexUpdate events so a grep can
  /// tell which folder a frame belongs to.
  String get pairId => _pairId;

  /// Absolute path of the on-disk `.db` file. Exposed so a caller (Roadmap
  /// Phase 0.5) can copy an hourly `.bak` without re-deriving it. Under WAL
  /// mode the `-wal` and `-shm` sidecar files live alongside; [backup]
  /// snapshots the main file.
  String get path => _path;

  /// Open (or create) the Index DB for [pairId]. The file lives at
  /// `<stateDir>/index/<safePairId>.db`, where [safePairId] has any
  /// non-alphanumeric characters replaced with `_` so we never produce an
  /// illegal filename. Idempotent: opening an existing DB upgrades its schema
  /// via migrations and returns immediately.
  ///
  /// [DbFactory.init] is called defensively — if some code path opens an
  /// IndexDb before `main()` has installed the FFI factory, we install it
  /// here. No-op when already initialized.
  ///
  /// ## DB hardening (Roadmap Phase 0.5)
  ///
  /// Beyond WAL mode (already set in [onConfigure]), the open path now also:
  ///   - sets `PRAGMA synchronous = NORMAL` — the documented safe companion to
  ///     WAL (SQLite recommends `NORMAL` under WAL; `FULL` is needlessly slow,
  ///     and the older default could lose the WAL frame journal on a crash),
  ///   - runs `PRAGMA integrity_check` once and logs the result (a corrupt DB
  ///     is surfaced in the diagnostic stream instead of silently producing
  ///     wrong query results), and
  ///   - exposes [path] + [backup] so a caller can keep an hourly `.bak`.
  ///
  /// None of this changes ANY row or query — the schema, snapshots, and write
  /// methods are untouched. It only makes the file more crash-safe and
  /// recoverable.
  static Future<IndexDb> open(String pairId, Directory stateDir) async {
    DbFactory.init();
    final dir = Directory(p.join(stateDir.path, 'index'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final path = p.join(dir.path, '${_safeName(pairId)}.db');
    final db = await databaseFactory.openDatabase(
      path,
      options: sqf.OpenDatabaseOptions(
        version: 1,
        onCreate: _create,
        // onConfigure runs once per connection. WAL + synchronous=NORMAL are
        // the documented crash-safe pairing under WAL mode. Setting them here
        // (not onOpen) guarantees they apply before any page cache is built.
        onConfigure: (db) async {
          await db.execute('PRAGMA journal_mode = WAL');
          await db.execute('PRAGMA synchronous = NORMAL');
        },
        // onOpen runs for BOTH freshly-created and pre-existing DBs, so it's
        // the right hook to add the local_sha column to older index files
        // (see _migrate). Idempotent.
        onOpen: (db) async {
          await _migrate(db);
          await _integrityCheck(db);
        },
      ),
    );
    return IndexDb._(pairId, db, path);
  }

  /// Run `PRAGMA integrity_check` and emit the result to the diagnostic log.
  /// A healthy DB returns the single row `ok`; anything else (e.g.
  /// `database disk image is malformed`) is logged so a corrupt DB is visible
  /// instead of silently producing wrong query results. Non-fatal: we never
  /// throw here — a corrupt DB is still opened so the caller can decide to
  /// restore a backup; throwing would prevent recovery entirely.
  static Future<void> _integrityCheck(Database db) async {
    try {
      final rows = await db.rawQuery('PRAGMA integrity_check');
      final result = rows.isEmpty
          ? 'empty'
          : rows.map((r) => r.values.join(',')).join(';');
      // ignore: avoid_print
      print('[Conduit][db] integrity_check: $result');
    } catch (e) {
      // ignore: avoid_print
      print('[Conduit][db] integrity_check FAILED: $e');
    }
  }

  static String _safeName(String pairId) =>
      pairId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  static Future<void> _create(Database db, int _) async {
    await db.execute('''
      CREATE TABLE files (
        path         TEXT PRIMARY KEY,
        size         INTEGER NOT NULL,
        mtime        INTEGER NOT NULL,
        sha256       TEXT NOT NULL,
        version      TEXT NOT NULL,
        sequence     INTEGER NOT NULL,
        deleted      INTEGER NOT NULL,
        block_hashes TEXT,
        local_sha    TEXT NOT NULL DEFAULT '',
        local_size   INTEGER NOT NULL DEFAULT 0,
        local_mtime  INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('CREATE INDEX seq_index ON files(sequence)');
  }

  /// Schema migration for pre-existing DBs (the V2 redesign shipped without
  /// [local_sha]; older index files must be upgraded in place). Adds the column
  /// if missing. Idempotent — re-running on an already-migrated DB is a no-op.
  static Future<void> _migrate(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(files)');
    final hasLocalSha = cols.any((c) => (c['name'] as String?) == 'local_sha');
    if (!hasLocalSha) {
      await db.execute(
          "ALTER TABLE files ADD COLUMN local_sha TEXT NOT NULL DEFAULT ''");
    }
    if (!cols.any((c) => (c['name'] as String?) == 'local_size')) {
      await db.execute(
          'ALTER TABLE files ADD COLUMN local_size INTEGER NOT NULL DEFAULT 0');
    }
    if (!cols.any((c) => (c['name'] as String?) == 'local_mtime')) {
      await db.execute(
          'ALTER TABLE files ADD COLUMN local_mtime INTEGER NOT NULL DEFAULT 0');
    }
  }

  Future<Map<String, ({String sha, int size, int mtime})>>
      localFingerprints() async {
    final rows = await _db.rawQuery('''
      SELECT path, local_sha, local_size, local_mtime
      FROM files WHERE deleted = 0 AND local_sha != ''
    ''');
    return {
      for (final row in rows)
        row['path'] as String: (
          sha: row['local_sha'] as String,
          size: row['local_size'] as int,
          mtime: row['local_mtime'] as int,
        ),
    };
  }

  /// Highest sequence number this folder has assigned. Starts at 0 for an
  /// empty DB. Used by the engine to know "what's the watermark I send a peer
  /// when they ask for IndexUpdates with sequence > X".
  Future<int> maxSequence() async {
    final rows = await _db.rawQuery('SELECT MAX(sequence) AS m FROM files');
    final v = rows.firstOrNull?['m'];
    return v is int ? v : 0;
  }

  /// Number of live (non-deleted) file rows. Diagnostic / for UI counts.
  Future<int> liveCount() async {
    final rows =
        await _db.rawQuery('SELECT COUNT(*) AS c FROM files WHERE deleted = 0');
    final v = rows.firstOrNull?['c'];
    return v is int ? v : 0;
  }

  /// Look up one entry by relative path. Returns null if absent. NEVER throws
  /// on a missing row — callers (scanner, engine) treat absence as "first
  /// time we've seen this file".
  Future<IndexEntry?> get(String relPath) async {
    final rows = await _db
        .rawQuery('SELECT * FROM files WHERE path = ? LIMIT 1', [relPath]);
    if (rows.isEmpty) return null;
    return _rowToEntry(rows.first);
  }

  /// All entries with `sequence > [since]`, ordered ascending — the delta a
  /// peer requests on reconnect ("give me everything past my watermark").
  /// Uses the `seq_index` index; O(log n) seek + O(k) scan.
  Future<List<IndexEntry>> changesSince(int since) async {
    final rows = await _db.rawQuery(
      'SELECT * FROM files WHERE sequence > ? ORDER BY sequence ASC',
      [since],
    );
    return rows.map(_rowToEntry).toList(growable: false);
  }

  /// Like [changesSince] but only rows ORIGINATING from [deviceId] — i.e.
  /// rows whose version vector has a non-zero counter for [deviceId].
  ///
  /// This is what the V2 engine's advertise path must use: the peer already
  /// has its own entries, so re-advertising them is wasteful and wrong. Only
  /// rows that THIS device wrote (via [upsertLocal] / [markDeletedLocal])
  /// should be sent. Rows inserted by [applyRemote] carry the remote device's
  /// counter and are correctly excluded.
  Future<List<IndexEntry>> changesSinceLocal(int since, String deviceId) async {
    final all = await changesSince(since);
    return all.where((e) {
      final c = e.version.counts[deviceId];
      return c != null && c > 0;
    }).toList(growable: false);
  }

  /// Snapshot of every live (non-deleted) entry. Used to seed a peer's initial
  /// Index on first connect (sent once per connection — REDESIGN.md §(3)).
  Future<List<IndexEntry>> liveSnapshot() async {
    final rows = await _db.rawQuery(
        'SELECT * FROM files WHERE deleted = 0 ORDER BY sequence ASC');
    return rows.map(_rowToEntry).toList(growable: false);
  }

  /// Snapshot of live entries that THIS device HAS BYTES FOR on its own disk —
  /// rows whose on-disk content is confirmed ([IndexEntry.localSha] is
  /// non-empty) OR rows this device originated (its version-vector counter for
  /// [deviceId] is non-zero).
  ///
  /// The V2 engine's needs-computation (indexDiff) compares "what WE have"
  /// against "what the PEER has". A row must appear here once we actually hold
  /// its bytes, or [indexDiff] sees `mine == null` and re-fetches it forever.
  ///
  /// Why BOTH signals, not just the origin counter (Bug #8 root cause): a file
  /// we RECEIVED from a peer and fetched to disk is confirmed via
  /// `confirmLocalObservation`, which stamps [IndexEntry.localSha] but does NOT
  /// add OUR device's counter to the version vector (only a local EDIT bumps
  /// our counter — see [upsertLocal]). So a fetched-but-never-edited file
  /// carries solely the origin device's counter. Filtering on that counter
  /// alone excluded every received file → `_processNeeds` computed a need for
  /// it on every reconcile → re-fetched it → `fs.write` churned the WAL and
  /// bumped the file mtime → the FolderWatcher's (count+size+mtime) signature
  /// changed → a spurious "Local change detected" → another reconcile →
  /// infinite loop (the ~25-min-for-11-files startup). Including
  /// `localSha != ''` makes a confirmed file visible so indexDiff's
  /// "both live, mineDiskSha == peer.sha256 → skip" path fires and the loop
  /// stops.
  ///
  /// Why keep the origin-counter branch: it covers a file this device authored
  /// (or edited) whose [IndexEntry.localSha] happens to be empty (e.g. a row
  /// seeded by [upsertLocal] before any on-disk confirmation, or a migrated
  /// pre-`local_sha` row). Those are still "ours" and must be offered to the
  /// diff. A freshly-applied peer entry that we have NOT yet fetched has
  /// `localSha == ''` AND no local counter → correctly stays excluded, so the
  /// engine still fetches it the first time (the original anti-echo invariant
  /// this method was written to preserve).
  Future<List<IndexEntry>> localSnapshot(String deviceId) async {
    final all = await liveSnapshot();
    return all.where((e) {
      if (e.localSha.isNotEmpty) return true;
      if (e.localSize < 0) return false;
      final c = e.version.counts[deviceId];
      return c != null && c > 0;
    }).toList(growable: false);
  }

  /// All rows currently marked `deleted = 1`. Used by the delete-propagation
  /// sweep (REDESIGN.md Phase 4, Bug #6): a tombstone in the DB whose file is
  /// STILL on disk is an un-propagated delete — the bytes must be removed. We
  /// include tombstones regardless of origin device, because the dominance
  /// decision ("does this delete beat a concurrent edit?") was already made when
  /// the tombstone was STORED (engine._applyRemoteTombstone) — by the time a
  /// row is `deleted=1` here, the delete is authoritative for this side.
  Future<List<IndexEntry>> tombstones() async {
    final rows = await _db.rawQuery(
        'SELECT * FROM files WHERE deleted = 1 ORDER BY sequence ASC');
    return rows.map(_rowToEntry).toList(growable: false);
  }

  /// Just the live (non-deleted) relPaths — used to detect tombstones (a path
  /// that's in the DB as live but absent from disk). Cheaper than
  /// [liveSnapshot] since it skips the version/blocks columns the scanner
  /// doesn't need.
  Future<Set<String>> livePaths() async {
    final rows = await _db.rawQuery('SELECT path FROM files WHERE deleted = 0');
    return rows.map((r) => r['path'] as String).toSet();
  }

  /// Like [livePaths] but only paths THIS device HAS BYTES FOR on its own disk
  /// — rows whose on-disk content is confirmed ([IndexEntry.localSha] is
  /// non-empty) OR rows this device originated (its version-vector counter for
  /// [deviceId] is non-zero).
  ///
  /// The scanner's tombstone detection must use THIS, not [livePaths]:
  /// `applyRemote` stores peer entries in the same table, and a peer's file
  /// that we don't have on disk is NOT a local delete — it's a file we haven't
  /// fetched yet. Using [livePaths] would wrongly tombstone every peer entry on
  /// every scan, creating a delete-storm that drowns out real local deletes.
  ///
  /// Why BOTH signals, not just the origin counter (the delete-propagation half
  /// of Bug #8): a file we RECEIVED from a peer and fetched to disk is
  /// confirmed via `confirmLocalObservation`, which stamps [IndexEntry.localSha]
  /// but does NOT add OUR device's counter to the version vector. Filtering on
  /// the origin counter alone excluded every received file, so deleting one on
  /// our side never produced a tombstone and the delete never propagated to the
  /// peer — a silent, user-visible data-divergence (delete a received file on
  /// the phone, the PC keeps it forever).
  ///
  /// `localSha` is the SAFE signal here, in a way it is NOT a risk: it never
  /// crosses the wire ([toJson] excludes it), so a freshly `applyRemote`'d peer
  /// row we have NOT yet fetched has `localSha == ''` (see [applyRemote]) and
  /// stays correctly excluded — no delete-storm. The only way `localSha`
  /// becomes non-empty is `confirmLocalObservation`, called only after THIS
  /// device actually wrote the file's bytes. So `localSha.isNotEmpty` is a
  /// truthful witness that we hold the bytes, which is exactly the precondition
  /// for "its absence from disk is a real local delete."
  Future<Set<String>> localLivePaths(String deviceId) async {
    final all = await liveSnapshot();
    return all
        .where((e) {
          if (e.localSha.isNotEmpty) return true;
          if (e.localSize < 0) return false;
          final c = e.version.counts[deviceId];
          return c != null && c > 0;
        })
        .map((e) => e.relPath)
        .toSet();
  }

  /// Record a LOCAL observation of [relPath]: the scanner saw this file on
  /// disk with the given size/mtime/sha. Bumps the version vector for
  /// [deviceId] (only OUR counter moves), assigns the next sequence, and
  /// upserts the row atomically.
  ///
  /// ## When this bumps vs no-ops (the edit-reversion fix)
  ///
  /// The authoritative content sha is [sha256] (matches the row's [sha256]
  /// field when in sync). [IndexEntry.localSha] is what THIS device last
  /// confirmed on its OWN disk — the baseline the scanner compares against:
  ///
  ///   - disk sha == localSha  → the file has not changed since our last
  ///     observation. NO bump, regardless of whether the row's authoritative
  ///     sha moved (a peer's edit landed in the DB but our disk hasn't fetched
  ///     it yet — that's STALE disk, NOT a local edit; stamping it would revert
  ///     the peer's edit). We DO refresh localSha's mtime bookkeeping only if
  ///     the authoritative sha already matches (no write needed).
  ///   - disk sha != localSha   → a genuine LOCAL change (user edited, or we
  ///     just fetched new bytes). Bump [deviceId]'s counter, advance the row's
  ///     authoritative sha to [sha256], and set localSha = [sha256].
  ///
  /// This is the only way to correctly tell "I authored new content" from "my
  /// disk is behind a peer's version" without a per-device sha baseline.
  ///
  /// Returns `true` iff a row was actually written (the file changed).
  Future<bool> upsertLocal({
    required String relPath,
    required int size,
    required int mtime,
    required String sha256,
    required String deviceId,
    List<String> blockHashes = const [],
  }) async {
    return _db.transaction((txn) async {
      final existing = await txn
          .rawQuery('SELECT * FROM files WHERE path = ? LIMIT 1', [relPath]);
      final prior = existing.isEmpty ? null : _rowToEntry(existing.first);
      final priorLocalSha = prior?.localSha ?? '';

      // No local change since our last on-disk observation → never bump, never
      // overwrite an authoritative (peer) row. This is the stale-disk guard:
      // a peer's newer row may be in the DB while our disk still holds the old
      // bytes; re-scanning those bytes must NOT be recorded as authorship or
      // it creates a concurrent version that reverts the peer's edit.
      if (prior?.deleted != true &&
          sha256 == priorLocalSha &&
          sha256.isNotEmpty) {
        if (prior!.localSize != size || prior.localMtime != mtime) {
          await txn.update('files', {'local_size': size, 'local_mtime': mtime},
              where: 'path = ?', whereArgs: [relPath]);
        }
        return false;
      }

      // First-ever observation with no prior row: seed it (no meaningful
      // bump possible — the empty vector just gains our counter).
      // Handled by the general path below.

      final nextVersion =
          (prior?.version ?? const VersionVector.empty()).bump(deviceId);
      final nextSeq = await _nextSequenceInTxn(txn);
      await txn.insert(
        'files',
        _entryToRow(IndexEntry(
          relPath: relPath,
          size: size,
          mtime: mtime,
          sha256: sha256,
          version: nextVersion,
          sequence: nextSeq,
          deleted: false,
          blockHashes: blockHashes,
          localSha: sha256,
          localSize: size,
          localMtime: mtime,
        )),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return true;
    });
  }

  /// Bounded-memory form of [changesSinceLocal]. Database rows are decoded in
  /// pages and only locally-originated entries are yielded to the transport.
  Stream<List<IndexEntry>> changesSinceLocalPages(
    int since,
    String deviceId, {
    int pageSize = 500,
  }) async* {
    var cursor = since;
    var cursorPath = '';
    while (true) {
      final rows = await _db.rawQuery(
        'SELECT * FROM files WHERE sequence > ? '
        'OR (sequence = ? AND path > ?) '
        'ORDER BY sequence ASC, path ASC LIMIT ?',
        [cursor, cursor, cursorPath, pageSize],
      );
      if (rows.isEmpty) return;
      cursor = (rows.last['sequence'] as num).toInt();
      cursorPath = rows.last['path'] as String;
      final local = rows
          .map(_rowToEntry)
          .where((entry) => (entry.version.counts[deviceId] ?? 0) > 0)
          .toList(growable: false);
      if (local.isNotEmpty) yield local;
      if (rows.length < pageSize) return;
    }
  }

  /// Apply one complete scanner pass in a single SQLite transaction. This uses
  /// the same stale-disk and version-vector rules as [upsertLocal], but avoids a
  /// SELECT, MAX(sequence), and transaction commit for every file.
  Future<List<IndexEntry>> applyLocalScan({
    required List<LocalFileObservation> observations,
    required Set<String> seenPaths,
    required String deviceId,
  }) async {
    return _db.transaction((txn) async {
      final rows = await txn.rawQuery('SELECT * FROM files');
      final current = <String, IndexEntry>{
        for (final row in rows) row['path'] as String: _rowToEntry(row),
      };
      final maxRows = await txn
          .rawQuery('SELECT COALESCE(MAX(sequence), 0) AS max_seq FROM files');
      var nextSequence = (maxRows.first['max_seq'] as num?)?.toInt() ?? 0;
      final changed = <IndexEntry>[];

      for (final observation in observations) {
        final prior = current[observation.relPath];
        final priorLocalSha = prior?.localSha ?? '';
        if (prior?.deleted != true &&
            observation.sha256 == priorLocalSha &&
            observation.sha256.isNotEmpty) {
          if (prior!.localSize != observation.size ||
              prior.localMtime != observation.mtime) {
            await txn.update(
              'files',
              {
                'local_size': observation.size,
                'local_mtime': observation.mtime,
              },
              where: 'path = ?',
              whereArgs: [observation.relPath],
            );
          }
          continue;
        }

        nextSequence++;
        final entry = IndexEntry(
          relPath: observation.relPath,
          size: observation.size,
          mtime: observation.mtime,
          sha256: observation.sha256,
          version:
              (prior?.version ?? const VersionVector.empty()).bump(deviceId),
          sequence: nextSequence,
          localSha: observation.sha256,
          localSize: observation.size,
          localMtime: observation.mtime,
        );
        await txn.insert('files', _entryToRow(entry),
            conflictAlgorithm: sqf.ConflictAlgorithm.replace);
        current[observation.relPath] = entry;
        changed.add(entry);
      }

      for (final prior in current.values.toList(growable: false)) {
        if (prior.deleted || seenPaths.contains(prior.relPath)) continue;
        final localCounter = prior.version.counts[deviceId] ?? 0;
        final hasLocalBytes = prior.localSha.isNotEmpty ||
            (prior.localSize >= 0 && localCounter > 0);
        if (!hasLocalBytes) continue;
        nextSequence++;
        final tombstone = IndexEntry(
          relPath: prior.relPath,
          size: prior.size,
          mtime: prior.mtime,
          sha256: prior.sha256,
          version: prior.version.bump(deviceId),
          sequence: nextSequence,
          deleted: true,
          blockHashes: prior.blockHashes,
        );
        await txn.insert('files', _entryToRow(tombstone),
            conflictAlgorithm: sqf.ConflictAlgorithm.replace);
        changed.add(tombstone);
      }

      changed.sort((a, b) => a.sequence.compareTo(b.sequence));
      return changed;
    });
  }

  /// Record a LOCAL deletion of [relPath]: the scanner saw the file is gone.
  /// A delete is NEVER a row removal — it is a row with `deleted = 1` and a
  /// bumped version (REDESIGN.md §(2)). The bumped version dominates the
  /// pre-delete version, so a peer that has the live copy will delete it too;
  /// a peer that concurrently modified the file has a higher version and the
  /// delete correctly loses (conflict → `.syncversions`). This is the heart
  /// of fixing root flaw #3 (stale-snapshot deletes).
  ///
  /// Idempotent: deleting an already-deleted row is a no-op. Returns `true`
  /// iff a row was actually written.
  Future<bool> markDeletedLocal(
      {required String relPath, required String deviceId}) async {
    return _db.transaction((txn) async {
      final existing = await txn
          .rawQuery('SELECT * FROM files WHERE path = ? LIMIT 1', [relPath]);
      final prior = existing.isEmpty ? null : _rowToEntry(existing.first);
      if (prior != null && prior.deleted) return false; // already a tombstone

      final nextVersion =
          (prior?.version ?? const VersionVector.empty()).bump(deviceId);
      final nextSeq = await _nextSequenceInTxn(txn);
      await txn.insert(
        'files',
        _entryToRow(IndexEntry(
          relPath: relPath,
          size: prior?.size ?? 0,
          mtime: prior?.mtime ?? 0,
          sha256: prior?.sha256 ?? '',
          version: nextVersion,
          sequence: nextSeq,
          deleted: true,
          blockHashes: prior?.blockHashes ?? const <String>[],
        )),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return true;
    });
  }

  /// Record that THIS device has CONFIRMED the bytes on disk hash to [sha] —
  /// WITHOUT bumping the version. Used by the engine's post-fetch path: a
  /// successful fetch writes verified bytes, so the on-disk baseline
  /// ([IndexEntry.localSha]) must advance to [sha] so the next scanner pass
  /// sees disk == baseline and does NOT mis-classify it as a local edit.
  ///
  /// This never changes the authoritative [sha256]/[version] of the row — it
  /// only stamps the local-disk baseline. That separation is what lets the
  /// scanner distinguish "I have these bytes" (localSha) from "the newest known
  /// version" (sha256), so stale disk after a peer update is not mistaken for
  /// authorship (the edit-reversion bug). If [sha] already matches the row's
  /// localSha this is a no-op.
  Future<void> confirmLocalObservation({
    required String relPath,
    required String sha,
  }) async {
    await _db.transaction((txn) async {
      final existing = await txn
          .rawQuery('SELECT * FROM files WHERE path = ? LIMIT 1', [relPath]);
      if (existing.isEmpty) return;
      final prior = _rowToEntry(existing.first);
      if (prior.localSha == sha) return; // already recorded
      await txn.insert(
        'files',
        _entryToRow(prior.withLocalSha(sha)),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  /// Resolve a CONCURRENT edit-vs-delete tie in favor of the LOCAL edit:
  /// merge the remote tombstone's version counters into the existing LIVE row
  /// (so future dominance comparisons are accurate — we now "know" the peer
  /// reached its delete counter) but KEEP the row live (`deleted = 0`) and
  /// preserve our own content fields (size/sha/sequence). The file stays on
  /// disk; the peer learns of our edit on its next reconcile and resurrects.
  ///
  /// This is the edit-wins half of the delete-propagation rule
  /// (REDESIGN.md Phase 4, Bug #6). No-op if no live prior row exists.
  Future<void> resolveEditWinsDelete({
    required String relPath,
    required VersionVector remoteVersion,
  }) async {
    await _db.transaction((txn) async {
      final existing = await txn
          .rawQuery('SELECT * FROM files WHERE path = ? LIMIT 1', [relPath]);
      if (existing.isEmpty) return;
      final prior = _rowToEntry(existing.first);
      if (prior.deleted) return; // already tombstoned — nothing to resolve
      final merged = prior.version.merge(remoteVersion);
      if (merged == prior.version) return; // no new counter to absorb
      await txn.insert('files', _entryToRow(prior.withVersion(merged)),
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  /// Apply a REMOTE entry received from a peer (via Index or IndexUpdate).
  ///
  /// Stores the row so the DB is the durable source of truth for "what does my
  /// peer have". Insert-or-replace on (path, sequence): a remote row only
  /// supersedes a prior one if its sequence is strictly greater, so out-of-order
  /// or duplicate IndexUpdates are harmless.
  ///
  /// **Version merging (the edit-reversion fix).** The stored version is the
  /// per-device MAX of the incoming remote version and the row already on disk
  /// — never a pure replace. Why: a peer's row carries ONLY the authoring
  /// device's counter. If we replaced, we would LOSE the origin counter (e.g.
  /// a phone-created file's `PHONE:1` would vanish the moment the PC's edit row
  /// `{PC:1}` arrived). Losing it makes the two sides' vectors CONCURRENT
  /// (same counts, different shas) → `indexDiff`'s conflict path fetches stale
  /// content over a genuine edit → the edit is reverted. Merging preserves
  /// every device's counter, so the side that edits ends up strictly
  /// dominating the side that merely received.
  Future<void> applyRemote(IndexEntry remote) async {
    await _db.transaction((txn) async {
      final existing = await txn.rawQuery(
          'SELECT * FROM files WHERE path = ? LIMIT 1', [remote.relPath]);
      final prior = existing.isEmpty ? null : _rowToEntry(existing.first);
      final priorSeq = prior?.sequence ?? -1;

      // The version-vector MERGE runs UNCONDITIONALLY — BEFORE the sequence
      // guard below, and regardless of whether that guard fires. Why: sequences
      // are per-device, per-folder counters that are NOT comparable across
      // devices. A remote row for a path this device already has (e.g. a file
      // WE authored that the peer merely re-advertises) still carries the peer's
      // ORIGIN counter. The old code's `return` on `sequence <= priorSeq`
      // dropped the whole frame — including that counter — so a later edit here
      // bumped a vector missing the peer's entry, the two sides' vectors
      // diverged (peer {P:1, Me:2} vs us {Me:2}), the peer strictly dominated,
      // and indexDiff fetched the peer's OLDER bytes — a silent edit reversion
      // (hardware smoke #3, repro'd 2026-06-24). The merge is idempotent and
      // commutative, so running it on every frame cannot loop or grow.
      final mergedVersion =
          (prior?.version ?? const VersionVector.empty()).merge(remote.version);

      // A live version that causally dominates our tombstone is an explicit
      // resurrection. Accept it even when its per-device sequence is lower
      // than ours (sequences are not comparable across devices), but mark it
      // as awaiting local bytes. The old tombstone contains our device counter;
      // without this sentinel localSnapshot/localLivePaths would mistake the
      // metadata-only row for a file we still have, re-tombstone it before the
      // fetch, and send a newer delete back to the restoring peer.
      if (prior?.deleted == true &&
          !remote.deleted &&
          remote.version.dominates(prior!.version)) {
        final staged = IndexEntry(
          relPath: remote.relPath,
          size: remote.size,
          mtime: remote.mtime,
          sha256: remote.sha256,
          version: mergedVersion,
          sequence: remote.sequence > prior.sequence
              ? remote.sequence
              : prior.sequence,
          deleted: false,
          blockHashes: remote.blockHashes,
          localSha: '',
          localSize: -1,
          localMtime: -1,
        );
        await txn.insert('files', _entryToRow(staged),
            conflictAlgorithm: ConflictAlgorithm.replace);
        return;
      }

      // Transport dedup: a remote row at or below the sequence we already hold
      // must NOT move the transport fields (size/mtime/sha/sequence) backwards
      // — those describe the newest CONTENT this device knows.
      //
      // Version-merge guard (smoke #3 fix): when the remote carries an ORIGIN
      // COUNTER we lacked (e.g. the peer re-advertises a path we authored,
      // carrying their own earlier {Peer:1} entry), we must absorb that counter
      // so our vector doesn't look spuriously newer than the peer's on the next
      // diff — which would make indexDiff fetching the peer's stale bytes
      // (edit-reversion, hardware smoke #3).
      //
      // HOWEVER, the merge must only run when the CONTENT is the same
      // (remote.sha256 == prior.sha256). If the shas differ AND the sequence
      // guard fires, this is a first-pair concurrent conflict: two devices
      // independently created the same path before ever pairing. Merging their
      // version counters here would give us a merged vector that DOMINATES the
      // peer's version in indexDiff — masking the conflict entirely and
      // preventing the LWW tie-break from ever running. Leaving the vectors
      // SEPARATE keeps them concurrent (neither dominates), so indexDiff
      // correctly applies LWW and exactly ONE side fetches.
      if (remote.sequence <= priorSeq) {
        if (prior != null &&
            remote.sha256 == prior.sha256 &&
            mergedVersion != prior.version) {
          // Same content, different origin counter — absorb without updating
          // transport fields.
          await txn.insert(
              'files', _entryToRow(prior.withVersion(mergedVersion)),
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
        return;
      }

      // A FRESH peer row (no prior on this device) must get localSha=''.
      // localSha is "the sha of the bytes THIS device last confirmed on its OWN
      // disk" — a brand-new received row has NO on-disk baseline yet, so it
      // would be a lie to inherit whatever localSha the in-memory entry happens
      // to carry. (Over the wire [toJson] already strips localSha so this is a
      // no-op there; but in-memory callers may pass a DB-read entry whose
      // localSha is the sender's, and inheriting it would make an UNFETCHED
      // row look confirmed — which would let [localLivePaths] tombstone it on
      // the next scan = a delete-storm of files we simply haven't pulled yet.
      // Zeroing here makes "unfetched ⇒ localSha empty" a guaranteed invariant
      // at the applyRemote boundary. The engine's post-fetch
      // confirmLocalObservation repopulates localSha with THIS device's own
      // confirmed sha, so Bug #8's needs-skip path still fires after a real
      // fetch. For a row we already had, [priorLocalSha] preserves our own
      // baseline across the peer's content update — see the next block.)
      final priorLocalSha = prior?.localSha ?? '';
      final merged = prior == null
          ? remote.withLocalSha('')
          : IndexEntry(
              relPath: remote.relPath,
              size: remote.size,
              mtime: remote.mtime,
              sha256: remote.sha256,
              version: mergedVersion,
              sequence: remote.sequence,
              deleted: remote.deleted,
              blockHashes: remote.blockHashes,
              localSha: priorLocalSha,
              localSize: prior.localSize,
              localMtime: prior.localMtime,
            );
      await txn.insert('files', _entryToRow(merged),
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  /// Close the underlying handle. Safe to call multiple times. After close,
  /// every other method throws — the engine must reopen via [open].
  Future<void> close() async => _db.close();

  /// Make a crash-recovery backup of the DB file (Roadmap Phase 0.5).
  ///
  /// Atomically copies the main `.db` file to `<path>.bak` (overwriting any
  /// prior backup). The copy is taken WITHOUT an exclusive lock: SQLite under
  /// WAL tolerates a concurrent file copy of the main file, and we follow it
  /// with a `PRAGMA wal_checkpoint(TRUNCATE)` first so the backup captures a
  /// complete, consistent snapshot rather than a partial WAL state. On any
  /// I/O error the backup is skipped (logged) — it must NEVER interrupt sync,
  /// since a missing backup just means the next hourly tick tries again.
  ///
  /// The result is true iff a fresh backup file was written.
  Future<bool> backup() async {
    try {
      // Fold the WAL back into the main file so the copy is self-contained.
      await _db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      final src = File(_path);
      if (!await src.exists()) return false;
      final dest = File('$_path.bak');
      await src.copy(dest.path);
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('[Conduit][db] backup FAILED ($pairId): $e');
      return false;
    }
  }

  // ---- internals -----------------------------------------------------------

  /// Next monotonic sequence number within a transaction. Reads MAX+1 inside
  /// the txn so concurrent writers can't get the same value (SQLite
  /// transactions are serial).
  Future<int> _nextSequenceInTxn(Transaction txn) async {
    final rows = await txn.rawQuery('SELECT MAX(sequence) AS m FROM files');
    final v = rows.firstOrNull?['m'];
    return (v is int ? v : 0) + 1;
  }

  static IndexEntry _rowToEntry(Map<String, Object?> row) {
    final versionJson =
        jsonDecode(row['version'] as String) as Map<String, dynamic>;
    final blocksRaw = row['block_hashes'] as String?;
    final blocks = blocksRaw == null
        ? const <String>[]
        : (jsonDecode(blocksRaw) as List).cast<String>();
    // local_sha is nullable only on pre-migration rows; _migrate adds it with a
    // default of '' so this is always present after open. Coerce defensively.
    final localSha = (row['local_sha'] as String?) ?? '';
    return IndexEntry(
      relPath: row['path'] as String,
      size: row['size'] as int,
      mtime: row['mtime'] as int,
      sha256: row['sha256'] as String,
      version: VersionVector.fromJson(versionJson),
      sequence: row['sequence'] as int,
      deleted: (row['deleted'] as int) != 0,
      blockHashes: blocks,
      localSha: localSha,
      localSize: (row['local_size'] as int?) ?? 0,
      localMtime: (row['local_mtime'] as int?) ?? 0,
    );
  }

  static Map<String, Object?> _entryToRow(IndexEntry e) {
    return <String, Object?>{
      'path': e.relPath,
      'size': e.size,
      'mtime': e.mtime,
      'sha256': e.sha256,
      'version': jsonEncode(e.version.toJson()),
      'sequence': e.sequence,
      'deleted': e.deleted ? 1 : 0,
      'block_hashes': e.blockHashes.isEmpty ? null : jsonEncode(e.blockHashes),
      'local_sha': e.localSha,
      'local_size': e.localSize,
      'local_mtime': e.localMtime,
    };
  }

  /// Exposed for tests / diagnostics only. Production code never touches the
  /// raw [Database]; it goes through the typed methods above.
  @visibleForTesting
  Database get rawDb => _db;
}
