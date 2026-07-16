import 'dart:async';

import 'manifest.dart';

/// A platform-agnostic change watcher for a single sync folder.
///
/// - Windows: polls the directory contents every [interval] as a portable
///   fallback. (ReadDirectoryChangesW is available but polls work fine and
///   avoid FFI complexity for v1.)
/// - Android: the sync folder is a SAF `content://` tree URI that `dart:io`
///   CANNOT enumerate (the legacy `Directory.list()` path threw and was
///   silently swallowed, so the watcher NEVER emitted — Bug #7). Routing every
///   observation through the injected [FileSystemAccess] (the same SAF-aware
///   abstraction the scanner already uses) makes the cheap poll work on a
///   `content://` URI identically to a real path.
///
/// Emits a (debounced) unit signal whenever a change is detected. The sync
/// engine then re-scans and diffs. The contract is deliberately "something
/// changed" — no details — so the enumeration backend can be swapped without
/// touching the rest of the engine.
class FolderWatcher {
  FolderWatcher({
    required this.fs,
    required this.rootPath,
    this.interval = const Duration(seconds: 4),
    this.debounce = const Duration(milliseconds: 800),
    this.batchListWithStat,
  }) : _currentInterval = interval;

  /// Filesystem backend. On Android this is [SafFileSystemAccess] (so the poll
  /// works over the `content://` tree URI); elsewhere [LocalFileSystemAccess].
  /// Required — without it the watcher cannot see a SAF folder (Bug #7).
  final FileSystemAccess fs;
  final String rootPath;
  final Duration interval;
  final Duration debounce;

  /// Optional fast-path lister (Roadmap Phase 0.6 — battery). When supplied,
  /// [_computeSignature] uses this single batched metadata fetch instead of
  /// [FileSystemAccess.listFiles] + one [FileSystemAccess.stat] call per
  /// file. This poll runs every [interval] (4s while a peer is connected —
  /// see [setInterval]), so on Android the per-file stat loop meant several
  /// SAF ContentResolver round trips per file, every 4 seconds, scaling with
  /// folder size. On Android this is wired to
  /// [SafFileSystemAccess.listFilesWithStat] (one query per directory); null
  /// everywhere else, which preserves the exact original per-file loop.
  final Future<List<FileEntry>> Function(String rootPath)? batchListWithStat;

  /// The live poll cadence. Starts equal to [interval]; the engine stretches
  /// it via [setInterval] when no peer is connected (battery backoff) and
  /// restores it on connect.
  Duration _currentInterval;

  Timer? _timer;
  Timer? _debounceTimer;
  final _controller = StreamController<void>.broadcast();
  int _lastSignature = 0;
  bool _scanInProgress = false;

  Stream<void> get changes => _controller.stream;
  bool get isRunning => _timer != null;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(_currentInterval, (_) => _scan());
    _scan(); // establish baseline
  }

  /// Change the poll cadence at runtime (Roadmap Phase 0.2 — battery backoff).
  ///
  /// When no peer is connected there is nothing to sync a detected change
  /// *toward*, so the engine stretches the interval (e.g. 4s→30s), cutting SAF
  /// IPC ~8× in the common offline state. The moment a peer connects the
  /// engine restores the snappy interval so a real edit is caught quickly.
  ///
  /// Idempotent: a no-op if the interval is unchanged. Restarting the periodic
  /// timer reschedules the next tick from now (Timer.periodic has no reschedule
  /// API), which is the desired behaviour — a freshly-restored fast interval
  /// fires soon rather than waiting out the remainder of a slow one. The
  /// debounce window and last-signature baseline are preserved, so a backoff
  /// change never emits a spurious change signal.
  void setInterval(Duration newInterval) {
    if (newInterval == _currentInterval) return;
    _currentInterval = newInterval;
    final running = _timer;
    if (running == null)
      return; // not started — start() will pick up the new value
    running.cancel();
    _timer = Timer.periodic(newInterval, (_) => _scan());
    _scan(); // Trigger immediate scan to capture pending changes instantly
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    await _controller.close();
  }

  Future<void> _scan() async {
    if (_scanInProgress) return;
    _scanInProgress = true;
    try {
      final sig = await _computeSignature();
      if (sig != _lastSignature && _lastSignature != 0) {
        // something changed — debounce so we coalesce bursts of writes.
        _debounceTimer?.cancel();
        _debounceTimer = Timer(debounce, () {
          _controller.add(null);
        });
      }
      _lastSignature = sig;
    } catch (_) {
      // directory might be briefly unavailable — skip this tick. (This is also
      // the path a SAF permission revocation takes: listFiles throws and we
      // hold the last good signature until access returns.)
    } finally {
      _scanInProgress = false;
    }
  }

  /// Cheap signature: total file count + sum of sizes + newest mtime.
  /// Changes when files are added/removed/resized/modified.
  ///
  /// Goes through [FileSystemAccess] (not `dart:io`) so it works over a SAF
  /// `content://` tree URI on Android — the whole point of the Bug #7 fix.
  /// A missing/empty folder yields 0, which the caller treats as "no baseline
  /// yet" on the first tick and never false-emits.
  Future<int> _computeSignature() async {
    int count = 0;
    int size = 0;
    int newest = 0;

    if (batchListWithStat != null) {
      final entries = await batchListWithStat!(rootPath);
      for (final e in entries) {
        if (_isInternalArtefact(e.relPath)) continue;
        count += 1;
        size += e.size;
        if (e.mtime > newest) newest = e.mtime;
      }
      return count * 1000003 + size + newest;
    }

    final files = await fs.listFiles(rootPath);
    for (final rel in files) {
      // Skip our own metadata artefacts (kept in sync with the scanner's
      // _isInternalArtefact filter so a partial download or a vault write
      // doesn't trigger a spurious change signal).
      if (_isInternalArtefact(rel)) continue;
      count += 1;
      try {
        final st = await fs.stat(rootPath, rel);
        if (st == null) continue; // raced away between list and stat
        size += st.size;
        if (st.mtime > newest) newest = st.mtime;
      } catch (_) {}
    }
    // Combine into a single 63-bit int (good enough for change detection).
    return count * 1000003 + size + newest;
  }

  /// Same filter as [IndexScanner._isInternalArtefact] — kept local (rather
  /// than shared) so this file has no import on scanner.dart, matching the
  /// existing minimal-dependency style of this class.
  static bool _isInternalArtefact(String rel) {
    final norm = rel.replaceAll('\\', '/');
    return norm.startsWith('.syncstate/') ||
        norm.startsWith('.syncversions/') ||
        norm.endsWith('.syncpart');
  }
}
