import '../storage/index_db.dart';
import '../sync/ignore_rules.dart';
import '../sync/manifest.dart';

/// Result of one [IndexScanner.scan] pass: the entries whose rows actually
/// moved (created, modified, or tombstoned) since the last scan, plus the new
/// folder-wide max sequence. The engine sends these as IndexUpdates — anything
/// not in [changed] burned no sequence and is silently skipped on the wire.
class ScanResult {
  /// Entries whose sequence just bumped (live OR tombstone), ordered by
  /// sequence ascending so a peer consuming them updates its watermark
  /// monotonically.
  final List<IndexEntry> changed;

  /// Folder-wide max sequence after this scan. Equals
  /// `changed.last.sequence` when non-empty, else the unchanged prior max.
  final int maxSequence;

  ScanResult(this.changed, this.maxSequence);

  bool get isEmpty => changed.isEmpty;
}

/// Walks a sync folder and reconciles its on-disk contents with the per-folder
/// [IndexDb] (REDESIGN.md §(4): "Scanner decoupled from sync").
///
/// Each [scan]:
///   1. Lists every file under [rootPath] (via [FileSystemAccess]).
///   2. For each, hashes it (reusing nothing — see below) and calls
///      [IndexDb.upsertLocal]. That method is itself a no-op when size+mtime+
///      sha+blocks are unchanged, so re-scans of an unmodified folder burn zero
///      sequences. THIS IS THE KEY INVARIANT: a no-op re-scan must not bump any
///      version, or peers would re-fetch unchanged files forever.
///   3. Any live DB path absent from disk → [IndexDb.markDeletedLocal]
///      (a tombstone row with bumped version — Phase 4 propagates the delete).
///   4. Returns the [ScanResult] = the entries that actually moved.
///
/// Why hash every file on every scan? The scanner reuses a cached hash when
/// cached hash for unchanged size+mtime? Because the IndexDb fast path is
/// itself the cache: upsertLocal reads the prior row and compares. Re-hashing
/// is the cost of correctness — size+mtime can be unchanged while content
/// differs (rare but real: a same-length rewrite, a copy that preserves mtime).
/// The legacy manifest cache traded correctness for speed; the new engine does
/// not. The per-scan hash cost is bounded and, unlike the legacy path, the
/// result is durable (persists in SQLite across reconnects) so the cost is paid
/// once per actual change, not once per reconcile.
///
/// NOTE on deletes: a vanished file becomes a tombstone in the DB but Phase 2
/// does NOT propagate deletes to the peer — that's Phase 4 (version-vector
/// dominance decides whether the delete wins or a concurrent edit on the peer
/// does). Phase 2's scanner still RECORDS the tombstone so the data is present
/// when Phase 4 ships.
class IndexScanner {
  IndexScanner();

  /// One scan pass. See class docs for the algorithm and invariants.
  ///
  /// [deviceId] is THIS device's id — only our own counter moves on a local
  /// change (see [VersionVector.bump]).
  ///
  /// [batchListWithStat] is an optional fast-path lister (Roadmap Phase 0.6 —
  /// battery). When supplied it replaces [FileSystemAccess.listFiles] +
  /// one [FileSystemAccess.stat] call per file with a single batched
  /// metadata fetch — on Android this is [SafFileSystemAccess.listFilesWithStat],
  /// which costs one ContentResolver query per directory instead of several
  /// per file. When null (every non-Android caller, and any existing test),
  /// behaviour is byte-for-byte identical to before this parameter existed.
  /// Hashing is unaffected either way — see class docs for why every file is
  /// still hashed on every scan.
  /// [ignoreGlobs], [ignoreExtensions], and [maxFileSizeBytes] are Roadmap
  /// Phase 6.2 (ignore rules) — all optional and default to
  /// empty/null/no-op, so every pre-Phase-6 caller (and every existing
  /// test) behaves byte-for-byte as before. A path matching a rule is
  /// skipped before it's ever hashed or upserted — same "never-indexed"
  /// shape as `.syncstate`/`.syncversions` — but is still added to
  /// [seenPaths] so it's FROZEN rather than tombstoned: an
  /// already-synced file that starts matching a rule keeps its last-synced
  /// state and stops receiving further local-edit propagation, but is never
  /// deleted or delete-propagated to the peer. (Confirmed with the user
  /// 2026-07-11 — the alternative, treating a new ignore rule like a
  /// delete, is a different feature.)
  Future<ScanResult> scan({
    required FileSystemAccess fs,
    required IndexDb db,
    required String rootPath,
    required String deviceId,
    Future<List<FileEntry>> Function(String rootPath)? batchListWithStat,
    List<String> ignoreGlobs = const [],
    List<String> ignoreExtensions = const [],
    int? maxFileSizeBytes,
  }) async {
    final changed = <IndexEntry>[];
    final seenPaths = <String>{};

    final diskEntries =
        await _listWithStat(fs, rootPath, batchListWithStat);
    for (final fileEntry in diskEntries) {
      final rel = fileEntry.relPath;
      // Skip our own metadata artefacts. The legacy LocalFileSystemAccess
      // already filters .syncstate/.syncversions at list time; we add the V2
      // partial-download suffix here so a crashed block transfer never appears
      // as a "new file" in the index.
      if (_isInternalArtefact(rel)) continue;

      // Phase 6.2 — ignore rules. Freeze (not tombstone): still mark the
      // path seen so the tombstone sweep below leaves it alone, but skip
      // hashing/upserting so it never enters the Index DB, never gets a
      // version vector bump, and further local edits stop propagating.
      if (matchesIgnoreRule(
        rel,
        sizeBytes: fileEntry.size,
        globs: ignoreGlobs,
        extensions: ignoreExtensions,
        maxFileSizeBytes: maxFileSizeBytes,
      )) {
        seenPaths.add(rel);
        continue;
      }

      seenPaths.add(rel);

      // Hash every file. See class docs for why we don't reuse a cached digest.
      final sha = await hashFile(fs, rootPath, rel);

      final wrote = await db.upsertLocal(
        relPath: rel,
        size: fileEntry.size,
        mtime: fileEntry.mtime,
        sha256: sha,
        deviceId: deviceId,
      );
      if (wrote) {
        final entry = await db.get(rel);
        if (entry != null) changed.add(entry);
      }
    }

    // Tombstone detection: any LOCAL path that was live before this scan but
    // wasn't seen on disk this pass has been deleted locally. We use
    // localLivePaths (not livePaths) because applyRemote stores peer entries in
    // the same table — a peer's file we haven't fetched yet is NOT a local
    // delete, and tombstoning it would create a delete-storm.
    final priorLive = await db.localLivePaths(deviceId);
    for (final prior in priorLive) {
      if (!seenPaths.contains(prior)) {
        final wrote =
            await db.markDeletedLocal(relPath: prior, deviceId: deviceId);
        if (wrote) {
          final entry = await db.get(prior);
          if (entry != null) changed.add(entry);
        }
      }
    }

    changed.sort((a, b) => a.sequence.compareTo(b.sequence));
    final maxSeq =
        changed.isEmpty ? await db.maxSequence() : changed.last.sequence;
    return ScanResult(changed, maxSeq);
  }

  /// Lists every file under [rootPath] with its size+mtime. Uses
  /// [batchListWithStat] when supplied (one batched call); otherwise falls
  /// back to the original [FileSystemAccess.listFiles] + per-file
  /// [FileSystemAccess.stat] loop, unchanged from before Roadmap Phase 0.6. A
  /// file that races away between list and stat is silently skipped in the
  /// fallback path, matching prior behaviour; the batched path is a single
  /// atomic-enough directory read so this race window doesn't apply there.
  static Future<List<FileEntry>> _listWithStat(
    FileSystemAccess fs,
    String rootPath,
    Future<List<FileEntry>> Function(String rootPath)? batchListWithStat,
  ) async {
    if (batchListWithStat != null) {
      return batchListWithStat(rootPath);
    }
    final out = <FileEntry>[];
    final diskFiles = await fs.listFiles(rootPath);
    for (final rel in diskFiles) {
      final stat = await fs.stat(rootPath, rel);
      if (stat == null) continue; // raced away between list and stat
      out.add(stat);
    }
    return out;
  }

  /// True for paths the sync engine itself creates and must never index.
  /// `.syncpart` is the V2 block-transfer partial-download suffix; the others
  /// are pre-existing metadata dirs already filtered by LocalFileSystemAccess
  /// but defended here too so a SAF backend (which may not filter) is safe.
  static bool _isInternalArtefact(String rel) {
    final norm = rel.replaceAll('\\', '/');
    if (norm.startsWith('.syncstate/')) return true;
    if (norm.startsWith('.syncversions/')) return true;
    // V2 partial download: <name>.<ext>.syncpart at any depth.
    if (norm.endsWith('.syncpart')) return true;
    return false;
  }
}
