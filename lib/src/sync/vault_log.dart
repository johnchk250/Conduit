/// Roadmap Phase 6.4 — a lightweight per-pair catalog of files moved into
/// the `.syncversions` vault by `_replacePartWithFinal` (block_transfer.dart),
/// so the version-restore UI can list and restore a previous version
/// WITHOUT needing to directory-list `.syncversions/` itself.
///
/// Deliberately NOT built on a directory listing: `FileSystemAccess.listFiles`
/// (and the Android SAF native `listFiles`/`listFilesWithStat`) already
/// filter out `.syncversions` at the top level (see manifest.dart,
/// SafOps.kt) — that's existing, load-bearing behavior for the sync
/// scanner and not something to touch. Extending the native Android side
/// to also expose vault contents would mean writing and shipping new,
/// unverifiable Kotlin — this sandbox has no Android SDK/emulator to
/// build or test it against, and getting SAF traversal subtly wrong is
/// exactly the kind of thing that could disturb the working app.
///
/// Reading a SPECIFIC known relPath back, by contrast, needs no new native
/// code at all: the existing `stat`/`read` native handlers resolve an
/// exact path with no directory-level filtering (confirmed by reading
/// SafOps.kt — see PROGRESS.md 2026-07-11). So instead of listing, this
/// keeps its own small catalog of "what got vaulted and when" — written
/// purely on the Dart side — and the restore action reads the vaulted
/// file back through the ordinary [FileSystemAccess] `stat`/`openRead`
/// path, exactly like reading any other file.
///
/// Stored as one JSON file per pair, in the app's own state directory
/// (the same [Directory] [IndexDb] already uses — see
/// `SyncEngine.stateDir` — just a sibling `vault_log/` folder instead of
/// `index/`), NOT inside the synced folder itself. This keeps it fully
/// separate from the sync-critical Index DB (no schema migration, no
/// shared table, nothing the scanner/reconcile path reads) and from the
/// synced folder tree (nothing new for `_isInternalArtefact` to worry
/// about).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../storage/index_db.dart';
import 'version_vector.dart';

const vaultRetention = Duration(days: 14);

enum VaultReason {
  incomingOverwrite,
  conflictReplacement,
  peerDelete,
  restoreReplacement,
}

enum VaultOutcomeStatus { moved, absent, failed, invalidPath }

class VaultOutcome {
  const VaultOutcome(this.status, {this.entry});
  final VaultOutcomeStatus status;
  final VaultLogEntry? entry;
}

enum RestoreResult {
  restoredAndQueued,
  restoredOffline,
  restoredLocalOnlyByDirection,
  sourceMissing,
  permissionLost,
  invalidPath,
  failed,
}

class VaultLogReadException implements Exception {
  VaultLogReadException(this.cause);
  final Object cause;
  @override
  String toString() => 'VaultLogReadException: $cause';
}

class VaultLogEntry {
  /// The live path this was a version of, e.g. `docs/report.docx`.
  final String relPath;

  /// The path [FileSystemAccess.moveToVault] returned — pass this straight
  /// back to `stat`/`openRead` to read the old bytes. For
  /// [LocalFileSystemAccess] this is an absolute filesystem path already
  /// including [rootPath]; callers restoring on Windows should NOT
  /// re-join it with rootPath. For SAF it's whatever relative form the
  /// native side returns — always round-trip it unmodified.
  final String vaultPath;

  final DateTime timestamp;

  /// Size of the OLD file that was vaulted (not any incoming/new size).
  final int sizeBytes;
  final VaultReason reason;
  final String? sourcePeerId;
  final String? originalSha256;
  final VersionVector? originalVersion;
  final DateTime? restoredAt;

  VaultLogEntry({
    required this.relPath,
    required this.vaultPath,
    required this.timestamp,
    required this.sizeBytes,
    this.reason = VaultReason.incomingOverwrite,
    this.sourcePeerId,
    this.originalSha256,
    this.originalVersion,
    this.restoredAt,
  });

  String get entryId =>
      '${timestamp.toUtc().microsecondsSinceEpoch}|$vaultPath';

  Map<String, dynamic> toJson() => {
        'relPath': relPath,
        'vaultPath': vaultPath,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'sizeBytes': sizeBytes,
        'reason': reason.name,
        if (sourcePeerId != null) 'sourcePeerId': sourcePeerId,
        if (originalSha256 != null) 'originalSha256': originalSha256,
        if (originalVersion != null)
          'originalVersion': originalVersion!.toJson(),
        if (restoredAt != null)
          'restoredAt': restoredAt!.toUtc().toIso8601String(),
      };

  factory VaultLogEntry.fromJson(Map<String, dynamic> j) {
    VaultReason reason = VaultReason.incomingOverwrite;
    final rawReason = j['reason'];
    if (rawReason is String) {
      reason = VaultReason.values
              .where((candidate) => candidate.name == rawReason)
              .firstOrNull ??
          VaultReason.incomingOverwrite;
    }
    VersionVector? originalVersion;
    final rawVersion = j['originalVersion'];
    if (rawVersion is Map) {
      try {
        originalVersion =
            VersionVector.fromJson(rawVersion.cast<String, dynamic>());
      } catch (_) {}
    }
    DateTime? restoredAt;
    final rawRestoredAt = j['restoredAt'];
    if (rawRestoredAt is String) {
      restoredAt = DateTime.tryParse(rawRestoredAt)?.toUtc();
    }
    return VaultLogEntry(
      relPath: j['relPath'] as String,
      vaultPath: j['vaultPath'] as String,
      timestamp: DateTime.parse(j['timestamp'] as String).toUtc(),
      sizeBytes: (j['sizeBytes'] as num).toInt(),
      reason: reason,
      sourcePeerId: j['sourcePeerId'] as String?,
      originalSha256: j['originalSha256'] as String?,
      originalVersion: originalVersion,
      restoredAt: restoredAt,
    );
  }

  VaultLogEntry markRestored(DateTime value) => VaultLogEntry(
        relPath: relPath,
        vaultPath: vaultPath,
        timestamp: timestamp,
        sizeBytes: sizeBytes,
        reason: reason,
        sourcePeerId: sourcePeerId,
        originalSha256: originalSha256,
        originalVersion: originalVersion,
        restoredAt: value,
      );
}

class VaultLog {
  final File _file;

  VaultLog._(this._file);

  static Future<VaultLog> open(String pairId, Directory stateDir) async {
    final dir = Directory(p.join(stateDir.path, 'vault_log'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final safe = pairId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return VaultLog._(File(p.join(dir.path, '$safe.json')));
  }

  /// All entries, most recent first. Never throws: a missing or corrupt
  /// log file (this is a convenience index, not the source of truth — the
  /// actual vaulted files on disk are unaffected either way) is treated as
  /// empty rather than surfacing an error to the UI.
  Future<List<VaultLogEntry>> all() async {
    if (!await _file.exists()) return [];
    try {
      final raw = await _file.readAsString();
      final list = jsonDecode(raw) as List;
      final entries = list
          .map((e) => VaultLogEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      entries.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return entries;
    } catch (_) {
      return [];
    }
  }

  Future<List<VaultLogEntry>> allForMaintenance() async {
    if (!await _file.exists()) return [];
    try {
      final raw = await _file.readAsString();
      final list = jsonDecode(raw) as List;
      final entries = list
          .map((e) => VaultLogEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      entries.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return entries;
    } catch (e) {
      throw VaultLogReadException(e);
    }
  }

  /// Appends one entry before the engine applies the retention policy.
  Future<void> record(VaultLogEntry entry) async {
    final entries = await all();
    entries.add(entry);
    await replaceAll(entries);
  }

  /// Removes one entry (used after a successful restore, or if the
  /// underlying vault file has gone missing) without touching any other
  /// entry. No-ops if the exact entry can't be found — restore proceeds
  /// either way, this only tidies the catalog.
  Future<void> remove(VaultLogEntry entry) async {
    final entries = await all();
    entries.removeWhere((e) =>
        e.relPath == entry.relPath &&
        e.vaultPath == entry.vaultPath &&
        e.timestamp == entry.timestamp);
    await replaceAll(entries);
  }

  Future<void> markRestored(String entryId, DateTime restoredAt) async {
    final entries = await all();
    final updated = [
      for (final entry in entries)
        if (entry.entryId == entryId) entry.markRestored(restoredAt) else entry,
    ];
    await replaceAll(updated);
  }

  Future<void> replaceAll(List<VaultLogEntry> entries) async {
    final tmp = File('${_file.path}.tmp');
    final sink = tmp.openWrite();
    sink.write(jsonEncode(entries.map((e) => e.toJson()).toList()));
    await sink.flush();
    await sink.close();
    try {
      await tmp.rename(_file.path);
    } on FileSystemException {
      if (await _file.exists()) await _file.delete();
      await tmp.rename(_file.path);
    }
  }
}
