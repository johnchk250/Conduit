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

  VaultLogEntry({
    required this.relPath,
    required this.vaultPath,
    required this.timestamp,
    required this.sizeBytes,
  });

  Map<String, dynamic> toJson() => {
        'relPath': relPath,
        'vaultPath': vaultPath,
        'timestamp': timestamp.toIso8601String(),
        'sizeBytes': sizeBytes,
      };

  factory VaultLogEntry.fromJson(Map<String, dynamic> j) => VaultLogEntry(
        relPath: j['relPath'] as String,
        vaultPath: j['vaultPath'] as String,
        timestamp: DateTime.parse(j['timestamp'] as String),
        sizeBytes: j['sizeBytes'] as int,
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

  /// Appends one entry. Read-modify-write of a small JSON file — fine for
  /// this log's expected size (one entry per overwritten file, and only
  /// on devices that actually edit synced files locally); no pruning yet,
  /// matching the plan's own "retention policy out of scope for the first
  /// cut" call for the vault directory itself.
  Future<void> record(VaultLogEntry entry) async {
    final entries = await all();
    entries.add(entry);
    await _file.writeAsString(
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
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
    await _file.writeAsString(
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
  }
}
