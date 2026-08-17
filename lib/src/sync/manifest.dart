import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../core/relative_path.dart';

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
    relPath = requireSyncableRelativePath(relPath);
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

/// Optional event source for filesystems that can report tree changes without
/// recursively enumerating the tree. Events are coarse hints; reconciliation
/// remains the authoritative source of sync state.
abstract interface class FileSystemChangeSource {
  Stream<void> changesFor(String rootPath);

  Future<void> startWatching(String rootPath);

  Future<void> stopWatching(String rootPath);
}

abstract interface class BlockFileReader {
  Future<Uint8List> readBlock(
    String rootPath,
    String relPath,
    int offset,
    int length,
  );
}

Future<Uint8List> readFileBlock(
  FileSystemAccess fs,
  String rootPath,
  String relPath,
  int offset,
  int length,
) async {
  final blockReader = fs;
  if (blockReader is BlockFileReader) {
    return (blockReader as BlockFileReader)
        .readBlock(rootPath, relPath, offset, length);
  }
  final out = BytesBuilder(copy: false);
  var remaining = length;
  await for (final chunk in fs.openRead(rootPath, relPath, offset)) {
    if (remaining <= 0) break;
    if (chunk.length <= remaining) {
      out.add(chunk);
      remaining -= chunk.length;
    } else {
      out.add(chunk.sublist(0, remaining));
      remaining = 0;
    }
    if (remaining == 0) break;
  }
  return out.takeBytes();
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
class LocalFileSystemAccess
    implements FileSystemAccess, BlockFileReader, TemporaryFileFinalizer {
  const LocalFileSystemAccess();

  @override
  bool get isAndroidSAF => false;

  @override
  Future<List<String>> listFiles(String rootPath) async {
    final root = Directory(_canonicalRoot(rootPath));
    if (!await root.exists()) return [];
    final result = <String>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: root.path);
      // Skip our own state dir and hidden versioning vault.
      if (rel.startsWith('.syncstate') || rel.startsWith('.syncversions')) {
        continue;
      }
      result.add(rel.replaceAll('\\', '/'));
    }
    return result;
  }

  /// Enumerate and stat in one traversal, avoiding a second exists/stat pass.
  Future<List<FileEntry>> listFilesWithStat(String rootPath) async {
    final root = Directory(_canonicalRoot(rootPath));
    if (!await root.exists()) return const <FileEntry>[];
    final result = <FileEntry>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel =
          p.relative(entity.path, from: root.path).replaceAll('\\', '/');
      if (rel.startsWith('.syncstate/') ||
          rel.startsWith('.syncversions/') ||
          rel.endsWith('.syncpart')) {
        continue;
      }
      final stat = await entity.stat();
      result.add(FileEntry(
        relPath: rel,
        size: stat.size,
        mtime: stat.modified.millisecondsSinceEpoch,
        sha256: '',
      ));
    }
    return result;
  }

  @override
  Future<FileEntry?> stat(String rootPath, String relPath) async {
    relPath = requireSafeRelativePath(relPath);
    final file = File(_containedPath(rootPath, relPath));
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
    relPath = requireSafeRelativePath(relPath);
    final file = File(_containedPath(rootPath, relPath));
    final raf = file.openRead(offset);
    return raf;
  }

  @override
  Future<Uint8List> readBlock(
    String rootPath,
    String relPath,
    int offset,
    int length,
  ) async {
    relPath = requireSafeRelativePath(relPath);
    final file = await File(_containedPath(rootPath, relPath)).open();
    try {
      await file.setPosition(offset);
      return await file.read(length);
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> write(String rootPath, String relPath, List<int> data) async {
    relPath = requireSafeRelativePath(relPath);
    final full = _containedPath(rootPath, relPath);
    await Directory(p.dirname(full)).create(recursive: true);
    await File(full).writeAsBytes(data, flush: true);
  }

  @override
  Future<void> append(String rootPath, String relPath, List<int> data) async {
    relPath = requireSafeRelativePath(relPath);
    final full = _containedPath(rootPath, relPath);
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
    relPath = requireSafeRelativePath(relPath);
    final file = File(_containedPath(rootPath, relPath));
    if (await file.exists()) {
      await file.delete();
      return true;
    }
    return false;
  }

  @override
  Future<String> moveToVault(String rootPath, String relPath) async {
    relPath = requireSyncableRelativePath(relPath);
    final relDir = p.dirname(relPath); // '.' when relPath has no directory
    final vaultRelDir =
        relDir == '.' ? '.syncversions' : p.join('.syncversions', relDir);
    final vaultDir = _containedPath(rootPath, vaultRelDir);
    await Directory(vaultDir).create(recursive: true);
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final base = p.basenameWithoutExtension(relPath);
    final ext = p.extension(relPath);
    final destName = '$base.$stamp$ext';
    final dest = _containedPath(rootPath, p.join(vaultRelDir, destName));
    final src = _containedPath(rootPath, relPath);
    await File(src).rename(dest);
    return p.join(vaultRelDir, destName);
  }

  @override
  Future<void> replaceFromTemporary(
    String rootPath,
    String temporaryRelPath,
    String destinationRelPath,
  ) async {
    temporaryRelPath = requireSafeRelativePath(temporaryRelPath);
    destinationRelPath = requireSyncableRelativePath(destinationRelPath);
    final source = File(_containedPath(rootPath, temporaryRelPath));
    final destination = _containedPath(rootPath, destinationRelPath);
    await Directory(p.dirname(destination)).create(recursive: true);
    final existing = File(destination);
    if (await existing.exists()) await existing.delete();
    Object? lastError;
    for (var attempt = 0; attempt < 12; attempt++) {
      try {
        await source.rename(destination);
        if (!await File(destination).exists() || await source.exists()) {
          throw FileSystemException(
            'Temporary file rename was not visible after completion',
            destination,
          );
        }
        return;
      } catch (e) {
        lastError = e;
        if (attempt == 11) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    throw lastError!;
  }
}

String _canonicalRoot(String rootPath) {
  final absolute = p.normalize(p.absolute(rootPath));
  final root = Directory(absolute);
  return root.existsSync()
      ? p.normalize(root.resolveSymbolicLinksSync())
      : absolute;
}

String _containedPath(String rootPath, String relPath) {
  relPath = requireSafeRelativePath(relPath);
  final root = _canonicalRoot(rootPath);
  final candidate = p.normalize(p.join(root, relPath));
  if (!p.isWithin(root, candidate)) {
    throw FileSystemException('Path escapes the selected sync root', candidate);
  }

  var current = root;
  for (final segment in relPath.replaceAll('\\', '/').split('/')) {
    current = p.join(current, segment);
    if (FileSystemEntity.typeSync(current, followLinks: false) ==
        FileSystemEntityType.link) {
      throw FileSystemException(
        'Symbolic links and junctions are not valid sync paths',
        current,
      );
    }
  }
  return candidate;
}

String resolveLocalContainedPath(String rootPath, String relPath) =>
    _containedPath(rootPath, relPath);

/// Compute the SHA-256 of a file. Used by the scanner when hashing files.
Future<String> hashFile(
    FileSystemAccess fs, String rootPath, String relPath) async {
  final digest = await sha256.bind(fs.openRead(rootPath, relPath)).first;
  return digest.toString();
}
