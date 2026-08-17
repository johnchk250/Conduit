import 'dart:io';

/// Checks if a given path should be ignored by scanners, watchers, and indexing.
bool isIgnoredSyncPath(String path) {
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

/// Safely renames/moves [source] to [destination], handling Windows file locking,
/// target collisions, case-only renames, and transient sharing violations.
Future<void> safeAtomicRename(
  File source,
  File destination, {
  int maxRetries = 6,
  Duration initialDelay = const Duration(milliseconds: 50),
}) async {
  final destDir = destination.parent;
  if (!await destDir.exists()) {
    await destDir.create(recursive: true);
  }

  int attempt = 0;
  while (true) {
    try {
      attempt++;

      if (await destination.exists()) {
        final samePathCaseInsensitive =
            source.path.toLowerCase() == destination.path.toLowerCase();

        if (samePathCaseInsensitive && source.path != destination.path) {
          // Case-only rename: NTFS requires moving to an intermediate temporary name
          final tempIntermediate = File(
            '${destination.path}.case_tmp_${DateTime.now().microsecondsSinceEpoch}',
          );
          final tempFile = await source.rename(tempIntermediate.path);
          await tempFile.rename(destination.path);
          return;
        } else {
          // Delete existing destination to prevent Win32 ERROR_ALREADY_EXISTS (183)
          await destination.delete();
        }
      }

      await source.rename(destination.path);
      return;
    } on FileSystemException catch (e) {
      final errorCode = e.osError?.errorCode;
      final isLockOrCollision = Platform.isWindows &&
          (errorCode == 32 || // ERROR_SHARING_VIOLATION
              errorCode == 5 ||  // ERROR_ACCESS_DENIED
              errorCode == 183); // ERROR_ALREADY_EXISTS

      if (!isLockOrCollision || attempt >= maxRetries) {
        rethrow;
      }

      // Linear backoff to allow background indexers/antivirus to release handles
      await Future.delayed(initialDelay * attempt);
    }
  }
}
