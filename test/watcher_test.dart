import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/src/sync/manifest.dart';
import 'package:conduit/src/sync/watcher.dart';

/// Regression tests for Bug #7: the phone's change-watcher enumerated the sync
/// folder with raw `dart:io` `Directory.list()`, which throws on an Android
/// SAF `content://` tree URI. The throw was silently swallowed, so the watcher
/// NEVER emitted a change and the phone detected no local edits/deletes at all
/// until some unrelated wire event kicked a reconcile.
///
/// The fix routes the watcher's signature computation through the injected
/// [FileSystemAccess] (the same SAF-aware abstraction the scanner uses), so the
/// poll works on a `content://` URI identically to a real path. These tests pin
/// that:
///   - the watcher emits when a SAF-backed FS changes, and
///   - it never touches `dart:io` (a SAF root string is opaque to it).
void main() {
  test('FolderWatcher emits on a SAF-backed (content://) filesystem change',
      () async {
    // A SAF-style root path: the raw string `dart:io` cannot enumerate. The
    // watcher must observe it solely through the FakeFs backend.
    const root = 'content://com.android.externalstorage.documents/tree/primary'
        '%3ATestM';
    final fs = _SafLikeFs({'a.txt': _b('hello')});

    final emitted = <Null>[];
    final w = FolderWatcher(
      fs: fs,
      rootPath: root,
      interval: const Duration(milliseconds: 30),
      debounce: const Duration(milliseconds: 20),
    );
    final sub = w.changes.listen((_) => emitted.add(null));
    w.start();
    // Establish baseline across a couple of ticks.
    await _settle();

    // Make a local change (e.g. the user edited a file via a file manager).
    fs.files['a.txt'] = _b('hello world');
    fs._bumpMtime('a.txt');

    await _settle();
    await sub.cancel();
    await w.stop();

    expect(emitted, isNotEmpty,
        reason: 'Bug #7: the watcher must emit a change signal when a SAF-'
            'backed folder changes; the old dart:io path threw and emitted '
            'nothing.');
  });

  test('FolderWatcher does NOT emit on an unchanged SAF folder (no false fire)',
      () async {
    const root = 'content://tree/primary%3AStill';
    final fs = _SafLikeFs({'a.txt': _b('hello'), 'b.txt': _b('world')});
    final emitted = <Null>[];
    final w = FolderWatcher(
      fs: fs,
      rootPath: root,
      interval: const Duration(milliseconds: 30),
      debounce: const Duration(milliseconds: 20),
    );
    final sub = w.changes.listen((_) => emitted.add(null));
    w.start();
    await _settle(); // baseline
    emitted.clear();
    await _settle(); // unchanged
    await sub.cancel();
    await w.stop();
    expect(emitted, isEmpty,
        reason: 'a stable folder must not produce a change signal');
  });

  test('FolderWatcher takes a FileSystemAccess (the constructor fix)', () {
    // Compile-time + existence check: the constructor REQUIRES `fs`. The old
    // constructor took only rootPath and enumerated via dart:io internally.
    const fs = LocalFileSystemAccess();
    final w = FolderWatcher(fs: fs, rootPath: '.');
    expect(w.isRunning, isFalse);
  });
}

Future<void> _settle([Duration d = const Duration(milliseconds: 160)]) async {
  // A few event-loop turns past the debounce + one interval.
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(d ~/ 6);
  }
}

List<int> _b(String s) => s.codeUnits;

/// A FileSystemAccess whose `rootPath` is treated as an opaque SAF tree URI
/// (mimicking `SafFileSystemAccess`): [listFiles] is backed by an in-memory map
/// and works regardless of the path string. This is the shape the real Android
/// backend exposes — the whole point of Bug #7 is that the watcher must use
/// THIS surface, not dart:io.
class _SafLikeFs implements FileSystemAccess {
  _SafLikeFs(this.files);
  final Map<String, List<int>> files;
  final _mtimes = <String, int>{};

  void _bumpMtime(String rel) => _mtimes[rel] = (_mtimes[rel] ?? 1) + 1;

  @override
  bool get isAndroidSAF => true;

  @override
  Future<List<String>> listFiles(String rootPath) async =>
      files.keys.toList(growable: false);

  @override
  Future<FileEntry?> stat(String rootPath, String relPath) async {
    final data = files[relPath];
    if (data == null) return null;
    return FileEntry(
        relPath: relPath,
        size: data.length,
        mtime: _mtimes[relPath] ?? 1,
        sha256: '');
  }

  @override
  Stream<List<int>> openRead(String rootPath, String relPath,
      [int offset = 0]) async* {
    final data = files[relPath];
    if (data == null) return;
    yield data.sublist(offset);
  }

  @override
  Future<void> write(String rootPath, String relPath, List<int> data) async {
    files[relPath] = data;
    _bumpMtime(relPath);
  }

  @override
  Future<void> append(String rootPath, String relPath, List<int> data) async {
    files[relPath] = [...?files[relPath], ...data];
    _bumpMtime(relPath);
  }

  @override
  Future<bool> delete(String rootPath, String relPath) async =>
      files.remove(relPath) != null;

  @override
  Future<String> moveToVault(String rootPath, String relPath) async =>
      throw UnsupportedError('not used by the watcher');
}
