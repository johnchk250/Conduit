import 'dart:async';
import 'dart:io';

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
  /// file. Earlier Android builds ran this traversal every few seconds; the
  /// current event-led policy uses provider notifications and a long fallback
  /// interval instead. On Android this is wired to
  /// [SafFileSystemAccess.listFilesWithStat] (one query per directory); null
  /// everywhere else, which preserves the exact original per-file loop.
  final Future<List<FileEntry>> Function(String rootPath)? batchListWithStat;

  /// The live poll cadence. Starts equal to [interval]; the engine stretches
  /// it via [setInterval] when no peer is connected (battery backoff) and
  /// restores it on connect.
  Duration _currentInterval;

  Timer? _timer;
  Timer? _debounceTimer;
  StreamSubscription<FileSystemEvent>? _nativeEvents;
  StreamSubscription<void>? _providerEvents;
  final _controller = StreamController<void>.broadcast();
  int _lastSignature = 0;
  bool _hasBaseline = false;
  bool _scanInProgress = false;

  Stream<void> get changes => _controller.stream;
  bool get isRunning => _timer != null;

  void start() {
    if (_timer != null) return;
    _startNativeEvents();
    _schedulePoller();
    if (!_hasBaseline) _scan();
  }

  void seedSignature(int signature) {
    _lastSignature = signature;
    _hasBaseline = true;
  }

  /// Change the poll cadence at runtime (Roadmap Phase 0.2 — battery backoff).
  ///
  /// When no peer is connected there is nothing to sync a detected change
  /// *toward*, so the engine stretches the interval. On Android, provider
  /// change notifications are the primary trigger and the poll is only a
  /// long-interval correctness fallback; this avoids repeatedly traversing a
  /// SAF tree merely because the connection state changed.
  ///
  /// Idempotent: a no-op if the interval is unchanged. Restarting the periodic
  /// timer reschedules the next tick from now (Timer.periodic has no reschedule
  /// API), which is the desired behaviour. Local filesystems also get an
  /// immediate catch-up scan when speeding up; Android SAF relies on the
  /// engine's reconnect reconcile to avoid a duplicate tree traversal. The
  /// debounce window and last-signature baseline are preserved, so a cadence
  /// change never emits a spurious change signal.
  void setInterval(Duration newInterval) {
    if (newInterval == _currentInterval) return;
    final previousInterval = _currentInterval;
    _currentInterval = newInterval;
    final running = _timer;
    if (running == null) {
      return; // not started — start() will pick up the new value
    }
    running.cancel();
    _schedulePoller();
    // A local-filesystem reconnect (slow→fast) should immediately catch edits
    // accumulated while offline. Android SAF reconnects already run a full
    // engine reconcile and provider events remain armed, so firing a second
    // tree traversal here only duplicates expensive ContentResolver work. A
    // disconnect or battery-saver transition must never trigger a scan.
    if (newInterval < previousInterval && !fs.isAndroidSAF) {
      unawaited(_scan());
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    await _nativeEvents?.cancel();
    _nativeEvents = null;
    await _providerEvents?.cancel();
    _providerEvents = null;
    final source = fs;
    if (source is FileSystemChangeSource) {
      final changeSource = source as FileSystemChangeSource;
      try {
        await changeSource.stopWatching(rootPath);
      } catch (_) {}
    }
    await _controller.close();
  }

  Future<void> _scan() async {
    if (_scanInProgress) return;
    _scanInProgress = true;
    try {
      final sig = await _computeSignature();
      if (_hasBaseline && sig != _lastSignature) {
        // something changed — debounce so we coalesce bursts of writes.
        _signalChange();
      }
      _lastSignature = sig;
      _hasBaseline = true;
    } catch (_) {
      // directory might be briefly unavailable — skip this tick. (This is also
      // the path a SAF permission revocation takes: listFiles throws and we
      // hold the last good signature until access returns.)
    } finally {
      _scanInProgress = false;
    }
  }

  void _schedulePoller() {
    final interval =
        _nativeEvents != null && _currentInterval < const Duration(seconds: 30)
            ? const Duration(seconds: 30)
            : _currentInterval;
    _timer = Timer.periodic(interval, (_) => _scan());
  }

  void _startNativeEvents() {
    final source = fs;
    if (source is FileSystemChangeSource) {
      final changeSource = source as FileSystemChangeSource;
      _providerEvents = changeSource.changesFor(rootPath).listen((_) {
        _signalChange();
      });
      unawaited(changeSource.startWatching(rootPath).catchError((_) {
        // The periodic signature scan remains the correctness fallback for
        // document providers that do not support observation.
      }));
      return;
    }
    if (fs.isAndroidSAF) return;
    try {
      final root = Directory(rootPath);
      if (!root.existsSync()) return;
      _nativeEvents = root.watch(recursive: true).listen((event) {
        final rel = event.path
            .substring(rootPath.length)
            .replaceFirst(RegExp(r'^[\\/]'), '')
            .replaceAll('\\', '/');
        if (!_isInternalArtefact(rel)) _signalChange();
      }, onError: (_) {
        _nativeEvents = null;
      });
    } catch (_) {
      _nativeEvents = null;
    }
  }

  void _signalChange() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () {
      if (!_controller.isClosed) _controller.add(null);
    });
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
