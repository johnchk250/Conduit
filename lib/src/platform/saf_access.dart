import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../diag.dart';
import '../sync/manifest.dart';

const _chPick = MethodChannel('conduit/saf_pick_tree');
const _chSaf = MethodChannel('conduit/saf');

/// Android-only FileSystemAccess backed by the Storage Access Framework.
///
/// The [rootPath] passed in by a folder pair is the persisted tree URI string
/// (e.g. content://com.android.externalstorage.documents/tree/primary%3A...).
/// We resolve relative paths within it via the Kotlin SafOps handler.
class SafFileSystemAccess implements FileSystemAccess, TemporaryFileFinalizer {
  const SafFileSystemAccess();

  @override
  bool get isAndroidSAF => true;

  /// Launch the system folder picker. Returns the granted tree URI, or null
  /// if the user cancelled. The permission is persisted on the Kotlin side.
  static Future<String?> pickTree({String? initialHint}) async {
    try {
      return await _chPick.invokeMethod<String>(
        'pick',
        {if (initialHint != null) 'initialHint': initialHint},
      );
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<List<String>> listFiles(String rootPath) async {
    final res = await _chSaf.invokeMethod('listFiles', {'treeUri': rootPath});
    return (res as List).cast<String>();
  }

  @override
  Future<FileEntry?> stat(String rootPath, String relPath) async {
    final res = await _chSaf.invokeMethod('stat', {
      'treeUri': rootPath,
      'relPath': relPath,
    });
    if (res == null) return null;
    final m = (res as Map).cast<String, dynamic>();
    return FileEntry(
      relPath: relPath,
      size: (m['size'] as num).toInt(),
      mtime: (m['mtime'] as num).toInt(),
      sha256: '',
    );
  }

  /// Battery fix (Roadmap Phase 0.6): every file's path+size+mtime in ONE
  /// method-channel round trip, backed by one ContentResolver query per
  /// directory on the Kotlin side (see SafOps.listFilesWithStat), instead of
  /// [listFiles] followed by one [stat] call per file. [FolderWatcher] and
  /// [IndexScanner] use this when it's supplied to them; every other caller
  /// (writes, deletes, one-off lookups) is unaffected and keeps using
  /// [listFiles]/[stat] directly.
  Future<List<FileEntry>> listFilesWithStat(String rootPath) async {
    final res =
        await _chSaf.invokeMethod('listFilesWithStat', {'treeUri': rootPath});
    final list = (res as List).cast<Map>();
    return list.map((raw) {
      final m = raw.cast<String, dynamic>();
      return FileEntry(
        relPath: m['path'] as String,
        size: (m['size'] as num).toInt(),
        mtime: (m['mtime'] as num).toInt(),
        sha256: '',
      );
    }).toList();
  }

  Future<String> hashFile(String rootPath, String relPath) async {
    return (await _chSaf.invokeMethod<String>('hashFile', {
      'treeUri': rootPath,
      'relPath': relPath,
    }))!;
  }

  @override
  Stream<List<int>> openRead(String rootPath, String relPath,
      [int offset = 0]) async* {
    // SAF gives us a whole-file byte buffer; we slice as requested.
    final bytes = await _chSaf.invokeMethod('read', {
      'treeUri': rootPath,
      'relPath': relPath,
      'offset': offset,
    }) as Uint8List;
    yield bytes;
  }

  @override
  Future<void> write(String rootPath, String relPath, List<int> data) async {
    await _chSaf.invokeMethod('write', {
      'treeUri': rootPath,
      'relPath': relPath,
      'data': data is Uint8List ? data : Uint8List.fromList(data),
    });
  }

  @override
  Future<void> append(String rootPath, String relPath, List<int> data) async {
    await _chSaf.invokeMethod('append', {
      'treeUri': rootPath,
      'relPath': relPath,
      'data': data is Uint8List ? data : Uint8List.fromList(data),
    });
  }

  @override
  Future<void> replaceFromTemporary(
    String rootPath,
    String temporaryRelPath,
    String destinationRelPath,
  ) async {
    await _chSaf.invokeMethod('replaceFromTemporary', {
      'treeUri': rootPath,
      'temporaryRelPath': temporaryRelPath,
      'destinationRelPath': destinationRelPath,
    });
  }

  @override
  Future<bool> delete(String rootPath, String relPath) async {
    final res = await _chSaf.invokeMethod('delete', {
      'treeUri': rootPath,
      'relPath': relPath,
    });
    return res as bool;
  }

  @override
  Future<String> moveToVault(String rootPath, String relPath) async {
    final res = await _chSaf.invokeMethod('moveToVault', {
      'treeUri': rootPath,
      'relPath': relPath,
    });
    return res as String;
  }

  /// Open a received file in the system viewer (used by notification tap).
  ///
  /// [treeUri] is the SAF tree root URI (the persisted tree the user picked).
  /// [relPath] is the file's relative path within that tree (e.g. "photo.jpg").
  /// The native side resolves the document URI, determines the MIME type, and
  /// fires an [Intent.ACTION_VIEW] so the OS opens the file in the correct app.
  /// Best-effort — errors are swallowed so a failed open never crashes the app.
  static Future<void> openFile(String treeUri, String relPath) async {
    try {
      await _chSaf.invokeMethod<void>('openFile', {
        'treeUri': treeUri,
        'relPath': relPath,
      });
    } catch (e) {
      // Best-effort: no handler for this MIME type, or the file was deleted.
      // TEMP diagnostic logging (2026-07-14): this was a bare `catch (_) {}`,
      // which is exactly why the MIME-type bug (every file resolving to
      // application/octet-stream, so no app could open it) was invisible —
      // the native "no_handler" error was thrown and immediately discarded.
      // Logging it now so any future failure here is visible instead of silent.
      Diag.log('open_file_failed', fields: {
        'treeUri': treeUri,
        'relPath': relPath,
        'error': e.toString(),
      });
    }
  }
}

/// Platform-aware factory: returns SAF access on Android, local access elsewhere.
FileSystemAccess platformFileSystemAccess() {
  // Decided at runtime in the engine bootstrap (see app_state.dart); this
  // helper exists for symmetry.
  return const LocalFileSystemAccess();
}
