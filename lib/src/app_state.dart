import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import 'core/config_store.dart';
import 'core/identity.dart';
import 'clipboard/clipboard_sync.dart';
import 'desktop/commands.dart';
import 'diag.dart';
import 'net/connection_supervisor.dart';
import 'net/bluetooth_bridge.dart';
import 'net/discovery.dart';
import 'net/peer_registry.dart';
import 'net/peer_session.dart';
import 'net/transport.dart';
import 'notifications/notifier.dart';
import 'platform/saf_access.dart';
import 'protocol/wire.dart';
import 'sync/engine.dart';
import 'sync/vault_log.dart';
import 'sync/file_send.dart';
import 'sync/manifest.dart';
import 'sync/sync_preview.dart';
import 'runtime/app_dependencies.dart';
import 'transfers/transfer_receipt.dart';

/// Summary returned by [AppState.syncAllNow].
///
/// A global manual sync is intentionally separate from connection boost: it
/// performs one authoritative reconcile per folder pair, in sequence, without
/// enabling aggressive discovery or holding a wake lock beyond real transfers.
class SyncAllResult {
  const SyncAllResult({
    required this.totalPairs,
    required this.triggeredWithPeer,
    required this.indexedLocally,
    required this.skippedBusy,
    required this.failed,
    this.paused = false,
    this.alreadyRunning = false,
    this.notStarted = false,
  });

  final int totalPairs;
  final int triggeredWithPeer;
  final int indexedLocally;
  final int skippedBusy;
  final int failed;
  final bool paused;
  final bool alreadyRunning;
  final bool notStarted;

  String get message {
    if (notStarted) return 'Conduit is still starting. Try again in a moment.';
    if (alreadyRunning) return 'Sync all is already running.';
    if (paused) return 'Sync is paused. Resume syncing first.';
    if (totalPairs == 0) return 'No folder pairs to sync.';

    final parts = <String>[];
    if (triggeredWithPeer > 0) {
      parts.add('Started sync for $triggeredWithPeer connected folder(s)');
    }
    if (indexedLocally > 0) {
      parts.add('Scanned $indexedLocally offline folder(s); waiting for peer');
    }
    if (skippedBusy > 0) {
      parts.add('$skippedBusy already syncing');
    }
    if (failed > 0) parts.add('$failed failed');
    return parts.isEmpty ? 'Sync all finished.' : '${parts.join(' · ')}.';
  }
}

/// Central app state, exposed to the UI via Provider. Owns:
///   - device identity
///   - config store (folder pairs + paired peers)
///   - LAN discovery
///   - peer connection manager
///   - sync engine
///   - THE shared [PeerConnectionRegistry] (Step 4): single source of truth
///     for "which session is live for peer X", held jointly with the engine.
///
/// Step 3 of the fix plan: invites are surfaced to the UI as STATE
/// ([pendingInvite]), not a broadcast stream event. The UI reads state on
/// every rebuild via `context.watch<AppState>()`; there is no
/// StreamSubscription to attach "in time" or to lose on a rebuild.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState({AppDependencies? dependencies})
      : dependencies = dependencies ?? AppDependencies.production();

  final AppDependencies dependencies;

  late DeviceIdentity _identity;
  late ConfigStore _config;
  late FileSystemAccess _fs;
  late SyncEngine _engine;
  late PeerConnectionManager _connections;
  late PeerConnectionRegistry _registry;
  late ConnectionSupervisor _supervisor;
  Discovery? _discovery;
  BluetoothBridge? _bluetooth;
  final Map<String, DiscoveredPeer> _bluetoothPeers = {};
  String _bluetoothAdapterStatus = 'Bluetooth starting';
  String? _bluetoothAttemptStatus;

  /// Roadmap Phase 2 — clipboard sync. Created in [start] once the registry
  /// and config exist. Lives outside the sync engine; talks to peers over the
  /// same live sessions the engine uses.
  ClipboardSync? _clipboard;
  ClipboardSync? get clipboard => _clipboard;

  /// Roadmap Phase 4 — remote command executor (Windows-only). Null on Android.
  RemoteCommandExecutor? _remoteCmd;

  /// Roadmap Phase 3 — system notification wrapper.
  final _notifier = AppNotifier();

  /// Roadmap Phase 3a — ad-hoc file send / auto-receive handler.
  AdHocFileSend? _adHoc;
  TransferReceiptRepository? _transferReceipts;
  TransferReceiptRepository? get transferReceipts => _transferReceipts;

  // Phase 3d: files shared into Conduit from outside the app that are
  // waiting to be sent (when no peer is connected at share-time, or when
  // multiple peers are connected and the user must pick one).
  List<PendingSharedFile>? _pendingSharedFiles;
  String? _lastTransferBlockReason;

  /// Pending files from an OS-level share/send action. Non-null when there
  /// are files queued that need the user to select a peer before sending.
  List<PendingSharedFile>? get pendingSharedFiles => _pendingSharedFiles;

  /// True when the pending shared-files queue came from an OS share/send action
  /// while exactly one peer was connected. The Send panel uses this to auto-start
  /// the transfer after it has a visible progress UI on screen.
  bool _pendingSharedFilesAutoStart = false;
  bool get pendingSharedFilesAutoStart => _pendingSharedFilesAutoStart;
  String? get lastTransferBlockReason => _lastTransferBlockReason;

  /// Clear the pending shared-files queue (called after they've been sent).
  void clearPendingSharedFiles() {
    _pendingSharedFiles = null;
    _pendingSharedFilesAutoStart = false;
    notifyListeners();
  }

  /// Discovered-peers cache, also exposed to [ConnectionSupervisor] as a
  /// [DiscoveredPeerCache] (read-only view) so it can read last-known peer
  /// addresses without a direct AppState reference (avoids a cycle).
  final _discoveredPeers = _DiscoveredPeerCache();
  final List<SyncEvent> _events = [];
  final Map<String, PairSyncState> _pairStates = {};

  final Map<String, DeviceDashboardState> _dashboardStates = {};
  Map<String, DeviceDashboardState> get dashboardStates => _dashboardStates;

  DeviceDashboardState getOrCreateDashboardState(String deviceId) {
    return _dashboardStates.putIfAbsent(
        deviceId, () => DeviceDashboardState(deviceId: deviceId));
  }

  Timer? _androidStatusTimer;
  Map<String, dynamic>? _lastSentStatus;
  DateTime? _lastFullRefreshTime;
  final Map<String, Completer<String>> _pendingAlertCompleters = {};
  int _alertIdCounter = 0;
  // In-flight outbound connects (guard against parallel dials for one peer).
  final _connectingPeerIds = <String>{};
  final _connectingBluetoothPeerIds = <String>{};
  // The lexically-larger device yields only once per reconnect cycle. Keeping
  // this separate from the in-flight guard prevents every supervisor retry
  // from paying the old multi-second anti-double-dial delay.
  final _autoConnectStaggeredPeerIds = <String>{};
  final Map<String, Timer> _bluetoothDialTimers = <String, Timer>{};
  Timer? _windowsLanUpgradeTimer;

  /// Peers the user has INTENTIONALLY disconnected from via [disconnectPeer].
  /// The [ConnectionSupervisor] and the beacon-driven auto-connect both skip
  /// these, so a user disconnect STAYS disconnected until the user reconnects.
  /// Cleared by any explicit user-initiated connect (pairWithPeer /
  /// connectViaToken), since those signal "I want to be connected again".
  final _suppressedPeerIds = <String>{};

  Timer? _connectionWakeLockRenewal;
  bool _connectionWakeLockHeld = false;
  Timer? _connectionBoostTimer;
  Timer? _connectionBoostRetryTimer;
  DateTime? _connectionBoostUntil;
  Timer? _networkRecoveryTimer;
  final List<Timer> _networkReannounceTimers = <Timer>[];
  bool _networkRecoveryActive = false;
  Timer? _resumeProbeTimer;
  Timer? _highFrequencyUiTimer;
  bool _networkingReady = false;
  bool _supervisorInitialized = false;
  Map<String, dynamic>? _pendingNativeNetworkEvent;
  int? _lastNativeNetworkGeneration;
  String? _lastNativeNetworkEpoch;

  bool get connectionBoostActive {
    final until = _connectionBoostUntil;
    return until != null && dependencies.now().isBefore(until);
  }

  DateTime? get connectionBoostUntil =>
      connectionBoostActive ? _connectionBoostUntil : null;

  /// Roadmap Phase 0.4 (post-audit fix): renews the transfer-tied wake lock
  /// every 45s while a burst is active. The separate connection lock is used
  /// only for bounded reconnect recovery.
  /// Previously a transfer burst only fired one native `acquire` at its start
  /// with no renewal, so any burst longer than the native lock's timeout
  /// silently lost wake-lock protection even without the app being
  /// backgrounded. See [_onTransferState].
  Timer? _transferWakeLockRenewal;

  /// Roadmap Phase 0.6 — battery: mirrors whether the Android SyncService's
  /// MulticastLock is currently requested. The service starts lock-free; a
  /// bounded startup/network/reconnect recovery window explicitly acquires it.
  bool _discoveryLockHeld = false;

  /// Step 3: the current pending invite, surfaced to the UI as STATE. Null
  /// when there is nothing to show. Setting this calls notifyListeners, so
  /// any widget doing `context.watch<AppState>()` re-renders and picks it up
  /// — no subscription lifecycle to manage, no race against rebuilds.
  FolderPairInvite? _pendingInvite;
  FolderPairInvite? get pendingInvite => _pendingInvite;
  final _queuedInvites = <FolderPairInvite>[];

  /// Global manual-sync state surfaced on the Overview quick action. Folder
  /// pairs are reconciled sequentially so one tap cannot launch several
  /// recursive SAF scans against Files by Google at the same time.
  bool _syncAllRunning = false;
  DateTime? _lastSyncAllAt;
  String? _lastSyncAllSummary;

  bool _started = false;

  // Roadmap Phase 4: true while the compact, KDE-Connect-style "send widget"
  // (see SendWidgetScreen) is standing in for the full dashboard shell so a
  // Windows "Send to Conduit" doesn't have to open the whole app just to push
  // one file. Windows-only — the sole place that sets it is
  // [_onIncomingSharedFiles] — so nothing in the full-shell "Send" tab can
  // ever trigger it by accident. AppState deliberately knows nothing about
  // window geometry itself; window_manager calls live in the UI layer
  // alongside the rest of the desktop window plumbing (desktop/tray.dart) —
  // this flag is purely the on/off signal DashboardScreen.build() switches on.
  bool _sendWidgetMode = false;
  String _status = 'Starting…';

  DeviceIdentity get identity => _identity;
  ConfigStore get config => _config;
  FileSystemAccess get fs => _fs;
  SyncEngine get engine => _engine;
  bool get isStarted => _started;
  bool get syncAllRunning => _syncAllRunning;
  DateTime? get lastSyncAllAt => _lastSyncAllAt;
  String? get lastSyncAllSummary => _lastSyncAllSummary;
  bool get sendWidgetMode => _sendWidgetMode;
  String get status => _status;
  List<DiscoveredPeer> get discoveredPeers => <DiscoveredPeer>{
        ..._discoveredPeers.values,
        ..._bluetoothPeers.values.where((candidate) => !_discoveredPeers.values
            .any((lan) => lan.deviceId == candidate.deviceId)),
      }.toList(growable: false);
  List<PairedPeer> get pairedPeers => _config.pairedPeers;
  List<SyncEvent> get events => _engine.eventLog;
  PairSyncState? stateFor(String pairId) => _engine.stateFor(pairId);
  bool get bluetoothEnabled => _config.bluetoothEnabled;
  String get bluetoothStatus {
    for (final peer in _config.pairedPeers) {
      final session = _registry.openSessionFor(peer.deviceId);
      if (session?.isLinkReady == true &&
          session?.transport == ConnectionTransport.bluetooth) {
        return 'Bluetooth connected to ${peer.name}';
      }
    }
    for (final peer in _config.pairedPeers) {
      final session = _registry.openSessionFor(peer.deviceId);
      if (session?.isLinkReady == true &&
          session?.transport == ConnectionTransport.lan) {
        return 'LAN active - Bluetooth remains available as fallback';
      }
    }
    return _bluetoothAttemptStatus ?? _bluetoothAdapterStatus;
  }

  bool get bluetoothStatusHealthy {
    if (_registry.readyPeerIds.isNotEmpty) return true;
    final lower = bluetoothStatus.toLowerCase();
    return lower.contains('ready') || lower.contains('available as fallback');
  }

  bool get bluetoothSupported =>
      _bluetooth?.isSupported ?? (Platform.isAndroid || Platform.isWindows);

  PeerConnectionSnapshot connectionStateFor(String deviceId) {
    final session = _registry.openSessionFor(deviceId);
    if (session?.isLinkReady == true) {
      return PeerConnectionSnapshot(
        phase: PeerConnectionPhase.connected,
        transport: session!.transport,
        latestRttMs: session.latestRttMs,
        missedHeartbeats: session.missedHeartbeats,
      );
    }
    final connecting = session != null ||
        _connectingPeerIds.contains(deviceId) ||
        _connectingBluetoothPeerIds.contains(deviceId);
    return PeerConnectionSnapshot(
      phase: connecting
          ? PeerConnectionPhase.connecting
          : PeerConnectionPhase.offline,
      transport: session?.transport,
    );
  }

  ConnectionTransport? connectionTransportFor(String deviceId) =>
      connectionStateFor(deviceId).transport;

  /// UI helper for an explicit per-folder sync request. Uses the current ready
  /// session when available; passing null intentionally means a local scan only.
  Future<void> syncFolderNow(FolderPair pair) async {
    final peerId = pair.peerDeviceId;
    final session = peerId == null ? null : _registry.openSessionFor(peerId);
    await _engine.reconcile(
      pair,
      session != null && session.isLinkReady ? session : null,
    );
  }

  /// Force one manual reconcile for every configured folder pair.
  ///
  /// This deliberately does not start connection boost. Connected pairs sync
  /// immediately; offline pairs refresh their local index so their changes are
  /// ready for the reconnect-triggered exchange. Runs pairs sequentially to
  /// keep Android SAF/provider work bounded and battery-friendly.
  Future<SyncAllResult> syncAllNow() async {
    if (!_started) {
      return const SyncAllResult(
        totalPairs: 0,
        triggeredWithPeer: 0,
        indexedLocally: 0,
        skippedBusy: 0,
        failed: 0,
        notStarted: true,
      );
    }
    if (_syncAllRunning) {
      return const SyncAllResult(
        totalPairs: 0,
        triggeredWithPeer: 0,
        indexedLocally: 0,
        skippedBusy: 0,
        failed: 0,
        alreadyRunning: true,
      );
    }
    if (_engine.isPaused) {
      return const SyncAllResult(
        totalPairs: 0,
        triggeredWithPeer: 0,
        indexedLocally: 0,
        skippedBusy: 0,
        failed: 0,
        paused: true,
      );
    }

    final pairs = List<FolderPair>.of(_config.folderPairs);
    if (pairs.isEmpty) {
      return const SyncAllResult(
        totalPairs: 0,
        triggeredWithPeer: 0,
        indexedLocally: 0,
        skippedBusy: 0,
        failed: 0,
      );
    }

    _syncAllRunning = true;
    _lastSyncAllSummary = 'Syncing ${pairs.length} folder pair(s)…';
    notifyListeners();

    var triggeredWithPeer = 0;
    var indexedLocally = 0;
    var skippedBusy = 0;
    var failed = 0;

    try {
      for (final pair in pairs) {
        // The pair may have been removed while an earlier scan was awaiting.
        if (!_config.folderPairs.any((candidate) => candidate.id == pair.id)) {
          continue;
        }
        if (_engine.stateFor(pair.id)?.scanning == true) {
          skippedBusy++;
          continue;
        }

        final peerId = pair.peerDeviceId;
        final session =
            peerId == null ? null : _registry.openSessionFor(peerId);
        final hasReadyPeer = session?.isLinkReady == true;
        try {
          await _engine.reconcile(pair, hasReadyPeer ? session : null);
          if (_engine.stateFor(pair.id)?.status == 'Error') {
            failed++;
          } else if (hasReadyPeer) {
            triggeredWithPeer++;
          } else {
            indexedLocally++;
          }
        } catch (error) {
          failed++;
          Diag.log(
            'manual_sync_all_pair_failed',
            pairId: pair.id,
            fields: {'error': error.toString()},
          );
        }
      }

      final result = SyncAllResult(
        totalPairs: pairs.length,
        triggeredWithPeer: triggeredWithPeer,
        indexedLocally: indexedLocally,
        skippedBusy: skippedBusy,
        failed: failed,
      );
      _lastSyncAllAt = dependencies.now();
      _lastSyncAllSummary = result.message;
      Diag.log('manual_sync_all_complete', fields: {
        'pairs': pairs.length,
        'withPeer': triggeredWithPeer,
        'localOnly': indexedLocally,
        'busy': skippedBusy,
        'failed': failed,
      });
      return result;
    } finally {
      _syncAllRunning = false;
      notifyListeners();
    }
  }

  /// Temporarily run discovery, reconnect, and folder reconciliation in an
  /// aggressive user-requested mode. Healthy sessions are preserved; only
  /// offline or incomplete sessions are redialled.
  Future<void> startConnectionBoost(Duration requestedDuration) async {
    if (!_started) return;
    final duration = requestedDuration < const Duration(minutes: 1)
        ? const Duration(minutes: 1)
        : requestedDuration > const Duration(minutes: 30)
            ? const Duration(minutes: 30)
            : requestedDuration;
    final deadline = dependencies.now().add(duration);
    _connectionBoostUntil = deadline;
    _connectionBoostTimer?.cancel();
    _connectionBoostRetryTimer?.cancel();
    _connectionBoostTimer =
        Timer(duration, () => _finishConnectionBoost(deadline));
    _connectionBoostRetryTimer =
        Timer.periodic(const Duration(seconds: 10), (_) {
      if (!connectionBoostActive) return;
      _supervisor.retryNow();
      _discovery?.reannounce();
    });

    _suppressedPeerIds.clear();
    if (_engine.isPaused) _engine.resumeSync();
    _ensureBackgroundServiceRunning();
    _applyBeaconMode();
    notifyListeners();
    Diag.log('connection_boost_start', fields: {
      'durationSeconds': duration.inSeconds,
      'peers': _config.pairedPeers.length,
      'pairs': _config.folderPairs.length,
    });
    unawaited(_runConnectionBoost());
  }

  Future<void> _runConnectionBoost() async {
    _discovery?.reannounce();
    if (_config.bluetoothEnabled) await _bluetooth?.refreshDiscovery();

    final reconnects = <Future<void>>[];
    for (final peer in _config.pairedPeers) {
      final session = _registry.openSessionFor(peer.deviceId);
      if (session?.isLinkReady == true) continue;
      if (session != null) {
        _registry.drop(peer.deviceId, session);
        session.stopHeartbeat();
        _engine.onPeerSessionLost(peer.deviceId);
        _engine.onPeerDisconnected(peer.deviceId);
        unawaited(session.close().catchError((Object _) {}));
      }
      reconnects.add(reconnectPeer(peer).catchError((Object error) {
        Diag.session('connection_boost_dial_failed',
            peer: peer.deviceId, fields: {'error': error.toString()});
      }));
    }
    await Future.wait(reconnects);
    _supervisor.retryNow();

    await Future.wait(_config.folderPairs.map((pair) async {
      try {
        await syncFolderNow(pair);
      } catch (error) {
        Diag.log('connection_boost_sync_failed',
            pairId: pair.id, fields: {'error': error.toString()});
      }
    }));
  }

  void _finishConnectionBoost(DateTime deadline) {
    if (_connectionBoostUntil != deadline) return;
    _connectionBoostTimer?.cancel();
    _connectionBoostTimer = null;
    _connectionBoostRetryTimer?.cancel();
    _connectionBoostRetryTimer = null;
    _connectionBoostUntil = null;
    _applyBeaconMode();
    notifyListeners();
    Diag.log('connection_boost_end');
  }

  Future<SyncPreview> buildSyncPreview(
    FolderPair pair, {
    bool refreshLocal = true,
  }) async {
    if (refreshLocal) {
      await _engine.refreshLocalIndexForPreview(pair);
    }
    final inputs = await _engine.previewInputs(pair);
    var preview = assembleSyncPreview(
      pair: pair,
      inputs: inputs,
      capturedAt: DateTime.now(),
    );
    final latest = await _engine.previewInputs(pair);
    if (latest.localGeneration != inputs.localGeneration) {
      preview = preview.withFreshness(SyncPreviewFreshness.staleLocal);
    } else if (latest.peerGeneration != inputs.peerGeneration) {
      preview = preview.withFreshness(SyncPreviewFreshness.stalePeer);
    }
    return preview;
  }

  bool isPeerConnected(String deviceId) =>
      connectionStateFor(deviceId).isConnected;

  /// Info about currently-connected peers for the devices panel.
  List<PairedPeer> get connectedPeers => _config.pairedPeers
      .where((p) => _registry.openSessionFor(p.deviceId)?.isLinkReady == true)
      .toList(growable: false);

  Future<void>? _startOperation;

  /// Start once and let concurrent callers join the same initialization.
  /// Android's headless service entry and DashboardScreen can legitimately
  /// request startup at nearly the same time.
  Future<void> start() {
    if (_started) return Future<void>.value();
    final active = _startOperation;
    if (active != null) return active;
    final operation = _start();
    _startOperation = operation;
    void clearOperation() {
      if (identical(_startOperation, operation)) _startOperation = null;
    }

    operation.then<void>(
      (_) => clearOperation(),
      onError: (Object _, StackTrace __) => clearOperation(),
    );
    return operation;
  }

  Future<void> _start() async {
    if (_started) return;
    // Observe app lifecycle so we can recover from suspend/resume (Priority 8).
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isAndroid) {
      _chNetworkEvents.setMethodCallHandler(_onNativeNetworkCall);
    }
    final platform = Platform.isWindows
        ? 'windows'
        : Platform.isAndroid
            ? 'android'
            : 'other';

    _identity = await dependencies.loadIdentity(platform);
    _config = await dependencies.loadConfig();

    // Load persisted dashboard states
    final snapshots = _config.deviceStatusSnapshots;
    snapshots.forEach((deviceId, data) {
      if (data is Map<String, dynamic>) {
        final state = getOrCreateDashboardState(deviceId);
        state.batteryPct = data['batteryPct'] as int?;
        state.powerState = data['powerState'] as String?;
        state.storageAvailableBytes = data['storageAvailableBytes'] as int?;
        state.storageTotalBytes = data['storageTotalBytes'] as int?;
        state.conduitHealth = data['conduitHealth'] as Map<String, dynamic>?;
        state.pairHealth = data['pairHealth'] as Map<String, dynamic>?;
        if (data['statusReceivedAt'] != null) {
          state.statusReceivedAt =
              DateTime.tryParse(data['statusReceivedAt'] as String);
        }
        if (data['lastSeenAt'] != null) {
          state.lastSeenAt = DateTime.tryParse(data['lastSeenAt'] as String);
        }
        if (data['lastDisconnectedAt'] != null) {
          state.lastDisconnectedAt =
              DateTime.tryParse(data['lastDisconnectedAt'] as String);
        }
        if (data['connectedAt'] != null) {
          state.connectedAt = DateTime.tryParse(data['connectedAt'] as String);
        }
      }
    });

    _fs = dependencies.createFileSystemAccess(platform);

    // Step 4: shared registry — the single source of truth for live sessions.
    _registry = PeerConnectionRegistry();

    _bluetooth = BluetoothBridge(
      onDevice: _onBluetoothDevice,
      onStatus: (status) {
        _bluetoothAdapterStatus = status;
        Diag.log('bluetooth_status', fields: {'status': status});
        notifyListeners();
      },
    );

    // App-private dir for sync metadata. Same place as config.json /
    // identity.json. NEVER inside the synced folder.
    final stateDir = await dependencies.loadSupportDirectory();
    _transferReceipts = await TransferReceiptRepository.open(stateDir);

    _engine = SyncEngine(
      fs: _fs,
      config: _config,
      stateDir: stateDir,
      registry: _registry,
      deviceId: _identity.deviceId,
      onFolderInvite: _onFolderInviteReceived,
      // Phase 0.4: route transfer start/stop to the Android wake lock so the
      // radio/CPU stay up only while bytes are actually moving.
      onTransferState: _onTransferState,
      // Phase 2: route an inbound peer clipboard push to the host-side writer.
      onClipboardPush: _onClipboardPushReceived,
      onClipboardRequest: _onClipboardRequestReceived,
      // Phase 4: route an inbound remote command to the PC executor.
      onRunCommand: _onRunCommandReceived,
      onDeviceStatus: _onDeviceStatusReceived,
      onPhoneAction: _onPhoneActionReceived,
      onPhoneActionResult: _onPhoneActionResultReceived,
      onLanProbe: _onLanProbeReceived,
      onLanCandidates: _onLanCandidatesReceived,
      // Phase 0.6: on Android, give the watcher/scanner the batched SAF
      // lister instead of the per-file stat loop. Null (unchanged behaviour)
      // on every other platform.
      batchListWithStat: _fs is SafFileSystemAccess
          ? (_fs as SafFileSystemAccess).listFilesWithStat
          : _fs is LocalFileSystemAccess
              ? (_fs as LocalFileSystemAccess).listFilesWithStat
              : null,
      hashFileOverride: _fs is SafFileSystemAccess
          ? (_fs as SafFileSystemAccess).hashFile
          : null,
    );
    _engine.stateChanges.listen((s) {
      _pairStates[s.pairId] = s;
      _notifyHighFrequency();
    });
    _engine.events.listen((e) {
      _events.insert(0, e);
      if (_events.length > 500) _events.removeRange(500, _events.length);
      notifyListeners();
    });

    _connections = PeerConnectionManager(
      identity: _identity,
      config: _config,
      registry: _registry,
      onSessionReady: _onSessionReady,
      onPairingRequest: (_, __) {},
      resolveIncomingTransport: _bluetooth!.resolveIncoming,
    );
    final port = await _connections.start();

    // Start discovery once we know our listen port.
    _discovery = Discovery(
      self: _identity,
      listenPort: port,
      onPeer: (peer) {
        final previous = _discoveredPeers[peer.deviceId];
        final changed = previous == null ||
            previous.address.address != peer.address.address ||
            previous.port != peer.port ||
            previous.transport != peer.transport ||
            previous.transportEndpoint != peer.transportEndpoint ||
            previous.name != peer.name;
        _discoveredPeers[peer.deviceId] = peer;
        if (changed) {
          unawaited(_config
              .rememberPeerEndpoint(
                deviceId: peer.deviceId,
                address: peer.address.address,
                port: peer.port,
              )
              .catchError((_) {}));
          notifyListeners();
        }
        if (_networkingReady) {
          _supervisor.notePeerSeen(peer, endpointChanged: changed);
        } else {
          unawaited(_maybeAutoConnect(peer));
        }
      },
      onNetworkChanged: _onHostInterfaceChanged,
    );
    await _discovery!.start();
    if (_config.bluetoothEnabled) {
      if (Platform.isAndroid) {
        await _bluetooth!.requestPermissions();
      }
      unawaited(_bluetooth!.start(dartListenPort: port));
    } else {
      _bluetoothAdapterStatus = 'Bluetooth disabled';
    }
    _seedDiscoveredPeersFromSavedEndpoints();

    // The supervisor is the reliable reconnect path: independent of discovery
    // beacons, it periodically ensures every paired peer has a live session.
    // This closes the gaps where a lost beacon or a half-dead socket left a
    // paired peer disconnected indefinitely. It reuses the existing connect
    // path via [_maybeAutoConnectFor].
    _supervisor = ConnectionSupervisor(
      registry: _registry,
      config: _config,
      discoveredPeers: _discoveredPeers,
      connect: _maybeAutoConnectFor,
      isConnecting: (id) => _connectingPeerIds.contains(id),
      isSuppressed: (id) => _suppressedPeerIds.contains(id),
    );
    _supervisorInitialized = true;
    _supervisor.start();
    _networkingReady = true;
    final pendingNetworkEvent = _pendingNativeNetworkEvent;
    _pendingNativeNetworkEvent = null;
    if (pendingNetworkEvent != null) {
      _handleNativeNetworkEvent(pendingNetworkEvent);
    }
    if (Platform.isWindows) {
      _windowsLanUpgradeTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => _probeLanUpgrades(),
      );
    }

    // Restart watching any pre-existing folder pairs.
    //
    // Started fire-and-forget (NOT awaited) so a wedged reconcile in any one
    // pair can never strand the UI on the "Starting…" spinner. startPair's
    // internal reconcile (engine.dart) awaits an unbounded peer block-response
    // (sink.next()); if that never resolves, awaiting it here would block
    // `_started = true` forever and freeze the dashboard. With a real peer
    // already connected and a pair carrying a backlog (e.g. many duplicate
    // files), that first startup reconcile is exactly the path that wedges.
    // Backgrounding it means the dashboard renders immediately and reconciles
    // run independently — a stuck one is visible (pair stays "Scanning" /
    // reports an error) rather than invisible behind a spinner.
    for (final pair in _config.folderPairs) {
      unawaited(_engine.startPair(pair).catchError((Object e, StackTrace s) {
        Diag.log('start_pair_error',
            pairId: pair.id, fields: {'error': e.toString()});
      }));
    }

    // Phase 0.5: hourly DB backup sweep (recoverable Index DB without a full
    // re-scan). The engine owns the open DB handles; it runs the actual copies.
    _engine.startBackupTimer();

    // Phase 1: on Android, start the foreground service so the OS treats sync
    // as a user-visible background task and (with the user's battery
    // whitelist) doesn't kill it. No-op + safe-fail on non-Android. The service
    // also owns the transfer-tied wake lock driven by _onTransferState below.
    _ensureBackgroundServiceRunning();
    // Give cold starts the same bounded recovery window as a real network
    // transition. setDiscoveryNeeded/setConnectionLockEnabled persist desired
    // state even if the asynchronous foreground-service start has not reached
    // onCreate yet, so the service acquires both locks as soon as it is ready.
    _activateNetworkRecovery(const Duration(seconds: 75));

    // Polish: apply the stored notification visibility preference now that the
    // service is running. Default is visible (true); only fires on Android.
    if (Platform.isAndroid && !_config.showPersistentNotification) {
      _chSync.invokeMethod<void>(
          'setNotificationVisibility', {'visible': false}).catchError((_) {});
    }

    // Polish: apply battery-saver mode before pairs start so watchers
    // are created with the right interval from the very first tick.
    if (_config.batterySaverMode) {
      _engine.setBatterySaverMode(true);
    }

    // Phase 2: clipboard sync.
    _clipboard = ClipboardSync(
      registry: _registry,
      pairedPeerIds: _pairedPeerIds,
      onLog: (msg, isError) => Diag.log('clipboard', fields: {
        'msg': msg,
        if (isError) 'level': 'error',
      }),
      onRemoteReceived: _onClipboardRemoteReceived,
      now: DateTime.now,
      onStateChanged: notifyListeners,
    );
    _clipboard!.setEnabled(_config.clipboardSyncEnabled);

    // Phase 3a: ad-hoc file send + auto-receive.
    _adHoc = AdHocFileSend(
      fs: _fs,
      notifier: _notifier,
      getReceivedFilesPath: _resolveReceivedFilesPath,
      getPeerName: _peerNameFor,
      receipts: _transferReceipts,
      onLog: (msg, {bool isError = false}) {
        Diag.log('adhoc', fields: {'msg': msg, if (isError) 'level': 'error'});
      },
    );
    _engine.adHocSend = _adHoc;
    _engine.transferReceipts = _transferReceipts;

    // Phase 3b: initialise the notification plugin (channel setup + permission).
    // Wire up the file-open callback BEFORE init() so any notification that
    // was tapped while the app was dead (cold-start) fires the handler.
    if (Platform.isAndroid) {
      _notifier.onFileNotificationTap = (treeUri, relPath) {
        // Open the received file in the system viewer (e.g. gallery, PDF app).
        // Best-effort: if the file was deleted or no viewer is installed the
        // native side logs and ignores the error.
        SafFileSystemAccess.openFile(treeUri, relPath);
      };
    }
    await _notifier.init();

    // Phase 3d: subscribe to the OS share/send channel so files shared into
    // Conduit from any file manager, gallery, or the Windows "Send to" menu
    // are routed to [sendAdHocFile] without the user having to open the app.
    _subscribeShareChannel();

    // Phase 3d (Windows only): ensure the "Send to Conduit" shortcut exists
    // in %APPDATA%\Microsoft\Windows\SendTo so it appears in Explorer right-click.
    if (Platform.isWindows) {
      _chShell
          .invokeMethod<bool>('createSendToShortcut')
          .catchError((Object e) {
        Diag.log('send_to_shortcut_error', fields: {'error': e.toString()});
        return false;
      });
    }

    // Phase 4: remote command executor (Windows only). On Android the phone
    // sends commands; on Windows the PC executes them. The executor is null
    // on Android so _onRunCommandReceived is a safe no-op there.
    if (Platform.isWindows) {
      _remoteCmd = RemoteCommandExecutor(
        enabled: _config.remoteControlEnabled,
        onLog: (msg, {bool isError = false}) {
          Diag.log('remote_cmd',
              fields: {'msg': msg, if (isError) 'level': 'error'});
        },
      );
    }

    _started = true;
    _status = 'Running';
    notifyListeners();
  }

  /// Step 3: invite arrives from the engine → store it as STATE, then notify.
  /// The DashboardScreen's build method reads `pendingInvite` and renders the
  /// dialog if non-null. No stream, no listener-to-attach-in-time, no
  /// tear-down-on-rebuild. If the user already has an invite on screen, we
  /// queue the next one (it surfaces after the current is resolved).
  void _onFolderInviteReceived(FolderPairInvite invite) {
    if (_pendingInvite != null) {
      _queuedInvites.add(invite);
      return;
    }
    _pendingInvite = invite;
    notifyListeners();
  }

  /// Called by the UI after the user responds (accept or decline) to the
  /// current [pendingInvite]. Clears it and surfaces any queued one.
  void _consumePendingInvite() {
    _pendingInvite = _queuedInvites.isEmpty ? null : _queuedInvites.removeAt(0);
    notifyListeners();
  }

  /// Auto-connect to a peer we've already paired with, triggered by a
  /// discovery beacon. Both the beacon path and the [ConnectionSupervisor]
  /// route through the shared [_dialPeer] core below.
  ///
  /// SYMMETRIC RECONNECT (was: dialer-only). Previously only the device with
  /// the lexically-smaller deviceId dialed; the other side only listened.
  /// That created a stalemate: if the listener's session died but the dialer
  /// thought theirs was alive (half-dead socket), the listener had NO path
  /// to reconnect and waited for the dialer's heartbeat timeout.
  ///
  /// Now BOTH sides dial. To avoid a simultaneous double-dial on the first
  /// beacon after a mutual disconnect, the lexically-smaller device dials
  /// immediately; the larger device waits a short stagger before its
  /// first attempt for that peer. The registry's identity-guarded `publish`
  /// already makes a late duplicate safe (it just evicts the older socket), so
  /// this stagger is belt-and-suspenders, not load-bearing.
  ///
  /// The [stagger] parameter is true for the lexically-larger device's FIRST
  /// attempt for a peer that currently has no session, to break the
  /// simultaneous-dial tie.
  Future<void> _maybeAutoConnect(DiscoveredPeer peer) async {
    final paired = _config.pairedPeers.any((p) => p.deviceId == peer.deviceId);
    if (!paired) return;
    await _dialPeer(peer, allowStagger: true);
  }

  void _onBluetoothDevice(BluetoothDeviceEndpoint endpoint) {
    final mappedId = _config.peerIdForBluetoothEndpoint(endpoint.id);
    PairedPeer? paired;
    if (mappedId != null) {
      for (final candidate in _config.pairedPeers) {
        if (candidate.deviceId == mappedId) {
          paired = candidate;
          break;
        }
      }
    }
    // The Windows backend changed from opaque WinRT service IDs to stable
    // Bluetooth addresses. When this installation has exactly one Conduit
    // peer, use its authenticated identity as the candidate for a newly seen
    // endpoint. The endpoint is persisted only after the handshake succeeds,
    // so an unrelated RFCOMM service cannot corrupt the mapping.
    if (paired == null && _config.pairedPeers.length == 1) {
      paired = _config.pairedPeers.single;
    }
    final peer = DiscoveredPeer(
      deviceId: paired?.deviceId ?? 'bluetooth:${endpoint.id}',
      name: paired?.name ?? endpoint.name,
      platform: paired?.platform ?? 'bluetooth',
      address: InternetAddress.loopbackIPv4,
      port: 0,
      publicKeyB64: paired?.publicKeyB64 ?? '',
      transport: ConnectionTransport.bluetooth,
      transportEndpoint: endpoint.id,
    );
    _bluetoothPeers[endpoint.id] = peer;
    notifyListeners();
    if (paired != null) _scheduleBluetoothCandidates(peer.deviceId);
  }

  void _scheduleBluetoothCandidates(String peerId) {
    _bluetoothDialTimers.remove(peerId)?.cancel();
    _bluetoothDialTimers[peerId] = Timer(
      const Duration(milliseconds: 500),
      () {
        _bluetoothDialTimers.remove(peerId);
        unawaited(_dialBluetoothCandidates(peerId));
      },
    );
  }

  void _setConnecting(Set<String> set, String peerId, bool connecting) {
    final changed = connecting ? set.add(peerId) : set.remove(peerId);
    if (changed) notifyListeners();
  }

  Future<void> _dialBluetoothCandidates(String peerId) async {
    if (_suppressedPeerIds.contains(peerId) ||
        _registry.openSessionFor(peerId) != null ||
        _connectingBluetoothPeerIds.contains(peerId)) {
      return;
    }
    final candidates = <String, DiscoveredPeer>{};
    final savedEndpoint = _config.bluetoothEndpoint(peerId);
    if (savedEndpoint != null) {
      final savedPeer = _bluetoothPeers[savedEndpoint];
      if (savedPeer != null) candidates[savedEndpoint] = savedPeer;
    }
    for (final peer in _bluetoothPeers.values) {
      final endpoint = peer.transportEndpoint;
      if (peer.deviceId == peerId && endpoint != null) {
        candidates[endpoint] = peer;
      }
    }
    if (candidates.isEmpty) {
      _bluetoothAttemptStatus =
          'Bluetooth ready - no OS-paired candidates found';
      notifyListeners();
      return;
    }

    _setConnecting(_connectingBluetoothPeerIds, peerId, true);
    _bluetoothAttemptStatus =
        'Trying ${candidates.length} OS-paired Bluetooth candidate${candidates.length == 1 ? '' : 's'}';
    notifyListeners();
    Object? lastError;
    try {
      for (final peer in candidates.values) {
        if (_registry.openSessionFor(peerId) != null) return;
        try {
          final session = await _connectTarget(peer);
          await _rememberSessionEndpoint(session, peer);
          _bluetoothAttemptStatus = null;
          notifyListeners();
          return;
        } catch (error) {
          lastError = error;
        }
      }
      if (_registry.openSessionFor(peerId) != null) return;
      Diag.session(
        'bluetooth_candidates_failed',
        peer: peerId,
        fields: {
          'candidates': candidates.length,
          if (lastError != null) 'error': lastError.toString(),
        },
      );
      _bluetoothAttemptStatus =
          'No OS-paired device accepted a Conduit Bluetooth connection';
      notifyListeners();
    } finally {
      _setConnecting(_connectingBluetoothPeerIds, peerId, false);
    }
  }

  void _probeLanUpgrades() {
    if (!Platform.isWindows) return;
    for (final peerId in _registry.readyPeerIds) {
      final session = _registry.openSessionFor(peerId);
      if (session?.transport != ConnectionTransport.bluetooth) continue;
      try {
        session!.send({'t': Msg.lanProbe});
      } catch (error) {
        Diag.session('lan_probe_send_failed',
            peer: peerId, fields: {'error': error.toString()});
      }
    }
  }

  Future<void> _onLanProbeReceived(String peerId) async {
    final session = _registry.openSessionFor(peerId);
    if (session == null || session.transport != ConnectionTransport.bluetooth) {
      return;
    }
    final hosts = await localIpAddresses();
    if (hosts.isEmpty) return;
    try {
      session.send({
        't': Msg.lanCandidates,
        'hosts': hosts,
        'port': _connections.listenPort,
      });
    } catch (error) {
      Diag.session('lan_candidates_send_failed',
          peer: peerId, fields: {'error': error.toString()});
    }
  }

  void _onLanCandidatesReceived(String peerId, List<String> hosts, int port) {
    if (!Platform.isWindows) return;
    unawaited(_dialLanCandidates(peerId, hosts, port));
  }

  Future<void> _dialLanCandidates(
      String peerId, List<String> rawHosts, int port) async {
    final existing = _registry.openSessionFor(peerId);
    if (existing?.transport != ConnectionTransport.bluetooth ||
        _connectingPeerIds.contains(peerId)) {
      return;
    }
    PairedPeer? paired;
    for (final candidate in _config.pairedPeers) {
      if (candidate.deviceId == peerId) {
        paired = candidate;
        break;
      }
    }
    if (paired == null) return;

    final hosts = <InternetAddress>[];
    for (final raw in rawHosts) {
      try {
        final address = InternetAddress(raw);
        if (address.type == InternetAddressType.IPv4 &&
            !address.isLoopback &&
            !hosts.any((candidate) => candidate.address == address.address)) {
          hosts.add(address);
        }
      } catch (_) {}
    }
    if (hosts.isEmpty) return;

    _setConnecting(_connectingPeerIds, peerId, true);
    try {
      final session = await _connections.connectMultiHost(
        deviceId: paired.deviceId,
        name: paired.name,
        platform: paired.platform,
        publicKeyB64: paired.publicKeyB64,
        hosts: hosts,
        port: port,
        forceTakeover: true,
      );
      await _config.rememberPeerEndpoint(
        deviceId: peerId,
        address: session.remoteAddress,
        port: port,
      );
      _discoveredPeers[peerId] = DiscoveredPeer(
        deviceId: paired.deviceId,
        name: paired.name,
        platform: paired.platform,
        address: InternetAddress(session.remoteAddress),
        port: port,
        publicKeyB64: paired.publicKeyB64,
      );
      notifyListeners();
    } catch (error) {
      Diag.session('lan_upgrade_failed', peer: peerId, fields: {
        'hosts': hosts.map((host) => host.address).toList(),
        'error': error.toString(),
      });
    } finally {
      _setConnecting(_connectingPeerIds, peerId, false);
    }
  }

  /// Entry point for the [ConnectionSupervisor]. Same as the beacon path,
  /// including the deterministic stagger that prevents both devices from
  /// issuing authenticated takeovers at the same time on every sweep.
  Future<void> _maybeAutoConnectFor(DiscoveredPeer peer) =>
      _dialPeer(peer, allowStagger: true, propagateFailure: true);

  Future<void> _dialPeer(
    DiscoveredPeer peer, {
    required bool allowStagger,
    bool propagateFailure = false,
  }) async {
    final id = peer.deviceId;

    // Respect a user-intentional disconnect: once you tap Disconnect, neither
    // beacons nor the supervisor reconnect you until you reconnect explicitly.
    if (_suppressedPeerIds.contains(id)) return;

    final existing = _registry.openSessionFor(id);
    final isLanUpgrade = existing != null &&
        isTransportUpgrade(existing.transport, peer.transport);
    if (isLanUpgrade && !Platform.isWindows) return;
    if (existing != null && !isLanUpgrade) return; // already on best link
    if (_connectingPeerIds.contains(id)) return; // a dial is in flight
    _setConnecting(_connectingPeerIds, id, true);

    try {
      // Anti-simultaneous-dial tie-break: the lexically-larger device gives the
      // smaller one a head start on the first reconnect attempt for this peer.
      if (!isLanUpgrade &&
          allowStagger &&
          _identity.deviceId.compareTo(id) > 0 &&
          _autoConnectStaggeredPeerIds.add(id)) {
        await Future<void>.delayed(const Duration(milliseconds: 900));
        // Re-check after the delay: the other side may have already connected
        // or the user may have explicitly disconnected while this dial waited.
        if (_suppressedPeerIds.contains(id)) return;
        final e2 = _registry.openSessionFor(id);
        if (e2 != null) return;
      }
      final session = await _connectTarget(
        peer,
        forceTakeover: isLanUpgrade,
      );
      unawaited(_rememberSessionEndpoint(session, peer));
    } catch (e) {
      Diag.session('auto_dial_failed',
          peer: id, fields: {'error': e.toString()});
      // Discovery-triggered attempts are opportunistic and suppress failures.
      // Supervisor-triggered attempts MUST propagate the failure so its
      // exponential backoff bookkeeping remains accurate.
      if (propagateFailure) rethrow;
    } finally {
      _setConnecting(_connectingPeerIds, id, false);
    }
  }

  Future<PeerSession> _connectTarget(
    DiscoveredPeer peer, {
    String? pairCode,
    bool forceTakeover = false,
  }) async {
    if (peer.transport == ConnectionTransport.bluetooth) {
      final endpoint = peer.transportEndpoint;
      if (endpoint == null || endpoint.isEmpty) {
        throw StateError('Bluetooth endpoint is missing for ${peer.name}.');
      }
      final proxyPort = await _bluetooth!.connect(endpoint);
      return _connections.connectBluetooth(
        target: peer,
        localProxyPort: proxyPort,
        pairCode: pairCode,
        forceTakeover: forceTakeover,
      );
    }
    return _connections.connect(
      target: peer,
      pairCode: pairCode,
      forceTakeover: forceTakeover,
    );
  }

  Future<void> _rememberSessionEndpoint(
      PeerSession session, DiscoveredPeer source) async {
    if (session.transport == ConnectionTransport.bluetooth) {
      final endpoint = session.transportEndpoint ?? source.transportEndpoint;
      if (endpoint != null) {
        await _config.rememberPeerBluetoothEndpoint(
          deviceId: session.peer.deviceId,
          endpointId: endpoint,
        );
        _bluetoothPeers[endpoint] = DiscoveredPeer(
          deviceId: session.peer.deviceId,
          name: session.peer.name,
          platform: session.peer.platform,
          address: InternetAddress.loopbackIPv4,
          port: 0,
          publicKeyB64: session.peer.publicKeyB64,
          transport: ConnectionTransport.bluetooth,
          transportEndpoint: endpoint,
        );
      }
      return;
    }
    await _config.rememberPeerEndpoint(
      deviceId: session.peer.deviceId,
      address: session.remoteAddress,
      port: source.port,
    );
  }

  /// Called whenever a session with a peer becomes available.
  ///
  /// Step 4: publishing goes through the registry. If a previous session for
  /// this peer is still registered, [PeerConnectionRegistry.publish] returns
  /// it and we destroy that specific socket directly — never via the
  /// connection-manager's id-indexed map, which now points at the new session.
  ///
  /// Step 2: bye handling is done by the engine (it owns onMessage), so here
  /// we only need a socket.done fallback for crashes/drops. The fallback uses
  /// an identity check via [PeerConnectionRegistry.drop] so a late
  /// done-callback from an OLD socket can't evict a NEW one.
  bool _onSessionReady(PeerSession session) {
    final id = session.peer.deviceId;
    final previous = _registry.sessionFor(id);
    if (previous != null && !identical(previous, session)) {
      final previousOpen = !previous.isClosed;
      final previousPreferred = _isPreferredSession(id, previous);
      final incomingPreferred = _isPreferredSession(id, session);
      final previousStillHealthy =
          previousOpen && !previous.canBeSupersededByAutoReconnect;
      final incomingIsBetter =
          isTransportUpgrade(previous.transport, session.transport);

      // Deterministic link ownership: for a pair of devices, the lexically
      // smaller id owns the outbound socket and the larger id owns the inbound
      // side of that same socket. If a healthy preferred session already
      // exists, reject a competing duplicate instead of replacing it and
      // triggering another reconnect on the peer.
      if (previousStillHealthy &&
          !incomingIsBetter &&
          (previousPreferred || !incomingPreferred)) {
        Diag.session('session_rejected_existing_preferred',
            peer: id,
            session: session.generation,
            fields: {
              'existingSession': previous.generation,
              'existingInitiatedByUs': previous.initiatedByUs,
              'newInitiatedByUs': session.initiatedByUs,
              'existingPreferred': previousPreferred,
              'newPreferred': incomingPreferred,
            });
        return false;
      }
    }

    _bluetoothDialTimers.remove(id)?.cancel();
    _bluetoothAttemptStatus = null;
    final replaced = _registry.publish(id, session);
    if (session.transport == ConnectionTransport.bluetooth &&
        session.transportEndpoint != null) {
      unawaited(_config.rememberPeerBluetoothEndpoint(
        deviceId: id,
        endpointId: session.transportEndpoint!,
      ));
    }
    if (replaced != null && !identical(replaced, session)) {
      // A previous session is being replaced. Cancel its in-flight sync work
      // BEFORE wiring up the new session, so the old manifest waiters / chunk
      // sinks are cleared before the new reconcile (called from
      // onPeerConnected below) tries to run. Otherwise the new reconcile hits
      // the pair's `scanning` re-entrancy guard (still held by the dead
      // reconcile) and the pair wedges.
      _engine.onPeerSessionLost(id);
      try {
        replaced.socket.destroy();
      } catch (_) {}
      replaced.stopHeartbeat();
    }
    session.onLinkReady = () {
      if (_registry.generationOf(id) != session.generation) return;
      final dstate = getOrCreateDashboardState(id);
      dstate.connectedAt = DateTime.now();
      dstate.lastSeenAt = DateTime.now();
      dstate.latestRttMs = session.latestRttMs;
      dstate.recentRttMs = List<int>.from(session.recentRttMs);
      dstate.missedHeartbeats = 0;
      _persistDashboardState(id);

      _supervisor.noteConnected(id);
      _autoConnectStaggeredPeerIds.remove(id);
      _applyBeaconMode();
      if (Platform.isWindows &&
          session.transport == ConnectionTransport.bluetooth) {
        _probeLanUpgrades();
      }
      _clipboard?.onPeerConnectivityChanged();
      notifyListeners();
    };

    session.onHeartbeat = () {
      if (_registry.generationOf(id) != session.generation) return;
      final dstate = getOrCreateDashboardState(id);
      dstate.latestRttMs = session.latestRttMs;
      dstate.recentRttMs = List<int>.from(session.recentRttMs);
      dstate.missedHeartbeats = session.missedHeartbeats;
      dstate.lastSeenAt = DateTime.now();
      _notifyHighFrequency();
    };

    _engine.onPeerConnected(session);
    invalidateQrPairingToken();
    try {
      session
          .send({'t': Msg.ready, 'deviceId': _identity.deviceId, 'ack': false});
    } catch (e) {
      Diag.session('link_ready_send_failed',
          peer: id,
          session: session.generation,
          fields: {'error': e.toString()});
    }

    Timer(const Duration(seconds: 10), () {
      if (_registry.generationOf(id) != session.generation) return;
      if (session.isClosed || session.hasReceivedLinkReady) return;
      Diag.session('link_ready_timeout', peer: id, session: session.generation);
      if (_registry.drop(id, session)) {
        session.stopHeartbeat();
        _engine.onPeerSessionLost(id);
        _supervisor.noteDisconnected(id);
        _startReconnectRecovery(id, const Duration(seconds: 75));
        _clipboard?.onPeerConnectivityChanged();
        notifyListeners();
      }
      session.close().catchError((Object _) {});
    });

    session.socket.done.then((_) {
      final wasReady = session.hasReceivedLinkReady;
      if (_registry.drop(id, session)) {
        session.stopHeartbeat();
        _engine.onPeerSessionLost(id); // cancel in-flight work for this session
        if (wasReady) {
          _engine.onPeerDisconnected(id);
          final dstate = getOrCreateDashboardState(id);
          dstate.lastDisconnectedAt = DateTime.now();
          _persistDashboardState(id);
        }
        _supervisor.noteDisconnected(id); // schedule a reconnect
        _startReconnectRecovery(id, const Duration(seconds: 75));
        _clipboard?.onPeerConnectivityChanged(); // Phase 2: peer gone -> idle
        notifyListeners();
        if (_config.bluetoothEnabled) {
          _scheduleBluetoothCandidates(id);
        }
      }
    });
    notifyListeners();
    return true;
  }

  bool _isPreferredSession(String peerId, PeerSession session) {
    final thisDeviceShouldInitiate = _identity.deviceId.compareTo(peerId) < 0;
    return session.initiatedByUs == thisDeviceShouldInitiate;
  }

  /// Phase 0.3 beacon backoff. Once every paired peer is ready we slow the
  /// UDP beacon. While any paired peer is missing, discovery stays active but
  /// backs off from 3s to 15s and then 1m to avoid keeping Wi-Fi busy forever.
  void _applyBeaconMode() {
    final readyPeerIds = _registry.readyPeerIds.toSet();
    final pairedPeerIds = _pairedPeerIds();
    final anyLive = readyPeerIds.isNotEmpty;
    final allPairedPeersReady = pairedPeerIds.isNotEmpty &&
        pairedPeerIds.every(readyPeerIds.contains);
    final needsDiscovery = !allPairedPeersReady;
    final boosted = connectionBoostActive || _networkRecoveryActive;

    // Do not slow or disable discovery merely because ONE device is online.
    // Every paired peer must be reachable before discovery can enter its stable
    // cadence; otherwise a second device that changed IP can stay offline.
    _discovery
        ?.setBeaconMode(needsDiscovery ? BeaconMode.fast : BeaconMode.stable);
    _discovery?.setBoosted(boosted);

    // A healthy TCP socket and the foreground service are enough to receive
    // lightweight clipboard traffic. Do not hold a 24/7 partial CPU wake lock
    // merely because clipboard sync is enabled; reserve it for bounded
    // reconnect/network-recovery bursts. Transfers own a separate scoped lock.
    _setConnectionWakeLockEnabled(boosted);
    // Receiving multicast/broadcast packets is only required during a bounded
    // recovery window. Outside that window both peers continue sparse outbound
    // beacons and symmetric TCP dials, so keeping Android's MulticastLock held
    // for an hours-long outage wastes battery without improving reachability.
    _setDiscoveryLockEnabled(boosted);

    if (anyLive) {
      _startAndroidStatusSampling();
    } else {
      _stopAndroidStatusSampling();
    }
  }

  /// Roadmap Phase 0.6 — battery: toggles the Android SyncService's
  /// MulticastLock. It is enabled only for bounded startup, reconnect, and
  /// network-transition recovery windows. Sparse outbound beacons and
  /// symmetric dialing continue after the window without keeping the Wi-Fi
  /// multicast receive filter open all day. Idempotent — skips the channel
  /// call when already in the requested state.
  ///
  /// SyncService is the sole MulticastLock owner, avoiding duplicate Wi-Fi
  /// locks while MainActivity is visible.
  void _setDiscoveryLockEnabled(bool needed) {
    if (!Platform.isAndroid) return;
    if (needed == _discoveryLockHeld) return; // already in the right state
    _discoveryLockHeld = needed;
    final method = needed ? 'acquireDiscovery' : 'releaseDiscovery';
    _chWakelock.invokeMethod<void>(method).catchError((Object e) {
      Diag.log('discovery_lock_toggle_error', fields: {'error': e.toString()});
    });
  }

  void _setConnectionWakeLockEnabled(bool enabled) {
    if (!Platform.isAndroid) return;
    if (enabled) {
      _renewConnectionWakeLock();
      _connectionWakeLockRenewal ??= Timer.periodic(
        const Duration(minutes: 10),
        (_) => _renewConnectionWakeLock(),
      );
      return;
    }

    _connectionWakeLockRenewal?.cancel();
    _connectionWakeLockRenewal = null;
    if (_connectionWakeLockHeld) {
      _connectionWakeLockHeld = false;
      _chWakelock
          .invokeMethod<void>('releaseConnection')
          .catchError((Object e) {
        Diag.log('connection_wakelock_release_error',
            fields: {'error': e.toString()});
      });
    }
  }

  void _renewConnectionWakeLock() {
    if (!Platform.isAndroid) return;
    _connectionWakeLockHeld = true;
    _chWakelock.invokeMethod<void>('acquireConnection').catchError((Object e) {
      Diag.log('connection_wakelock_acquire_error',
          fields: {'error': e.toString()});
    });
  }

  void _seedDiscoveredPeersFromSavedEndpoints() {
    for (final peer in _config.pairedPeers) {
      final discovered = _discoveredPeerFromSavedEndpoint(peer);
      if (discovered != null) {
        _discoveredPeers[peer.deviceId] = discovered;
      }
    }
  }

  DiscoveredPeer? _discoveredPeerFromSavedEndpoint(PairedPeer peer) {
    final endpoint = _config.peerEndpoint(peer.deviceId);
    if (endpoint == null) return null;
    try {
      return DiscoveredPeer(
        deviceId: peer.deviceId,
        name: peer.name,
        platform: peer.platform,
        address: InternetAddress(endpoint['address'] as String),
        port: endpoint['port'] as int,
        publicKeyB64: peer.publicKeyB64,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _windowsLanUpgradeTimer?.cancel();
    _windowsLanUpgradeTimer = null;
    _connectionBoostTimer?.cancel();
    _connectionBoostRetryTimer?.cancel();
    _networkRecoveryTimer?.cancel();
    _resumeProbeTimer?.cancel();
    _highFrequencyUiTimer?.cancel();
    _cancelNetworkReannounces();
    _networkingReady = false;
    if (Platform.isAndroid) {
      _chNetworkEvents.setMethodCallHandler(null);
    }
    if (_supervisorInitialized) {
      _supervisor.stop();
      _supervisorInitialized = false;
    }
    // Other late-owned resources are guaranteed only after a successful start.
    if (!_started) {
      super.dispose();
      return;
    }
    _discovery?.stop();
    _connections.stop();
    _clipboard?.dispose();
    _setConnectionWakeLockEnabled(false);
    _onTransferState(false); // cancel renewal timer + release, if held
    _engine.dispose();
    final receipts = _transferReceipts;
    if (receipts != null) unawaited(receipts.close());
    super.dispose();
  }

  // ---- App lifecycle (Priority 8: suspend/resume recovery) ---------------
  //
  // On mobile (Android Doze, iOS backgrounding) and after the OS has
  // throttled/suspended the app, open sockets may be suspect: the network
  // may have changed and half-dead sockets can linger until heartbeat cleanup.
  // Rather than destroy every session, on resume we actively probe them. Only
  // sessions that miss both probes are closed and handed to the reconnect
  // supervisor; healthy service-owned sockets are preserved without UI churn.
  //
  // GATING (critical — this was the root cause of session churn): Android
  // fires AppLifecycleState.resumed after EVERY inactive→resumed transition,
  // not just genuine backgroundings. The SAF folder picker (used when the user
  // accepts a folder invite), permission dialogs, and the notification shade
  // all cause inactive→resumed. Resetting on every one of those tore down
  // healthy sessions within the same second they were established. So we only
  // reset when BOTH hold:
  //   (a) the prior state was a real backgrounding (paused/hidden/detached),
  //       not a transient inactive; AND
  //   (b) we were backgrounded for at least [_minBgForReset] (five minutes).
  //       Brief backgroundings almost never invalidate sockets, and resetting them
  //       is worse than leaving them — a stale socket gets caught by the
  //       adaptive heartbeat or authenticated reconnect takeover anyway.
  AppLifecycleState? _lastLifecycle;
  DateTime? _backgroundedAt;
  // A short screen lock should not tear down a healthy connection on unlock.
  static const _minBgForReset = Duration(minutes: 5);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final previous = _lastLifecycle;
    _lastLifecycle = state;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      // Real backgrounding starts the clock. inactive doesn't — it's the
      // ephemeral pre-state for every transition and would fire constantly.
      _backgroundedAt ??= dependencies.now();
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    if (!_started) return;
    // Re-announce the Dart share handler on every Activity resume. This is a
    // cheap second handshake for cached/headless-engine cases where the first
    // ready call happened before MainActivity attached.
    if (Platform.isAndroid) {
      unawaited(
        _chShare.invokeMethod<bool>('shareHandlerReady').then<void>(
          (_) {},
          onError: (Object _, StackTrace __) {},
        ),
      );
    }
    // Clear the background clock regardless of whether we reset.
    final bgStart = _backgroundedAt;
    _backgroundedAt = null;
    final wasBackgrounded = previous == AppLifecycleState.paused ||
        previous == AppLifecycleState.hidden ||
        previous == AppLifecycleState.detached;
    if (!wasBackgrounded) return; // transient inactive→resumed (SAF, dialogs)
    // Always flush any pending clipboard write when foregrounded — this is
    // cheap and safe regardless of how long the app was backgrounded.
    unawaited(_clipboard?.onResume());
    if (bgStart == null ||
        dependencies.now().difference(bgStart) < _minBgForReset) {
      return; // too brief — sockets are fine
    }
    _probeSessionsOnResume();
  }

  /// Validate existing sessions after a long suspension without destroying
  /// healthy sockets. An immediate heartbeat probe is followed by a second
  /// probe; only sessions that miss both are torn down and redialled.
  void _probeSessionsOnResume() {
    final candidates = <String, PeerSession>{};
    for (final id in _registry.readyPeerIds) {
      final session = _registry.openSessionFor(id);
      if (session == null) continue;
      candidates[id] = session;
      session.probeHeartbeatNow();
    }

    _activateNetworkRecovery(const Duration(seconds: 20));
    _discovery?.reannounce();
    _supervisor.retryNow();

    _resumeProbeTimer?.cancel();
    _resumeProbeTimer = Timer(const Duration(seconds: 3), () {
      for (final entry in candidates.entries) {
        final current = _registry.openSessionFor(entry.key);
        if (!identical(current, entry.value)) continue;
        current?.probeHeartbeatNow();
      }
      _resumeProbeTimer = Timer(const Duration(seconds: 2), () {
        var dropped = 0;
        for (final entry in candidates.entries) {
          final current = _registry.openSessionFor(entry.key);
          if (!identical(current, entry.value)) continue;
          if (current!.missedHeartbeats < 2) continue;
          if (_dropSessionForReconnect(
            entry.key,
            current,
            reason: 'resume_probe_failed',
          )) {
            dropped++;
          }
        }
        Diag.session('resume_probe_complete', fields: {
          'probed': candidates.length,
          'dropped': dropped,
        });
        _discovery?.reannounce();
        _supervisor.retryNow();
        _applyBeaconMode();
        notifyListeners();
      });
    });
  }

  void _onHostInterfaceChanged() {
    if (!_networkingReady) return;
    Diag.log('host_network_interfaces_changed');
    _cancelNetworkReannounces();
    _activateNetworkRecovery(const Duration(seconds: 30));
    _invalidateLanSessionsForNetworkChange('host_interface_change');
    _supervisor.retryNow();
    _discovery?.reannounce();
    _scheduleNetworkReannounce(
      const Duration(seconds: 3),
      retryConnections: true,
    );
    _applyBeaconMode();
    notifyListeners();
  }

  Future<dynamic> _onNativeNetworkCall(MethodCall call) async {
    if (call.method != 'networkChanged') return null;
    final raw = call.arguments;
    if (raw is! Map) return null;
    final event = Map<String, dynamic>.from(raw);
    if (!_networkingReady) {
      _pendingNativeNetworkEvent = event;
      return null;
    }
    _handleNativeNetworkEvent(event);
    return null;
  }

  void _handleNativeNetworkEvent(Map<String, dynamic> event) {
    final available = event['available'] == true;
    final generation = (event['generation'] as num?)?.toInt() ?? 0;
    final reason = event['reason']?.toString() ?? 'unknown';
    final epoch = event['epoch']?.toString() ?? 'legacy';
    final previousGeneration = _lastNativeNetworkGeneration;
    final previousEpoch = _lastNativeNetworkEpoch;
    final routeChanged = available &&
        previousEpoch != null &&
        (epoch != previousEpoch || generation > (previousGeneration ?? -1));
    _lastNativeNetworkEpoch = epoch;
    _lastNativeNetworkGeneration = generation;

    Diag.log('android_network_event', fields: {
      'available': available,
      'generation': generation,
      'reason': reason,
      'epoch': epoch,
      'routeChanged': routeChanged,
    });

    if (!available) {
      _activateNetworkRecovery(const Duration(seconds: 20));
      _applyBeaconMode();
      return;
    }

    _cancelNetworkReannounces();
    _activateNetworkRecovery(const Duration(seconds: 45));
    if (routeChanged) {
      _invalidateLanSessionsForNetworkChange(reason);
    }

    // Rebind UDP discovery to the new interface before broadcasting. Android
    // can leave an any-address datagram socket attached to the old Wi-Fi link.
    unawaited((_discovery?.refreshNetwork() ?? Future<void>.value()).then((_) {
      _discovery?.reannounce();
      _supervisor.retryNow();
    }).catchError((Object error) {
      Diag.log('network_discovery_refresh_failed',
          fields: {'error': error.toString()});
    }));
    _supervisor.retryNow();
    if (_config.bluetoothEnabled) {
      unawaited(_bluetooth?.refreshDiscovery());
    }

    // Some routers need a moment to finish DHCP/routing after onAvailable.
    // Reannounce twice without bypassing supervisor backoff in a tight loop.
    _scheduleNetworkReannounce(const Duration(seconds: 2));
    _scheduleNetworkReannounce(
      const Duration(seconds: 8),
      retryConnections: true,
    );
    _applyBeaconMode();
    notifyListeners();
  }

  void _cancelNetworkReannounces() {
    for (final timer in _networkReannounceTimers) {
      timer.cancel();
    }
    _networkReannounceTimers.clear();
  }

  void _scheduleNetworkReannounce(
    Duration delay, {
    bool retryConnections = false,
  }) {
    late final Timer timer;
    timer = Timer(delay, () {
      _networkReannounceTimers.remove(timer);
      if (!_networkingReady) return;
      _discovery?.reannounce();
      if (retryConnections) _supervisor.retryNow();
    });
    _networkReannounceTimers.add(timer);
  }

  void _startReconnectRecovery(String peerId, Duration duration) {
    // Reset discovery's own fast-mode clock. Calling setBeaconMode(fast) is not
    // enough when it has already backed off to one minute after a long outage.
    _discovery?.beginRecovery();
    _activateNetworkRecovery(duration);
    // Retry only the session that broke. Resetting every peer here turns one
    // disconnect into needless dial bursts toward unrelated offline devices.
    _supervisor.retryPeerNow(peerId);
  }

  void _activateNetworkRecovery(Duration duration) {
    _networkRecoveryActive = true;
    _networkRecoveryTimer?.cancel();
    _networkRecoveryTimer = Timer(duration, () {
      _networkRecoveryActive = false;
      _applyBeaconMode();
    });
    _applyBeaconMode();
  }

  void _invalidateLanSessionsForNetworkChange(String reason) {
    final sessions = <MapEntry<String, PeerSession>>[];
    for (final id in _registry.connectedPeerIds) {
      final session = _registry.sessionFor(id);
      if (session != null && session.transport == ConnectionTransport.lan) {
        sessions.add(MapEntry(id, session));
      }
    }
    var dropped = 0;
    for (final entry in sessions) {
      if (_dropSessionForReconnect(
        entry.key,
        entry.value,
        reason: 'network_change:$reason',
      )) {
        dropped++;
      }
    }
    Diag.session('network_sessions_invalidated', fields: {
      'reason': reason,
      'dropped': dropped,
    });
  }

  bool _dropSessionForReconnect(
    String id,
    PeerSession session, {
    required String reason,
  }) {
    if (!_registry.drop(id, session)) return false;
    final wasReady = session.hasReceivedLinkReady;
    session.stopHeartbeat();
    _engine.onPeerSessionLost(id);
    if (wasReady) {
      _engine.onPeerDisconnected(id);
      final dashboard = getOrCreateDashboardState(id);
      dashboard.lastDisconnectedAt = dependencies.now();
      _persistDashboardState(id);
    }
    _supervisor.noteDisconnected(id);
    unawaited(session.close().catchError((Object _) {}));
    _clipboard?.onPeerConnectivityChanged();
    Diag.session('session_dropped_for_reconnect',
        peer: id,
        session: session.generation,
        fields: {'reason': reason});
    return true;
  }

  void _notifyHighFrequency() {
    _highFrequencyUiTimer ??= Timer(const Duration(milliseconds: 120), () {
      _highFrequencyUiTimer = null;
      notifyListeners();
    });
  }

  // ---- Folder pair management -------------------------------------------

  Future<FolderPair> createFolderPair(FolderPairDraft draft) async {
    final pair = draft.materialize(DeviceIdentity.uuid.v4());
    await _config.upsertPair(pair);
    try {
      await _engine.startPair(pair);
    } catch (_) {
      await _config.removePair(pair.id);
      rethrow;
    }
    notifyListeners();
    return pair;
  }

  /// Replaces a pair configuration and restarts its watcher/engine so no
  /// closure can retain the previous path, direction, peer, or rules.
  Future<void> updateFolderPair(
    String pairId,
    FolderPairDraft draft,
  ) async {
    final previous = _config.folderPairs
        .cast<FolderPair?>()
        .firstWhere((pair) => pair?.id == pairId, orElse: () => null);
    if (previous == null) {
      throw StateError('Folder pair $pairId no longer exists.');
    }
    final updated = draft.materialize(pairId);
    await _engine.stopPair(pairId);
    await _config.upsertPair(updated);
    try {
      await _engine.startPair(updated);
    } catch (_) {
      await _config.upsertPair(previous);
      try {
        await _engine.startPair(previous);
      } catch (rollbackError) {
        Diag.log(
          'folder_pair_update_rollback_error',
          fields: {'pairId': pairId, 'error': rollbackError.toString()},
        );
      }
      rethrow;
    }
    notifyListeners();
  }

  /// Add a folder pair locally (used by the "Add synced folder" flow on the
  /// initiating device, BEFORE sending the invite). The UI then calls
  /// [invitePeerToFolder] to send it to the connected peer.
  @Deprecated('Use createFolderPair or updateFolderPair explicitly.')
  Future<void> addFolderPair(FolderPair pair) async {
    final exists = _config.folderPairs.any((item) => item.id == pair.id);
    final draft = FolderPairDraft.fromPair(pair);
    if (exists) {
      await updateFolderPair(pair.id, draft);
    } else {
      await _config.upsertPair(pair);
      try {
        await _engine.startPair(pair);
      } catch (_) {
        await _config.removePair(pair.id);
        rethrow;
      }
      notifyListeners();
    }
  }

  /// Update a pair's ignore rules (Roadmap Phase 6.2) and take effect
  /// immediately.
  ///
  /// Deliberately NOT built on [addFolderPair]/`copyWith`+persist alone:
  /// `engine.startPair(pair)` closes over the `FolderPair` object in the
  /// watcher's change-listener and the periodic-reconcile timer, so simply
  /// re-persisting a changed pair to config would leave those already-running
  /// closures using the OLD rules until the app restarts (confirmed
  /// 2026-07-11 while investigating this feature — the same latent gap
  /// already exists for the pre-existing name/path/direction edit dialog,
  /// out of scope to fix here). `stopPair` + `startPair` is the same
  /// restart-the-watcher pattern already relied on when a pair is first
  /// added, and is explicitly designed to be safe to call in that sequence
  /// (cancels the watcher/timer, closes + drops the Index DB handle, drops
  /// per-pair V2 bookkeeping, then a fresh `startPair` reopens everything and
  /// reseeds via one scan).
  Future<void> updateIgnoreRules(
    String pairId, {
    required List<String> ignoreGlobs,
    required List<String> ignoreExtensions,
    int? maxFileSizeBytes,
  }) async {
    final existing = _config.folderPairs
        .cast<FolderPair?>()
        .firstWhere((p) => p?.id == pairId, orElse: () => null);
    if (existing == null) return;
    final updated = FolderPair(
      id: existing.id,
      name: existing.name,
      localPath: existing.localPath,
      direction: existing.direction,
      peerDeviceId: existing.peerDeviceId,
      ignoreGlobs: ignoreGlobs,
      ignoreExtensions: ignoreExtensions,
      maxFileSizeBytes: maxFileSizeBytes,
    );
    await updateFolderPair(pairId, FolderPairDraft.fromPair(updated));
  }

  /// Lists this pair's vault catalog for the version-history screen,
  /// most-recent-first.
  Future<List<VaultLogEntry>> vaultEntries(FolderPair pair) =>
      _engine.vaultEntries(pair);

  /// Restores [entry]'s vaulted bytes back to their live path.
  ///
  /// The engine holds the pair's scan guard from the filesystem write through
  /// index resurrection, so a watcher cannot mistake the restored bytes for
  /// an orphan belonging to the previous tombstone.
  Future<RestoreResult> restoreVersion(
    FolderPair pair,
    VaultLogEntry entry,
  ) async {
    final result = await _engine.restoreVaultEntry(pair, entry);
    notifyListeners();
    return result;
  }

  Future<VaultDeletionResult> deleteVaultEntries(
    FolderPair pair,
    Iterable<VaultLogEntry> entries,
  ) async {
    final result = await _engine.deleteVaultEntries(pair, entries);
    notifyListeners();
    return result;
  }

  Future<void> removeFolderPair(String id) async {
    await _engine.stopPair(id);
    _engine.forgetPeerAccepted(id);
    await _config.removePair(id);
    notifyListeners();
  }

  /// Send a folder-pair invite for [pairId] to the connected peer. The peer
  /// surfaces an accept dialog; on accept both sides share the pairId.
  void invitePeerToFolder(String pairId) {
    final pair = _config.folderPairs
        .cast<FolderPair?>()
        .firstWhere((p) => p?.id == pairId, orElse: () => null);
    if (pair == null) return;
    _engine.sendFolderInvite(pair);
    notifyListeners();
  }

  /// Accept the current [pendingInvite]. [localPath] is the folder the user
  /// picked on this device.
  Future<void> acceptInvite(FolderPairInvite invite, String localPath) async {
    await _engine.acceptFolderInvite(invite, localPath);
    if (_pendingInvite?.pairId == invite.pairId) {
      _consumePendingInvite();
    }
    notifyListeners();
  }

  /// Decline the current [pendingInvite].
  void declineInvite(String pairId) {
    _engine.declineFolderInvite(pairId);
    if (_pendingInvite?.pairId == pairId) {
      _consumePendingInvite();
    }
    notifyListeners();
  }

  /// Forcibly disconnect from a connected peer. Sends a `bye` (handled by the
  /// peer's engine) and closes our socket. Marks the peer suppressed so the
  /// supervisor and beacons don't immediately reconnect — the disconnect is
  /// honored until the user reconnects explicitly.
  Future<void> disconnectPeer(String deviceId) async {
    final session = _registry.sessionFor(deviceId);
    if (session != null) {
      _registry.drop(deviceId, session);
      session.stopHeartbeat();
      _engine.onPeerSessionLost(deviceId); // cancel in-flight sync work
      _engine.onPeerDisconnected(deviceId);
      await session.close();
    }
    _suppressedPeerIds.add(deviceId); // honor the disconnect
    _applyBeaconMode(); // Phase 0.3
    notifyListeners();
  }

  Future<void> reconnectPeer(PairedPeer peer) async {
    _suppressedPeerIds.remove(peer.deviceId);
    final existing = _registry.openSessionFor(peer.deviceId);
    if (existing != null) return;
    final targets = <DiscoveredPeer>[
      if (_discoveredPeers[peer.deviceId] ??
              _discoveredPeerFromSavedEndpoint(peer)
          case final target?)
        target,
      ..._bluetoothPeers.values.where((p) => p.deviceId == peer.deviceId),
    ];
    if (targets.isEmpty) {
      throw StateError(
          'No LAN or Bluetooth route for ${peer.name}. Open Conduit on that device.');
    }
    if (_connectingPeerIds.contains(peer.deviceId)) return;
    _setConnecting(_connectingPeerIds, peer.deviceId, true);
    try {
      Object? lastError;
      for (final target in targets) {
        try {
          final session = await _connectTarget(target, forceTakeover: true);
          await _rememberSessionEndpoint(session, target);
          return;
        } catch (e) {
          lastError = e;
        }
      }
      throw lastError ?? StateError('No route connected');
    } finally {
      _setConnecting(_connectingPeerIds, peer.deviceId, false);
      notifyListeners();
    }
  }

  Future<void> unpairPeer(String deviceId) async {
    final session = _registry.sessionFor(deviceId);
    if (session != null) {
      _registry.drop(deviceId, session);
      session.stopHeartbeat();
      _engine.onPeerSessionLost(deviceId);
      _engine.onPeerDisconnected(deviceId);
      await session.close();
    }
    _suppressedPeerIds.add(deviceId);
    _discoveredPeers.remove(deviceId);
    _dashboardStates.remove(deviceId);
    await _config.removeDeviceStatusSnapshot(deviceId);
    await _config.forgetPeer(deviceId);
    await _transferReceipts?.deleteByPeer(deviceId);
    _applyBeaconMode();
    notifyListeners();
  }

  Future<void> renameDevice(String newName) async {
    await _identity.rename(newName);
    // Re-broadcast under the new name immediately.
    notifyListeners();
  }

  // ---- Phase 0.4 + Phase 1: background survival & lifecycle ---------------
  //
  // The Android foreground service + transfer-tied wake lock are driven over
  // method channels; on Windows these channels simply don't exist, so the calls
  // are no-ops guarded by Platform.isAndroid. The sync engine itself never
  // touches a method channel — it only flips the [SyncEngine.onTransferState]
  // callback, which AppState routes here. This keeps the engine engine-safe
  // (no platform coupling) and the battery wiring in one place.

  static const _chSync = MethodChannel('conduit/sync_service');
  static const _chWakelock = MethodChannel('conduit/wakelock');
  static const _chPhoneDashboard = MethodChannel('conduit/phone_dashboard');
  static const _chNetworkEvents = MethodChannel('conduit/network_events');
  // Phase 3d: share channel — native pushes content:// or file-path URIs when
  // the user shares into Conduit from another app (Android share sheet) or
  // the Windows "Send to" context menu.
  static const _chShare = MethodChannel('conduit/share_receive');
  // Phase 3d (Windows): shell helpers ("Send to" shortcut creation).
  static const _chShell = MethodChannel('conduit/shell');

  /// The set of paired peer device ids — used by ClipboardSync to decide which
  /// live sessions are valid clipboard destinations (we never push to / accept
  /// from an unpaired peer).
  Set<String> _pairedPeerIds() {
    return _config.pairedPeers.map((p) => p.deviceId).toSet();
  }

  // Phase 3d ---------------------------------------------------------------

  bool isPairAcceptedByPeer(String pairId) =>
      _engine.isPairAcceptedByPeer(pairId);

  bool peerHasFeature(String peerId, String feature) {
    final session = _registry.openSessionFor(peerId);
    return session?.features.contains(feature) == true;
  }

  bool get allowPlayPhoneAlert => _config.allowPlayPhoneAlert;

  Future<void> setAllowPlayPhoneAlert(bool value) async {
    await _config.setAllowPlayPhoneAlert(value);
    if (Platform.isAndroid) {
      await _chPhoneDashboard
          .invokeMethod<void>('setPhoneAlertEnabled', {'enabled': value});
    }
    notifyListeners();
  }

  Future<void> _persistDashboardState(String deviceId) async {
    final dstate = _dashboardStates[deviceId];
    if (dstate == null) return;
    final map = <String, dynamic>{
      if (dstate.batteryPct != null) 'batteryPct': dstate.batteryPct,
      if (dstate.powerState != null) 'powerState': dstate.powerState,
      if (dstate.storageAvailableBytes != null)
        'storageAvailableBytes': dstate.storageAvailableBytes,
      if (dstate.storageTotalBytes != null)
        'storageTotalBytes': dstate.storageTotalBytes,
      if (dstate.conduitHealth != null) 'conduitHealth': dstate.conduitHealth,
      if (dstate.pairHealth != null) 'pairHealth': dstate.pairHealth,
      if (dstate.statusReceivedAt != null)
        'statusReceivedAt': dstate.statusReceivedAt!.toIso8601String(),
      if (dstate.lastSeenAt != null)
        'lastSeenAt': dstate.lastSeenAt!.toIso8601String(),
      if (dstate.lastDisconnectedAt != null)
        'lastDisconnectedAt': dstate.lastDisconnectedAt!.toIso8601String(),
      if (dstate.connectedAt != null)
        'connectedAt': dstate.connectedAt!.toIso8601String(),
    };
    await _config.saveDeviceStatusSnapshot(deviceId, map);
  }

  void _onDeviceStatusReceived(String peerId, Map<String, dynamic> msg) {
    final schema = msg['schema'] as int?;
    if (schema != 1) {
      Diag.log('device_status_ignored',
          fields: {'reason': 'unknown schema $schema', 'peer': peerId});
      return;
    }
    final dstate = getOrCreateDashboardState(peerId);
    dstate.batteryPct = msg['batteryPct'] as int?;
    dstate.powerState = msg['power'] as String?;
    dstate.storageAvailableBytes = msg['storageAvailableBytes'] as int?;
    dstate.storageTotalBytes = msg['storageTotalBytes'] as int?;
    dstate.conduitHealth = msg['conduitHealth'] as Map<String, dynamic>?;
    dstate.pairHealth = msg['pairHealth'] as Map<String, dynamic>?;
    dstate.statusReceivedAt = DateTime.now();
    dstate.lastSeenAt = DateTime.now();

    _persistDashboardState(peerId);
    notifyListeners();
  }

  Future<void> _onPhoneActionReceived(
      String peerId, String requestId, String action) async {
    if (action == 'play_alert') {
      final session = _registry.openSessionFor(peerId);
      if (session == null || !session.isLinkReady) return;

      String result = 'failed';
      try {
        final bool allowed = _config.allowPlayPhoneAlert;
        if (!allowed) {
          result = 'disabled';
        } else {
          final res =
              await _chPhoneDashboard.invokeMethod<String>('playPhoneAlert');
          result = res ?? 'failed';
        }
      } catch (e) {
        result = 'failed';
      }

      try {
        session.send({
          't': Msg.phoneActionResult,
          'requestId': requestId,
          'action': 'play_alert',
          'result': result,
        });
      } catch (e) {
        Diag.log('phone_action_result_send_error',
            fields: {'peer': peerId, 'error': e.toString()});
      }
    }
  }

  void _onPhoneActionResultReceived(
      String peerId, String requestId, String action, String result) {
    final completer = _pendingAlertCompleters.remove(requestId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(result);
    }
  }

  void _startAndroidStatusSampling() {
    if (Platform.isAndroid) {
      _androidStatusTimer?.cancel();
      _androidStatusTimer = Timer.periodic(
          const Duration(minutes: 5), (_) => _sampleAndSendStatusIfNeeded());
      _sampleAndSendStatusIfNeeded(forceFull: true);
    }
  }

  void _stopAndroidStatusSampling() {
    _androidStatusTimer?.cancel();
    _androidStatusTimer = null;
    _lastSentStatus = null;
    _lastFullRefreshTime = null;
  }

  Future<void> _sampleAndSendStatusIfNeeded({bool forceFull = false}) async {
    if (!Platform.isAndroid) return;
    if (_registry.readyPeerIds.isEmpty) return;

    try {
      final res = await _chPhoneDashboard
          .invokeMethod<Map<dynamic, dynamic>>('getDeviceStatus');
      if (res == null) return;

      final current = Map<String, dynamic>.from(res);
      bool shouldSend = false;
      final now = DateTime.now();

      if (forceFull ||
          _lastSentStatus == null ||
          _lastFullRefreshTime == null) {
        shouldSend = true;
      } else {
        final lastBatteryPct = _lastSentStatus!['batteryPct'] as int?;
        final currentBatteryPct = current['batteryPct'] as int?;
        final lastPower = _lastSentStatus!['power'] as String?;
        final currentPower = current['power'] as String?;

        if (lastBatteryPct != currentBatteryPct || lastPower != currentPower) {
          shouldSend = true;
        }

        if (now.difference(_lastFullRefreshTime!) >=
            const Duration(minutes: 10)) {
          shouldSend = true;
        }
      }

      if (shouldSend) {
        final isFullRefresh = _lastFullRefreshTime == null ||
            now.difference(_lastFullRefreshTime!) >=
                const Duration(minutes: 10) ||
            forceFull;
        if (isFullRefresh) {
          _lastFullRefreshTime = now;
        }

        final msg = <String, dynamic>{
          't': Msg.deviceStatus,
          'schema': 1,
          'batteryPct': current['batteryPct'],
          'power': current['power'],
        };

        if (isFullRefresh) {
          msg['storageAvailableBytes'] = current['storageAvailableBytes'];
          msg['storageTotalBytes'] = current['storageTotalBytes'];
          msg['conduitHealth'] = <String, dynamic>{
            'powerSaverMode': current['powerSaverMode'],
            'batteryOptimizationWarning': current['batteryOptimizationWarning'],
            'isServiceRunning': true,
          };
          msg['pairHealth'] = <String, dynamic>{};
        } else {
          if (_lastSentStatus != null) {
            msg['storageAvailableBytes'] =
                _lastSentStatus!['storageAvailableBytes'];
            msg['storageTotalBytes'] = _lastSentStatus!['storageTotalBytes'];
            msg['conduitHealth'] = _lastSentStatus!['conduitHealth'];
            msg['pairHealth'] = _lastSentStatus!['pairHealth'];
          }
        }

        _lastSentStatus = msg;

        for (final peerId in _registry.readyPeerIds) {
          final session = _registry.openSessionFor(peerId);
          if (session != null &&
              session.isLinkReady &&
              session.features.contains('device_status_v1')) {
            try {
              session.send(msg);
            } catch (e) {
              Diag.log('device_status_send_error',
                  fields: {'peer': peerId, 'error': e.toString()});
            }
          }
        }
      }
    } catch (e) {
      Diag.log('device_status_sample_error', fields: {'error': e.toString()});
    }
  }

  Future<String> playPhoneAlert(String peerId) async {
    final session = _registry.openSessionFor(peerId);
    if (session == null || !session.isLinkReady) {
      return 'offline';
    }
    if (!session.features.contains('phone_alert_v1')) {
      return 'unsupported';
    }

    final requestId =
        '${DateTime.now().millisecondsSinceEpoch}-${_alertIdCounter++}';
    final completer = Completer<String>();
    _pendingAlertCompleters[requestId] = completer;

    try {
      session.send({
        't': Msg.phoneAction,
        'requestId': requestId,
        'action': 'play_alert',
      });
    } catch (e) {
      _pendingAlertCompleters.remove(requestId);
      return 'failed';
    }

    return completer.future.timeout(const Duration(seconds: 10), onTimeout: () {
      _pendingAlertCompleters.remove(requestId);
      return 'timeout';
    });
  }

  /// Subscribe to the native→Dart share channel. Called once in [start].
  /// On Android: the method channel receives content:// URIs from the share
  /// sheet intent. On Windows: file-system paths from the --send CLI arg or
  /// WM_COPYDATA forwarding from a second instance.
  void _subscribeShareChannel() {
    _chShare.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'incomingFiles':
          final uris = (call.arguments as Map)['uris'];
          if (uris is List && uris.isNotEmpty) {
            await _onIncomingSharedFiles(uris.cast<String>());
          }
          break;
        case 'shareHostAttached':
          // MainActivity can be recreated while the cached FlutterEngine and
          // this AppState remain alive. Re-acknowledge every new native host so
          // share URIs buffered by that Activity are flushed to this handler.
          if (Platform.isAndroid) await _announceAndroidShareHandlerReady();
          break;
      }
    });
    if (Platform.isWindows) {
      _chShell.invokeMethod<bool>('shareHandlerReady').catchError((_) => false);
    } else if (Platform.isAndroid) {
      unawaited(_announceAndroidShareHandlerReady());
    }
  }

  Future<void> _announceAndroidShareHandlerReady() async {
    try {
      await _chShare.invokeMethod<bool>('shareHandlerReady');
    } catch (e) {
      // A headless engine can start before MainActivity installs its channel.
      // The Activity's shareHostAttached callback retries after it attaches.
      Diag.log('share_handler_ready_deferred', fields: {'error': e.toString()});
    }
  }

  /// Handles a list of URIs / paths delivered by the OS share/send mechanism.
  ///
  /// On Android each entry is a `content://` URI; on Windows each is a
  /// file-system path. Resolves each to (name, bytes) then either:
  ///   - auto-sends to the single connected peer (1 peer connected), or
  ///   - queues them in [pendingSharedFiles] and notifies the UI to open the
  ///     Send panel with the peer-picker (0 or 2+ peers connected).
  Future<void> _onIncomingSharedFiles(List<String> uris) async {
    final resolved = <PendingSharedFile>[];
    for (final uri in uris) {
      try {
        if (Platform.isAndroid) {
          // Resolve display name from the ContentProvider.
          final name = await const MethodChannel('conduit/saf')
                  .invokeMethod<String>('getSharedUriName', {'uri': uri}) ??
              uri.split('/').last;
          // Resolve size from the ContentProvider (Polish / connection-loss fix).
          // Eagerly query only the size metadata, NOT the file bytes.
          final size = await const MethodChannel('conduit/saf')
                  .invokeMethod<int>('getSharedUriSize', {'uri': uri}) ??
              0;
          resolved.add(PendingSharedFile(
            name: name,
            safUri: uri,
            size: size,
          ));
        } else if (Platform.isWindows) {
          // uri is a plain file-system path on Windows.
          final file = File(uri);
          if (await file.exists()) {
            final size = await file.length();
            resolved.add(PendingSharedFile(
              name: p.basename(uri),
              filePath: uri,
              size: size,
            ));
          }
        }
      } catch (e) {
        Diag.log('share_receive_error',
            fields: {'uri': uri, 'error': e.toString()});
      }
    }
    if (resolved.isEmpty) return;

    final peers = connectedPeers;
    // Always route OS share/send through the Send panel. If exactly one peer is
    // live, the panel auto-starts after rendering so the sender still sees a
    // real progress indicator instead of a silent background transfer.
    _pendingSharedFiles = resolved;
    _pendingSharedFilesAutoStart = peers.length == 1;
    // Roadmap Phase 4: a Windows "Send to Conduit" (or share-sheet) delivery
    // pops the compact send widget instead of forcing the full dashboard
    // open just to push one file — see SendWidgetScreen and
    // DashboardScreen's sendWidgetMode branch. Android has no window to
    // shrink, so it keeps the existing full-screen Send-tab navigation
    // unconditionally.
    if (Platform.isWindows) {
      _sendWidgetMode = true;
      try {
        // Eagerly show and focus the window to wake up the Flutter engine/renderer
        // immediately, ensuring the first frame paints and the build runs without delay.
        windowManager.show().then((_) => windowManager.focus());
      } catch (_) {}
    }
    notifyListeners();
  }

  // -------------------------------------------------------------------------

  /// Engine → host: a peer pushed its clipboard (Phase 2). Hand off to
  /// ClipboardSync, which writes our local clipboard if the feature is on.
  /// Engine-safe: this runs from the appended clipboardPush branch only.
  ///
  /// On Android, if the OS silently blocks the background clipboard write,
  /// ClipboardSync stores the text as a pending write. We only fire a
  /// notification in that case — a successful write happens silently.
  /// onResume() commits the pending write the moment the app is foregrounded.
  Future<void> _onClipboardPushReceived(String peerId, String text) async {
    final sync = _clipboard;
    if (sync == null) return;
    await sync.onPushReceived(peerId, text);
    // Only notify if the write was blocked (pending text still set after the
    // attempt). A successful write clears pendingRemoteText immediately.
    if (Platform.isAndroid && sync.pendingRemoteText != null) {
      final peerName = _peerNameFor(peerId);
      final preview = text.length > 40 ? '${text.substring(0, 40)}…' : text;
      unawaited(_notifier.showClipboardSyncReceived(preview, peerName));
    }
  }

  /// A clipboard-enabled peer asks this device to send its current clipboard.
  /// Only desktop fulfills this automatically because Android background
  /// clipboard reads are restricted by the OS.
  void _onClipboardRequestReceived(String peerId) {
    if (!_config.clipboardSyncEnabled || !Platform.isWindows) return;
    unawaited(_clipboard?.sendCurrentClipboard(targetPeerId: peerId));
  }

  /// ClipboardSync → host: a peer's clipboard just landed locally. Surface a
  /// CONTENT-FREE event to the activity feed — never the clipboard text.
  void _onClipboardRemoteReceived(String peerId) {
    final name = _peerNameFor(peerId);
    final ev = SyncEvent(
        DateTime.now(),
        'clipboard',
        'Clipboard received${name.isEmpty ? '' : ' from $name'}',
        SyncEventLevel.info);
    _events.insert(0, ev);
    if (_events.length > 500) _events.removeRange(500, _events.length);
    notifyListeners();
  }

  /// Best-effort friendly name for a peer id, for content-free log lines.
  String _peerNameFor(String peerId) {
    final match = _config.pairedPeers.where((p) => p.deviceId == peerId);
    return match.isEmpty ? '' : match.first.name;
  }

  /// UI → host: toggle clipboard sync on/off.
  Future<void> setClipboardSyncEnabled(bool enabled) async {
    await _config.setClipboardSyncEnabled(enabled);
    _clipboard?.setEnabled(enabled);
    _applyBeaconMode();
    notifyListeners();
  }

  /// Whether the Android persistent notification is shown with a status-bar
  /// icon. Always true on non-Android (setting has no effect there).
  bool get showPersistentNotification => _config.showPersistentNotification;

  /// Toggle the notification visibility. Persists the preference and
  /// immediately applies it to the running foreground service via the method
  /// channel so the user sees the change without restarting the app.
  Future<void> setShowPersistentNotification(bool visible) async {
    await _config.setShowPersistentNotification(visible);
    if (Platform.isAndroid) {
      _chSync.invokeMethod<void>('setNotificationVisibility',
          {'visible': visible}).catchError((Object e) {
        Diag.log('notif_visibility_error', fields: {'error': e.toString()});
      });
    }
    notifyListeners();
  }

  /// Whether battery-saver mode is on (event-led SAF watching with one
  /// eight-hour fallback while connected and no offline traversal).
  bool get batterySaverMode => _config.batterySaverMode;

  /// Toggle battery-saver mode. Persists the preference and immediately
  /// applies the new watcher interval to all running folder watchers.
  Future<void> setBatterySaverMode(bool enabled) async {
    await _config.setBatterySaverMode(enabled);
    _engine.setBatterySaverMode(enabled);
    _applyBeaconMode();
    notifyListeners();
  }

  /// UI → host: manual "send my clipboard now".
  Future<bool> sendClipboard({String? targetPeerId}) =>
      _clipboard?.sendCurrentClipboard(targetPeerId: targetPeerId) ??
      Future.value(false);

  // ---- Phase 4: remote command -----------------------------------------------

  /// True if the PC has remote command execution enabled.
  bool get remoteControlEnabled => _config.remoteControlEnabled;

  /// Toggle remote command execution on the PC side. Also updates the
  /// [RemoteCommandExecutor] so already-running sessions pick it up immediately.
  Future<void> setRemoteControlEnabled(bool enabled) async {
    await _config.setRemoteControlEnabled(enabled);
    _remoteCmd?.enabled = enabled;
    notifyListeners();
  }

  /// Phone UI → host: send a named command to one explicitly selected peer.
  /// The PC peer validates the name against its allowlist and executes it only
  /// if remote control is enabled there. Engine-safe: sends a plain
  /// [Msg.runCommand] frame; never touches the sync engine's state.
  Future<void> sendRemoteCommand(
    String name, {
    required String targetPeerId,
  }) async {
    final session = _registry.openSessionFor(targetPeerId);
    if (session == null || !session.isLinkReady) return;
    final frame = <String, dynamic>{'t': Msg.runCommand, 'name': name};
    try {
      session.send(frame);
    } catch (e) {
      Diag.log('remote_cmd_send_error',
          fields: {'name': name, 'peer': targetPeerId, 'error': '$e'});
    }
  }

  /// Engine → host: a peer sent a remote-control command (Phase 4).
  /// Only acts on Windows; silently ignored on Android (the phone side sends,
  /// the PC side receives).
  void _onRunCommandReceived(String peerId, String name) {
    _remoteCmd?.execute(name);
  }

  // ---- Phase 3a: ad-hoc file send ------------------------------------------

  /// The path where auto-received files land. Null until first configured.
  String? get receivedFilesPath => _config.receivedFilesPath;

  /// Persist a new received-files destination (called from Settings).
  Future<void> setReceivedFilesPath(String path) async {
    await _config.setReceivedFilesPath(path);
    notifyListeners();
  }

  /// Resolve the received-files path, creating a default if none is set.
  ///
  /// Default: `<Documents>\Sync\` on Windows, or null on Android (the user
  /// must pick a SAF tree URI via Settings before files can be received).
  /// Once set, it is remembered in config until changed.
  String? _resolveReceivedFilesPath() {
    final stored = _config.receivedFilesPath;
    if (stored != null && stored.isNotEmpty) return stored;
    // Windows: auto-create a default Sync directory under user Documents.
    if (Platform.isWindows) {
      final docs = Platform.environment['USERPROFILE'] ?? 'C:\\Users\\Public';
      final dir = Directory(p.join(docs, 'Documents', 'Sync'));
      if (!dir.existsSync()) {
        try {
          dir.createSync(recursive: true);
        } catch (_) {}
      }
      final path = dir.path;
      // Persist so future calls are instant.
      _config.setReceivedFilesPath(path).catchError((_) {});
      return path;
    }
    // Android: SAF requires an explicit tree URI from the user — can't
    // auto-create without a picker. Return null; the UI (Settings) guides
    // the user to pick the Sync folder.
    return null;
  }

  /// Send an ad-hoc file to the currently connected peer.
  /// Supports:
  ///   - [fileBytes] (already in memory, from in-app picker).
  ///   - [safUri] (Android content:// URI, streamed block-by-block).
  ///   - [filePath] (Windows local path, streamed block-by-block).
  ///
  /// Returns false if no peer session is available or if no valid source is provided.
  Future<bool> sendAdHocFile({
    required String peerId,
    required String fileName,
    List<int>? fileBytes,
    String? safUri,
    String? filePath,
    int? fileSize,
    void Function(bool success)? onComplete,
    void Function(int sent, int total)? onProgress,
  }) async {
    final session = _registry.openSessionFor(peerId);
    if (session == null || !session.isLinkReady) return false;
    if (_adHoc == null) return false;
    _lastTransferBlockReason = null;
    var effectiveSize = fileSize ?? fileBytes?.length ?? 0;
    if (effectiveSize <= 0 && filePath != null) {
      try {
        effectiveSize = await File(filePath).length();
      } catch (_) {}
    }
    if (session.isBandwidthConstrained &&
        effectiveSize > bluetoothLargeTransferLimitBytes) {
      _lastTransferBlockReason =
          'This file is larger than 10 MiB. Large transfers are paused on '
          'Bluetooth and will be available when LAN reconnects.';
      notifyListeners();
      return false;
    }
    var transferSucceeded = false;
    var lastProgressUiAt = DateTime.fromMillisecondsSinceEpoch(0);

    void done(bool ok) {
      transferSucceeded = ok;
      if (ok) {
        // Content-free Activity event (never logs file contents).
        final peerName = _peerNameFor(peerId);
        final ev = SyncEvent(
          DateTime.now(),
          'adhoc',
          'File sent: $fileName${peerName.isEmpty ? '' : ' to $peerName'}',
          SyncEventLevel.info,
        );
        _events.insert(0, ev);
        if (_events.length > 500) _events.removeRange(500, _events.length);
        notifyListeners();
      }
      onComplete?.call(ok);
    }

    void progressWrapper(int sent, int total) {
      // Update the Android status-bar notification.
      _adHoc!.notifier.showSendProgress(fileName, sent, total);
      // Notify the UI caller.
      final now = DateTime.now();
      if (sent >= total ||
          now.difference(lastProgressUiAt) >=
              const Duration(milliseconds: 100)) {
        lastProgressUiAt = now;
        onProgress?.call(sent, total);
      }
    }

    if (safUri != null) {
      await _adHoc!.sendFileFromSafUri(
        session: session,
        fileName: fileName,
        safUri: safUri,
        fileSize: fileSize ?? 0,
        onSendComplete: done,
        onProgress: progressWrapper,
        waitForCompletion: true,
      );
    } else if (filePath != null) {
      await _adHoc!.sendFileFromPath(
        session: session,
        fileName: fileName,
        filePath: filePath,
        onSendComplete: done,
        onProgress: progressWrapper,
        waitForCompletion: true,
      );
    } else if (fileBytes != null) {
      await _adHoc!.sendFile(
        session: session,
        fileName: fileName,
        fileBytes: fileBytes,
        onSendComplete: done,
        onProgress: progressWrapper,
        waitForCompletion: true,
      );
    } else {
      return false;
    }
    return transferSucceeded;
  }

  bool pauseAdHocTransfer(String peerId) =>
      _adHoc?.pauseOutboundForPeer(peerId) ?? false;

  bool resumeAdHocTransfer(String peerId) =>
      _adHoc?.resumeOutboundForPeer(peerId) ?? false;

  bool cancelAdHocTransfer(String peerId) =>
      _adHoc?.cancelOutboundForPeer(peerId) ?? false;

  /// Roadmap Phase 4: called by [SendWidgetScreen] once its compact window
  /// has been resized/moved back to normal (or the user dismissed it), so
  /// the dashboard shell reappears exactly where the user left it. AppState
  /// itself never touches window geometry — see desktop/tray.dart for that.
  void exitSendWidgetMode() {
    if (!_sendWidgetMode) return;
    _sendWidgetMode = false;
    notifyListeners();
  }

  /// Engine → host: bytes started/stopped moving (Phase 0.4). On Android we ask
  /// SyncService to acquire a short, renewable partial wake lock only while
  /// `transferring` is true, so Doze is free to take over on an idle folder.
  ///
  /// Post-audit fix: a burst now gets a periodic renewal (every 45s, same
  /// cadence as [_renewConnectionWakeLock]) for as long as it's active,
  /// instead of a single acquire at burst-start with no renewal. Without
  /// this, any burst lasting longer than the native lock's timeout silently
  /// lost wake-lock protection partway through — a multi-file sync over a
  /// slow link could easily run past that window.
  void _onTransferState(bool transferring) {
    if (!Platform.isAndroid) return;
    if (transferring) {
      _renewTransferWakeLock();
      _transferWakeLockRenewal ??= Timer.periodic(
        const Duration(seconds: 45),
        (_) => _renewTransferWakeLock(),
      );
      return;
    }

    _transferWakeLockRenewal?.cancel();
    _transferWakeLockRenewal = null;
    _chWakelock.invokeMethod<void>('release').catchError((Object e) {
      // Best-effort: a wakelock failure must never break a transfer.
      Diag.log('wakelock_error',
          fields: {'op': 'release', 'error': e.toString()});
    });
  }

  void _renewTransferWakeLock() {
    _chWakelock.invokeMethod<void>('acquire').catchError((Object e) {
      Diag.log('wakelock_error',
          fields: {'op': 'acquire', 'error': e.toString()});
    });
  }

  /// Start the Android foreground sync service (Phase 1). Idempotent and
  /// best-effort — non-Android platforms and any channel failure are swallowed.
  void _ensureBackgroundServiceRunning() {
    if (!Platform.isAndroid) return;
    _chSync.invokeMethod<void>('start').catchError((Object e) {
      Diag.log('fg_service_start_error', fields: {'error': e.toString()});
    });
  }

  /// Stop the Android foreground sync service. Used by [quit] on Android so the
  /// persistent notification clears on a real exit.
  void _stopBackgroundService() {
    if (!Platform.isAndroid) return;
    _chSync.invokeMethod<void>('stop').catchError((Object e) {
      Diag.log('fg_service_stop_error', fields: {'error': e.toString()});
    });
  }

  /// Open the system battery-optimization screen for Conduit (Phase 1 OEM
  /// guidance). On stock Android this launches the "Ignore battery
  /// optimizations" prompt directly; the Survival screen walks the user through
  /// the OEM-specific steps beyond that. No-op on non-Android.
  void openBatteryOptimizationSettings() {
    if (!Platform.isAndroid) return;
    _chSync.invokeMethod<void>('openBatterySettings').catchError((Object e) {
      Diag.log('battery_settings_error', fields: {'error': e.toString()});
    });
  }

  void openNotificationSettings() {
    if (!Platform.isAndroid) return;
    _chSync.invokeMethod<void>('openNotificationSettings').catchError(
      (Object e) {
        Diag.log(
          'notification_settings_error',
          fields: {'error': e.toString()},
        );
      },
    );
  }

  Future<void> requestBluetoothPermissions() async {
    if (!Platform.isAndroid) return;
    await _bluetooth?.requestPermissions();
  }

  int get listenerPort => _connections.listenPort;

  Future<void> setBluetoothEnabled(bool enabled) async {
    await _config.setBluetoothEnabled(enabled);
    if (enabled) {
      await _bluetooth?.requestPermissions();
      await _bluetooth?.start(dartListenPort: _connections.listenPort);
    } else {
      await _bluetooth?.stop();
      _bluetoothPeers.clear();
      // A disabled transport must not tear down a healthy LAN session.
      for (final peerId in _registry.openPeerIds.toList(growable: false)) {
        final session = _registry.openSessionFor(peerId);
        if (session?.transport == ConnectionTransport.bluetooth) {
          await disconnectPeer(peerId);
          _suppressedPeerIds.remove(peerId);
        }
      }
    }
    notifyListeners();
  }

  /// True while sync is paused (Roadmap Phase 1). Surfaced to the UI so the
  /// tray / a status chip can reflect it.
  bool get isPaused => _engine.isPaused;

  /// Pause all sync (Roadmap Phase 1). Future reconciles return immediately;
  /// in-flight transfers finish. Serving inbound pulls is unaffected.
  void pauseSync() {
    _engine.pauseSync();
    notifyListeners();
  }

  /// Resume sync after [pauseSync] (Roadmap Phase 1). Kicks a reconcile on
  /// every live pair so drift accrued while paused is caught up.
  void resumeSync() {
    _engine.resumeSync();
    notifyListeners();
  }

  Future<void> setOnboardingVersion(int version) async {
    await _config.setOnboardingVersion(version);
    notifyListeners();
  }

  /// INTENTIONAL quit (Roadmap Phase 1 — "Quit/exit" button). Tears the app
  /// down cleanly so the OS is free to reclaim it: stops the supervisor,
  /// discovery, connections, the foreground service, and the engine, then
  /// exits the process. This is distinct from close-to-tray (Windows) /
  /// backgrounding (Android), which keep the process alive. On Android this
  /// also stops the foreground service so the persistent notification clears.
  Future<void> quit() async {
    try {
      _setConnectionWakeLockEnabled(false);
      _connectionBoostTimer?.cancel();
      _connectionBoostRetryTimer?.cancel();
      _connectionBoostTimer = null;
      _connectionBoostRetryTimer = null;
      _connectionBoostUntil = null;
      _onTransferState(false); // cancel renewal timer + release, if held
      for (final timer in _bluetoothDialTimers.values) {
        timer.cancel();
      }
      _bluetoothDialTimers.clear();
      _windowsLanUpgradeTimer?.cancel();
      _windowsLanUpgradeTimer = null;
      _stopBackgroundService();
      if (_started) {
        _supervisor.stop();
        _discovery?.stop();
        await _bluetooth?.stop();
        _connections.stop();
        await _engine.dispose();
      }
    } catch (e) {
      Diag.log('quit_error', fields: {'error': e.toString()});
    } finally {
      // The actual process exit is performed by the caller (main.dart /
      // tray), because AppState shouldn't own process lifecycle. We only
      // guarantee that everything is torn down by the time it returns.
    }
  }

  // ---- Pairing ----------------------------------------------------------

  /// Called by the UI when the user taps "Pair" on a discovered peer.
  /// For first-time pairing we need a code the *peer* generated; the UI
  /// collects it from the user. Also clears any suppression for this peer —
  /// an explicit user connect overrides a prior explicit disconnect.
  Future<void> pairWithPeer(DiscoveredPeer peer, String pairCode) async {
    _suppressedPeerIds.remove(peer.deviceId);
    final alreadyPaired =
        _config.pairedPeers.any((p) => p.deviceId == peer.deviceId);
    final session = await _connectTarget(
      peer,
      pairCode: pairCode.isEmpty ? null : pairCode,
      forceTakeover: alreadyPaired,
    );
    await _rememberSessionEndpoint(session, peer);
    notifyListeners();
  }

  /// Pair over LAN when UDP discovery is unavailable. The secure welcome
  /// provides the remote identity, which is pinned by PeerConnectionManager.
  Future<void> pairManually({
    required String host,
    required int port,
    required String pairingPhrase,
  }) async {
    final hosts = await InternetAddress.lookup(
      host,
      type: InternetAddressType.IPv4,
    );
    if (hosts.isEmpty) {
      throw SocketException('No IPv4 address found for $host');
    }
    final session = await _connections.connectManual(
      hosts: hosts,
      port: port,
      pairCode: pairingPhrase,
    );
    _suppressedPeerIds.remove(session.peer.deviceId);
    await _config.rememberPeerEndpoint(
      deviceId: session.peer.deviceId,
      address: session.remoteAddress,
      port: port,
    );
    notifyListeners();
  }

  /// Show this device's connect token for QR (manual fallback).
  Future<String> connectToken() async {
    final addrs = await localIpAddresses();
    return _discovery!.encodeConnectToken(
      address: addrs.isEmpty ? null : InternetAddress(addrs.first),
      hosts: addrs,
      bluetoothAvailable: _bluetooth?.isStarted == true,
    );
  }

  /// Cached QR token + the Future that produced it, for the "Show QR" flow.
  /// `beginQrPairing` also arms a one-time pairing code, embedded in the
  /// token. Both are cached so:
  ///   (a) widget rebuilds keep returning the same token/code until it's
  ///       consumed by a successful first-time pair or invalidated, and
  ///   (b) callers that hand the *Future* itself to a `FutureBuilder` (the
  ///       QR-display screen) get the SAME Future instance back on every
  ///       call, not a new one each time. Previously this method returned a
  ///       cached *value* but was still `async`, so every call — including
  ///       ones triggered by an unrelated `notifyListeners()`, e.g. a
  ///       discovery beacon arriving every ~3s — produced a brand new
  ///       Future object. `FutureBuilder` resets to `ConnectionState.waiting`
  ///       whenever its `future:` argument changes identity, so the QR
  ///       screen was flickering back to a loading spinner roughly every 3
  ///       seconds even though nothing had actually changed.
  String?
      _cachedQrToken; // ignore: unused_field — kept for debugging/inspection
  Future<String>? _qrFuture;

  Future<String> beginQrPairing() {
    return _qrFuture ??= _beginQrPairingImpl();
  }

  Future<String> _beginQrPairingImpl() async {
    final code = _connections.armGenericPairing();
    final addrs = await localIpAddresses();
    final token = _discovery!.encodeConnectToken(
      address: addrs.isEmpty ? null : InternetAddress(addrs.first),
      hosts: addrs,
      pairCode: code,
      bluetoothAvailable: _bluetooth?.isStarted == true,
    );
    _cachedQrToken = token;
    return token;
  }

  /// Drop the cached QR token/Future so the next call to [beginQrPairing]
  /// generates a fresh one with a new single-use code.
  void invalidateQrPairingToken() {
    _cachedQrToken = null;
    _qrFuture = null;
    notifyListeners();
  }

  /// The pairing code we'd accept for an incoming first-time request.
  String generateIncomingPairCode(DiscoveredPeer forPeer) {
    return _connections.armPairingFor(forPeer);
  }

  /// Arm a single-use pairing code for any incoming first-time request, when
  /// the remote device isn't known yet (the "Generate code" manual flow).
  String generatePairingCode() {
    return _connections.armGenericPairing();
  }

  /// Connect using a token decoded from a scanned QR. Tries each candidate
  /// host in the token until one connects. Clears any suppression for this
  /// peer — an explicit user connect overrides a prior explicit disconnect.
  Future<void> connectViaToken(String token, String pairCode) async {
    final decoded = Discovery.decodeConnectTokenFull(token);
    if (decoded == null) {
      throw FormatException('Not a Conduit connect code.');
    }
    _suppressedPeerIds.remove(decoded.peer.deviceId);
    final alreadyPaired =
        _config.pairedPeers.any((p) => p.deviceId == decoded.peer.deviceId);
    Object? lastError;
    if (decoded.hosts.isNotEmpty) {
      try {
        final session = await _connections.connectMultiHost(
          deviceId: decoded.peer.deviceId,
          name: decoded.peer.name,
          platform: decoded.peer.platform,
          publicKeyB64: decoded.peer.publicKeyB64,
          hosts: decoded.hosts,
          port: decoded.peer.port,
          pairCode: pairCode.isEmpty ? null : pairCode,
          forceTakeover: alreadyPaired,
        );
        await _config.rememberPeerEndpoint(
          deviceId: decoded.peer.deviceId,
          address: session.remoteAddress,
          port: decoded.peer.port,
        );
        notifyListeners();
        return;
      } catch (error) {
        lastError = error;
      }
    }

    if (decoded.bluetoothAvailable && _bluetooth?.isStarted == true) {
      final endpoints = <String>{
        if (_config.bluetoothEndpoint(decoded.peer.deviceId) case final saved?)
          saved,
        ..._bluetoothPeers.keys,
      };
      for (final endpoint in endpoints) {
        final target = DiscoveredPeer(
          deviceId: decoded.peer.deviceId,
          name: decoded.peer.name,
          platform: decoded.peer.platform,
          address: InternetAddress.loopbackIPv4,
          port: 0,
          publicKeyB64: decoded.peer.publicKeyB64,
          transport: ConnectionTransport.bluetooth,
          transportEndpoint: endpoint,
        );
        try {
          final session = await _connectTarget(
            target,
            pairCode: pairCode.isEmpty ? null : pairCode,
            forceTakeover: alreadyPaired,
          );
          await _rememberSessionEndpoint(session, target);
          notifyListeners();
          return;
        } catch (error) {
          lastError = error;
        }
      }
    }

    if (lastError != null) throw lastError;
    throw const SocketException(
      'No reachable LAN or Bluetooth endpoint was found for this device.',
    );
  }
}

/// Backing store for AppState's discovered-peers cache. Implements [MapBase]
/// so AppState can keep using `cache[id] = peer` and `cache.values` exactly as
/// before, AND implements [DiscoveredPeerCache] so [ConnectionSupervisor] can
/// read last-known peer addresses without a direct AppState reference (which
/// would create a reference cycle).
class _DiscoveredPeerCache extends MapBase<String, DiscoveredPeer>
    implements DiscoveredPeerCache {
  final _map = <String, DiscoveredPeer>{};

  @override
  DiscoveredPeer? forPeer(String deviceId) => _map[deviceId];

  // ---- MapBase forwarding ----
  @override
  DiscoveredPeer? operator [](Object? key) => _map[key];

  @override
  void operator []=(String key, DiscoveredPeer value) {
    _map[key] = value;
  }

  @override
  void clear() => _map.clear();

  @override
  Iterable<String> get keys => _map.keys;

  @override
  DiscoveredPeer? remove(Object? key) => _map.remove(key);
}

// Phase 3d: a file that arrived via the OS share/send mechanism and is waiting
// for the user to pick a destination peer (used when 0 or 2+ peers connected).
class PendingSharedFile {
  final String name;
  final Uint8List? bytes;
  final String? safUri;
  final String? filePath;
  final int size;

  const PendingSharedFile({
    required this.name,
    this.bytes,
    this.safUri,
    this.filePath,
    required this.size,
  });
}

class DeviceDashboardState {
  final String deviceId;
  DateTime? connectedAt;
  DateTime? lastSeenAt;
  DateTime? lastDisconnectedAt;
  int? latestRttMs;
  List<int> recentRttMs = [];
  int missedHeartbeats = 0;

  // Status Snapshot fields
  int? batteryPct;
  String? powerState; // charging, full, discharging, unknown
  int? storageAvailableBytes;
  int? storageTotalBytes;
  Map<String, dynamic>? conduitHealth;
  Map<String, dynamic>? pairHealth;
  DateTime? statusReceivedAt;

  DeviceDashboardState({
    required this.deviceId,
    this.connectedAt,
    this.lastSeenAt,
    this.lastDisconnectedAt,
    this.latestRttMs,
    this.batteryPct,
    this.powerState,
    this.storageAvailableBytes,
    this.storageTotalBytes,
    this.conduitHealth,
    this.pairHealth,
    this.statusReceivedAt,
  });
}
