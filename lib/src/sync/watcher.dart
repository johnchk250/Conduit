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
    this.minimumSignalInterval = Duration.zero,
    this.fallbackSignalsWithoutScan = false,
    this.batchListWithStat,
  }) : _currentInterval = interval;

  /// Filesystem backend. On Android this is [SafFileSystemAccess] (so the poll
  /// works over the `content://` tree URI); elsewhere [LocalFileSystemAccess].
  /// Required — without it the watcher cannot see a SAF folder (Bug #7).
  final FileSystemAccess fs;
  final String rootPath;
  final Duration interval;
  final Duration debounce;

  /// Minimum spacing between emitted change hints.
  ///
  /// Android document providers often send several notifications for one
  /// logical save (temporary file, rename, metadata update, WAL update, and so
  /// on). [debounce] coalesces a short burst; this additional floor prevents a
  /// chatty provider from triggering repeated full-tree reconciles while an app
  /// is continuously writing. The next hint is delayed, never discarded.
  /// Local filesystem watchers leave this at zero for immediate behaviour.
  final Duration minimumSignalInterval;

  /// When true, a fallback timer emits a change hint directly instead of first
  /// traversing the tree to compute a signature.
  ///
  /// This is the efficient Android SAF shape: the engine's reconcile is the
  /// authoritative scan, so doing a watcher signature traversal immediately
  /// before it would enumerate the same provider tree twice whenever drift is
  /// found. Local filesystems keep signature polling because it is cheap and
  /// avoids unnecessary reconciles when nothing changed.
  final bool fallbackSignalsWithoutScan;

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
  bool _started = false;
  bool _providerEventsEnabled = true;
  bool _providerWatchActive = false;
  Future<void> _providerWatchOperation = Future<void>.value();
  DateTime? _lastSignalAt;

  Stream<void> get changes => _controller.stream;
  bool get isRunning => _started;

  void start() {
    if (_started) return;
    _started = true;
    _startNativeEvents();
    _schedulePoller();
    if (!_hasBaseline) _scan();
  }

  void seedSignature(int signature) {
    _lastSignature = signature;
    _hasBaseline = true;
  }

  /// Enable or disable Android/provider change observation without stopping
  /// the watcher itself.
  ///
  /// A folder whose peer is offline cannot sync anywhere. Disabling its
  /// ContentObserver avoids waking both Conduit and the DocumentsProvider for
  /// every camera/database write during that period. The engine performs a
  /// full catch-up reconcile and re-enables observation when the peer returns.
  /// Native local-filesystem watching is intentionally unaffected.
  void setProviderEventsEnabled(bool enabled) {
    if (_providerEventsEnabled == enabled) return;
    _providerEventsEnabled = enabled;
    if (!_started || fs is! FileSystemChangeSource) return;
    if (!enabled) {
      _debounceTimer?.cancel();
      _debounceTimer = null;
    }
    unawaited(_queueProviderWatchUpdate());
  }

  /// Change the fallback-poll cadence at runtime.
  ///
  /// When no peer is connected there is nothing to sync a detected change
  /// *toward*, so the engine stretches the interval. On Android, provider
  /// change notifications are the primary trigger and the poll is only a
  /// long-interval correctness fallback; this avoids repeatedly traversing a
  /// SAF tree merely because the connection state changed.
  ///
  /// [Duration.zero] disables fallback polling. Conduit pairs this with
  /// [setProviderEventsEnabled] for an Android SAF folder whose peer is offline:
  /// scanning cannot sync anything, and the engine performs an immediate
  /// reconcile when the peer reconnects.
  ///
  /// Idempotent: a no-op if the interval is unchanged. Restarting the periodic
  /// timer reschedules the next tick from now (Timer.periodic has no reschedule
  /// API), which is the desired behaviour. Local filesystems also get an
  /// immediate catch-up scan when polling is re-enabled or made faster;
  /// Android SAF relies on the engine's reconnect reconcile to avoid a
  /// duplicate tree traversal. The debounce window and last-signature baseline
  /// are preserved, so a cadence change never emits a spurious change signal.
  void setInterval(Duration newInterval) {
    if (newInterval == _currentInterval) return;
    final previousInterval = _currentInterval;
    _currentInterval = newInterval;
    if (!_started) {
      return; // not started — start() will pick up the new value
    }
    _timer?.cancel();
    _timer = null;
    _schedulePoller();
    // A local-filesystem reconnect (slow→fast) should immediately catch edits
    // accumulated while offline. Android SAF reconnects already run a full
    // engine reconcile and provider events remain armed, so firing a second
    // tree traversal here only duplicates expensive ContentResolver work. A
    // disconnect or battery-saver transition must never trigger a scan.
    final pollingWasDisabled = previousInterval <= Duration.zero;
    final pollingIsEnabled = newInterval > Duration.zero;
    final spedUp = pollingIsEnabled &&
        (pollingWasDisabled || newInterval < previousInterval);
    if (spedUp && !fs.isAndroidSAF) {
      unawaited(_scan());
    }
  }

  Future<void> stop() async {
    _started = false;
    _timer?.cancel();
    _timer = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    await _nativeEvents?.cancel();
    _nativeEvents = null;
    await _queueProviderWatchUpdate();
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
    if (!_started || _currentInterval <= Duration.zero) {
      _timer = null;
      return;
    }
    final interval =
        _nativeEvents != null && _currentInterval < const Duration(seconds: 30)
            ? const Duration(seconds: 30)
            : _currentInterval;
    _timer = Timer.periodic(interval, (_) {
      if (fallbackSignalsWithoutScan) {
        _signalChange();
      } else {
        _scan();
      }
    });
  }

  void _startNativeEvents() {
    final source = fs;
    if (source is FileSystemChangeSource) {
      unawaited(_queueProviderWatchUpdate());
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

  Future<void> _queueProviderWatchUpdate() {
    _providerWatchOperation = _providerWatchOperation
        .then((_) => _applyProviderWatchState())
        .catchError((Object _) {
      // The long fallback reconcile remains available when a provider does not
      // support observation or its platform channel is temporarily unavailable.
    });
    return _providerWatchOperation;
  }

  Future<void> _applyProviderWatchState() async {
    final source = fs;
    if (source is! FileSystemChangeSource) return;
    final changeSource = source as FileSystemChangeSource;
    final shouldWatch = _started && _providerEventsEnabled;

    if (!shouldWatch) {
      final subscription = _providerEvents;
      _providerEvents = null;
      try {
        await subscription?.cancel();
      } catch (_) {}
      if (!_providerWatchActive) return;
      _providerWatchActive = false;
      try {
        await changeSource.stopWatching(rootPath);
      } catch (_) {}
      return;
    }

    _providerEvents ??= changeSource.changesFor(rootPath).listen((_) {
      if (_started && _providerEventsEnabled) _signalChange();
    });
    if (_providerWatchActive) return;
    try {
      await changeSource.startWatching(rootPath);
      _providerWatchActive = true;
    } catch (_) {
      _providerWatchActive = false;
      // The periodic reconcile remains the correctness fallback for document
      // providers that do not support observation.
    }
  }

  void _signalChange() {
    _debounceTimer?.cancel();
    var delay = debounce;
    final last = _lastSignalAt;
    if (last != null && minimumSignalInterval > Duration.zero) {
      final remaining = minimumSignalInterval - DateTime.now().difference(last);
      if (remaining > delay) delay = remaining;
    }
    if (delay < Duration.zero) delay = Duration.zero;
    _debounceTimer = Timer(delay, () {
      _lastSignalAt = DateTime.now();
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
