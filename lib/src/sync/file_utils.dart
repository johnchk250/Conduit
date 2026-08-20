import 'dart:io';

/// Safely checks if a file/path/entity should be excluded from sync and indexing.
bool isIgnoredSyncPath(dynamic entity) {
  if (entity == null) return false;
  String? path;
  if (entity is String) {
    path = entity;
  } else if (entity is FileSystemEntity) {
    path = entity.path;
  } else {
    final dynamic value = entity;
    try {
      final candidate = value.path;
      if (candidate is String) path = candidate;
    } catch (_) {}
    if (path == null) {
      try {
        final candidate = value.relativePath;
        if (candidate is String) path = candidate;
      } catch (_) {}
    }
    if (path == null) {
      try {
        final candidate = value.relPath;
        if (candidate is String) path = candidate;
      } catch (_) {}
    }
  }

  if (path == null) return false;
  final normalized = path.replaceAll('\\', '/');
  final segments = normalized.split('/');
  final fileName = segments.isNotEmpty ? segments.last : normalized;

  if (fileName.endsWith('.syncpart') ||
      fileName.endsWith('.tmp') ||
      fileName.startsWith('.synctemp')) {
    return true;
  }

  for (final segment in segments) {
    if (segment == '.conduit' || segment == '.syncversions') {
      return true;
    }
  }

  return false;
}

/// Safely renames [source] to [destination], handling Windows file locking,
/// target collisions, case-only renames, and transient sharing violations.
Future<void> safeAtomicRename(
  dynamic source,
  dynamic destination, {
  int maxRetries = 6,
  Duration initialDelay = const Duration(milliseconds: 50),
}) async {
  final srcFile = source is File ? source : File(source.toString());
  final dstFile =
      destination is File ? destination : File(destination.toString());

  final destDir = dstFile.parent;
  if (!await destDir.exists()) {
    await destDir.create(recursive: true);
  }

  int attempt = 0;
  while (true) {
    try {
      attempt++;

      if (await dstFile.exists()) {
        final samePathCaseInsensitive =
            srcFile.path.toLowerCase() == dstFile.path.toLowerCase();

        if (samePathCaseInsensitive && srcFile.path != dstFile.path) {
          // Case-only rename: NTFS requires moving to an intermediate temporary name
          final tempIntermediate = File(
            '${dstFile.path}.case_tmp_${DateTime.now().microsecondsSinceEpoch}',
          );
          final tempFile = await srcFile.rename(tempIntermediate.path);
          await tempFile.rename(dstFile.path);
          return;
        } else {
          // Delete existing destination to prevent Win32 ERROR_ALREADY_EXISTS (183)
          await dstFile.delete();
        }
      }

      await srcFile.rename(dstFile.path);
      return;
    } on FileSystemException catch (e) {
      final errorCode = e.osError?.errorCode;
      final isLockOrCollision = Platform.isWindows &&
          (errorCode == 32 || errorCode == 5 || errorCode == 183);

      if (!isLockOrCollision || attempt >= maxRetries) {
        rethrow;
      }

      await Future.delayed(initialDelay * attempt);
    }
  }
}
