import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// One entry describing a file in a sync folder. `sha256` is the full-file
/// hash; block-level transfer additionally verifies per-block, but the index
/// layer only needs the whole-file digest to detect changes cheaply.
class FileEntry {
  final String relPath;
  final int size;
  final int mtime; // ms since epoch
  final String sha256;

  FileEntry({
    required this.relPath,
    required this.size,
    required this.mtime,
    required this.sha256,
  });

  Map<String, dynamic> toJson() => {
        'path': relPath,
        'size': size,
        'mtime': mtime,
        'sha256': sha256,
      };

  factory FileEntry.fromJson(Map<String, dynamic> j) => FileEntry(
        relPath: j['path'] as String,
        size: j['size'] as int,
        mtime: j['mtime'] as int,
        sha256: j['sha256'] as String,
      );

  @override
  String toString() => 'FileEntry($relPath, $size, $mtime)';
}

/// What the engine needs to know about the local filesystem for a pair.
/// On Windows this is direct File I/O; on Android it's proxied through the
/// SAF platform channel (see lib/src/platform/saf_access.dart).
abstract class FileSystemAccess {
  bool get isAndroidSAF;

  /// Recursively list all files under [rootPath], returning relative paths.
  Future<List<String>> listFiles(String rootPath);

  /// Stat a single file. Returns null if it doesn't exist.
  Future<FileEntry?> stat(String rootPath, String relPath);

  /// Open a readable byte stream for a file at [offset].
  Stream<List<int>> openRead(String rootPath, String relPath, [int offset = 0]);

  /// Write [data] to [relPath] under [rootPath], creating parent dirs.
  Future<void> write(String rootPath, String relPath, List<int> data);

  /// Append [data] to an existing file (used for chunked resume).
  Future<void> append(String rootPath, String relPath, List<int> data);

  /// Delete a file. Returns true if something was deleted.
  Future<bool> delete(String rootPath, String relPath);

  /// Move a file to the conflict vault directory (under .syncversions).
  /// Returns a path RELATIVE to [rootPath] — matching the Android SAF
  /// native implementation's convention (see SafOps.kt's `vaultRel`) —
  /// so callers can pass the return value straight back to
  /// `stat`/`openRead` uniformly across platforms, without re-deriving
  /// anything platform-specific. (This return value had zero callers
  /// before Roadmap Phase 6.4 wired it into `_replacePartWithFinal` and
  /// `AppState.restoreVersion` — the two implementations previously
  /// disagreed, Local returning an absolute path and SAF a relative one;
  /// fixed here, at the one moment that change is guaranteed to affect no
  /// existing behavior.)
  Future<String> moveToVault(String rootPath, String relPath) async {
    final relDir = p.dirname(relPath); // '.' when relPath has no directory
    final vaultDir = p.join(rootPath, '.syncversions', relDir);
    await Directory(vaultDir).create(recursive: true);
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final base = p.basenameWithoutExtension(relPath);
    final ext = p.extension(relPath);
    final destName = '$base.$stamp$ext';
    final dest = p.join(vaultDir, destName);
    final src = p.join(rootPath, relPath);
    await File(src).rename(dest);
    final vaultRelDir =
        relDir == '.' ? '.syncversions' : p.join('.syncversions', relDir);
    return p.join(vaultRelDir, destName);
  }
}

/// Optional filesystem capability for materializing a completed temporary
/// file without copying all of its bytes through Dart.
abstract interface class TemporaryFileFinalizer {
  Future<void> replaceFromTemporary(
    String rootPath,
    String temporaryRelPath,
    String destinationRelPath,
  );
}

/// Standard filesystem access for Windows (and any platform with real File I/O).
class LocalFileSystemAccess implements FileSystemAccess {
  const LocalFileSystemAccess();

  @override
  bool get isAndroidSAF => false;

  @override
  Future<List<String>> listFiles(String rootPath) async {
    final root = Directory(rootPath);
    if (!await root.exists()) return [];
    final result = <String>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: rootPath);
      // Skip our own state dir and hidden versioning vault.
      if (rel.startsWith('.syncstate') || rel.startsWith('.syncversions')) {
        continue;
      }
      result.add(rel.replaceAll('\\', '/'));
    }
    return result;
  }

  @override
  Future<FileEntry?> stat(String rootPath, String relPath) async {
    final file = File(p.join(rootPath, relPath));
    if (!await file.exists()) return null;
    final stat = await file.stat();
    return FileEntry(
      relPath: relPath.replaceAll('\\', '/'),
      size: stat.size,
      mtime: stat.modified.millisecondsSinceEpoch,
      sha256: '', // filled lazily by hashOnDemand
    );
  }

  @override
  Stream<List<int>> openRead(String rootPath, String relPath,
      [int offset = 0]) {
    final file = File(p.join(rootPath, relPath));
    final raf = file.openRead(offset);
    return raf;
  }

  @override
  Future<void> write(String rootPath, String relPath, List<int> data) async {
    final full = p.join(rootPath, relPath);
    await Directory(p.dirname(full)).create(recursive: true);
    await File(full).writeAsBytes(data, flush: true);
  }

  @override
  Future<void> append(String rootPath, String relPath, List<int> data) async {
    final full = p.join(rootPath, relPath);
    await Directory(p.dirname(full)).create(recursive: true);
    final f = await File(full).open(mode: FileMode.writeOnlyAppend);
    try {
      await f.writeFrom(data);
    } finally {
      await f.close();
    }
  }

  @override
  Future<bool> delete(String rootPath, String relPath) async {
    final file = File(p.join(rootPath, relPath));
    if (await file.exists()) {
      await file.delete();
      return true;
    }
    return false;
  }

  @override
  Future<String> moveToVault(String rootPath, String relPath) async {
    final relDir = p.dirname(relPath); // '.' when relPath has no directory
    final vaultDir = p.join(rootPath, '.syncversions', relDir);
    await Directory(vaultDir).create(recursive: true);
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final base = p.basenameWithoutExtension(relPath);
    final ext = p.extension(relPath);
    final destName = '$base.$stamp$ext';
    final dest = p.join(vaultDir, destName);
    final src = p.join(rootPath, relPath);
    await File(src).rename(dest);
    final vaultRelDir =
        relDir == '.' ? '.syncversions' : p.join('.syncversions', relDir);
    return p.join(vaultRelDir, destName);
  }
}

/// Compute the SHA-256 of a file. Used by the scanner when hashing files.
Future<String> hashFile(
    FileSystemAccess fs, String rootPath, String relPath) async {
  final digest = await sha256.bind(fs.openRead(rootPath, relPath)).first;
  return digest.toString();
}
