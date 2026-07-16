import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/config_store.dart';
import '../net/transport.dart';
import '../protocol/wire.dart';
import '../sync/engine.dart';
import '../sync/sync_preview.dart';
import '../sync/vault_log.dart';
import '../transfers/transfer_receipt.dart';

/// A scoped-listenable bridge used while [AppState] remains the compatibility
/// facade. Each controller publishes only its immutable feature snapshot.
abstract class AppController<T> extends ChangeNotifier {
  AppController(this.appState) {
    _snapshot = buildSnapshot();
    appState.addListener(_handleAppStateChanged);
  }

  final AppState appState;
  late T _snapshot;
  bool _disposed = false;

  T get snapshot => _snapshot;
  T buildSnapshot();

  void _handleAppStateChanged() {
    if (_disposed) return;
    final next = buildSnapshot();
    if (next == _snapshot) return;
    _snapshot = next;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    appState.removeListener(_handleAppStateChanged);
    super.dispose();
  }
}

@immutable
class LifecycleSnapshot {
  const LifecycleSnapshot({
    required this.isStarted,
    required this.status,
    required this.sendWidgetMode,
    required this.onboardingVersion,
  });

  final bool isStarted;
  final String status;
  final bool sendWidgetMode;
  final int onboardingVersion;

  @override
  bool operator ==(Object other) =>
      other is LifecycleSnapshot &&
      other.isStarted == isStarted &&
      other.status == status &&
      other.sendWidgetMode == sendWidgetMode &&
      other.onboardingVersion == onboardingVersion;

  @override
  int get hashCode =>
      Object.hash(isStarted, status, sendWidgetMode, onboardingVersion);
}

class AppLifecycleController extends AppController<LifecycleSnapshot> {
  AppLifecycleController(super.appState);

  static const currentOnboardingVersion = 1;

  @override
  LifecycleSnapshot buildSnapshot() => LifecycleSnapshot(
        isStarted: appState.isStarted,
        status: appState.status,
        sendWidgetMode: appState.sendWidgetMode,
        onboardingVersion:
            appState.isStarted ? appState.config.onboardingVersion : 0,
      );

  Future<void> start() => appState.start();
  Future<void> completeOnboarding() =>
      appState.setOnboardingVersion(currentOnboardingVersion);
  Future<void> resetOnboarding() => appState.setOnboardingVersion(0);
  Future<void> quit() => appState.quit();
}

@immutable
class PeerSummary {
  const PeerSummary({
    required this.peer,
    required this.connection,
  });

  final PairedPeer peer;
  final PeerConnectionSnapshot connection;

  @override
  bool operator ==(Object other) =>
      other is PeerSummary &&
      other.peer.deviceId == peer.deviceId &&
      other.peer.name == peer.name &&
      other.peer.publicKeyB64 == peer.publicKeyB64 &&
      other.connection.phase == connection.phase &&
      other.connection.transport == connection.transport &&
      other.connection.latestRttMs == connection.latestRttMs;

  @override
  int get hashCode => Object.hash(
        peer.deviceId,
        peer.name,
        peer.publicKeyB64,
        connection.phase,
        connection.transport,
        connection.latestRttMs,
      );
}

@immutable
class ConnectionSnapshot {
  const ConnectionSnapshot({
    required this.peers,
    required this.bluetoothStatus,
  });

  final List<PeerSummary> peers;
  final String bluetoothStatus;

  @override
  bool operator ==(Object other) =>
      other is ConnectionSnapshot &&
      listEquals(other.peers, peers) &&
      other.bluetoothStatus == bluetoothStatus;

  @override
  int get hashCode => Object.hash(Object.hashAll(peers), bluetoothStatus);
}

class ConnectionController extends AppController<ConnectionSnapshot> {
  ConnectionController(super.appState);

  @override
  ConnectionSnapshot buildSnapshot() {
    if (!appState.isStarted) {
      return const ConnectionSnapshot(peers: [], bluetoothStatus: 'Starting');
    }
    return ConnectionSnapshot(
      peers: List<PeerSummary>.unmodifiable(
        appState.pairedPeers.map(
          (peer) => PeerSummary(
            peer: peer,
            connection: appState.connectionStateFor(peer.deviceId),
          ),
        ),
      ),
      bluetoothStatus: appState.bluetoothStatus,
    );
  }

  Future<void> reconnect(PairedPeer peer) => appState.reconnectPeer(peer);
  Future<void> disconnect(String peerId) => appState.disconnectPeer(peerId);
  Future<void> forget(String peerId) => appState.unpairPeer(peerId);
}

@immutable
class FolderSyncSnapshot {
  const FolderSyncSnapshot({
    required this.pairs,
    required this.states,
    required this.pendingInvite,
    required this.isPaused,
    required this.fingerprint,
  });

  final List<FolderPair> pairs;
  final Map<String, PairSyncState> states;
  final FolderPairInvite? pendingInvite;
  final bool isPaused;
  final String fingerprint;

  @override
  bool operator ==(Object other) =>
      other is FolderSyncSnapshot &&
      other.fingerprint == fingerprint &&
      other.pendingInvite?.pairId == pendingInvite?.pairId &&
      other.isPaused == isPaused;

  @override
  int get hashCode => Object.hash(
        fingerprint,
        pendingInvite?.pairId,
        isPaused,
      );
}

class FolderSyncController extends AppController<FolderSyncSnapshot> {
  FolderSyncController(super.appState);

  @override
  FolderSyncSnapshot buildSnapshot() {
    if (!appState.isStarted) {
      return const FolderSyncSnapshot(
        pairs: [],
        states: {},
        pendingInvite: null,
        isPaused: false,
        fingerprint: '',
      );
    }
    final pairs = List<FolderPair>.unmodifiable(appState.config.folderPairs);
    return FolderSyncSnapshot(
      pairs: pairs,
      states: UnmodifiableMapView<String, PairSyncState>({
        for (final pair in pairs)
          if (appState.stateFor(pair.id) case final state?) pair.id: state,
      }),
      pendingInvite: appState.pendingInvite,
      isPaused: appState.isPaused,
      fingerprint: [
        for (final pair in pairs)
          [
            pair.id,
            pair.name,
            pair.localPath,
            pair.direction.name,
            pair.peerDeviceId ?? '',
            pair.ignoreGlobs.join(','),
            pair.ignoreExtensions.join(','),
            pair.maxFileSizeBytes ?? '',
            appState.stateFor(pair.id)?.status ?? '',
            appState.stateFor(pair.id)?.progress ?? '',
            appState.stateFor(pair.id)?.scanning ?? false,
            appState.stateFor(pair.id)?.transferring ?? false,
          ].join('|'),
      ].join('\n'),
    );
  }

  Future<FolderPair> createFolderPair(FolderPairDraft draft) =>
      appState.createFolderPair(draft);
  Future<void> updateFolderPair(String id, FolderPairDraft draft) =>
      appState.updateFolderPair(id, draft);
  Future<void> removeFolderPair(String id) => appState.removeFolderPair(id);
  void invitePeer(String pairId) => appState.invitePeerToFolder(pairId);
  Future<void> acceptInvite(FolderPairInvite invite, String localPath) =>
      appState.acceptInvite(invite, localPath);
  void declineInvite(String id) => appState.declineInvite(id);
  void pause() => appState.pauseSync();
  void resume() => appState.resumeSync();

  Future<SyncPreview> buildPreview(
    String pairId, {
    bool refreshLocal = true,
  }) async {
    final pair = snapshot.pairs
        .where((candidate) => candidate.id == pairId)
        .cast<FolderPair?>()
        .firstWhere((candidate) => candidate != null, orElse: () => null);
    if (pair == null) {
      throw StateError('The folder pair was removed.');
    }
    return appState.buildSyncPreview(pair, refreshLocal: refreshLocal);
  }

  Future<void> syncNow(String pairId) async {
    final pair = snapshot.pairs
        .where((candidate) => candidate.id == pairId)
        .cast<FolderPair?>()
        .firstWhere((candidate) => candidate != null, orElse: () => null);
    if (pair == null) {
      throw StateError('The folder pair was removed.');
    }
    await appState.syncFolderNow(pair);
  }

  Future<List<VaultLogEntry>> versionHistory(String pairId) =>
      appState.vaultEntries(_pair(pairId));

  Future<RestoreResult> restoreVersion(
    String pairId,
    String entryId,
  ) async {
    final pair = _pair(pairId);
    final entries = await appState.vaultEntries(pair);
    final matches = entries.where((entry) => entry.entryId == entryId);
    if (matches.isEmpty) return RestoreResult.sourceMissing;
    try {
      return await appState.restoreVersion(pair, matches.first);
    } on PlatformException {
      return RestoreResult.permissionLost;
    } catch (_) {
      return RestoreResult.failed;
    }
  }

  Future<VaultDeletionResult> deleteVersion(
    String pairId,
    String entryId,
  ) async {
    final pair = _pair(pairId);
    final entries = await appState.vaultEntries(pair);
    final matches = entries.where((entry) => entry.entryId == entryId);
    if (matches.isEmpty) {
      return const VaultDeletionResult(
        requested: 1,
        deleted: 0,
        missing: 1,
        failed: 0,
        reclaimedBytes: 0,
      );
    }
    return appState.deleteVaultEntries(pair, [matches.first]);
  }

  Future<VaultDeletionResult> clearVersionHistory(String pairId) async {
    final pair = _pair(pairId);
    final entries = await appState.vaultEntries(pair);
    return appState.deleteVaultEntries(pair, entries);
  }

  FolderPair _pair(String pairId) {
    final matches = snapshot.pairs.where((pair) => pair.id == pairId);
    if (matches.isEmpty) throw StateError('The folder pair was removed.');
    return matches.first;
  }
}

@immutable
class TransferSnapshot {
  const TransferSnapshot({
    required this.pendingFiles,
    required this.autoStart,
    required this.blockReason,
  });

  final List<PendingSharedFile> pendingFiles;
  final bool autoStart;
  final String? blockReason;

  @override
  bool operator ==(Object other) =>
      other is TransferSnapshot &&
      listEquals(other.pendingFiles, pendingFiles) &&
      other.autoStart == autoStart &&
      other.blockReason == blockReason;

  @override
  int get hashCode => Object.hash(
        Object.hashAll(pendingFiles),
        autoStart,
        blockReason,
      );
}

class TransferController extends AppController<TransferSnapshot> {
  TransferController(super.appState);

  @override
  TransferSnapshot buildSnapshot() => TransferSnapshot(
        pendingFiles: List<PendingSharedFile>.unmodifiable(
          appState.pendingSharedFiles ?? const [],
        ),
        autoStart: appState.pendingSharedFilesAutoStart,
        blockReason: appState.lastTransferBlockReason,
      );

  void consumePendingShare() => appState.clearPendingSharedFiles();
  void exitCompactMode() => appState.exitSendWidgetMode();

  Future<List<TransferReceipt>> recentReceipts({int limit = 100}) async =>
      appState.transferReceipts?.recent(limit: limit) ?? const [];

  Future<List<TransferReceipt>> receiptsForPeer(
    String peerId, {
    int limit = 100,
  }) async =>
      appState.transferReceipts?.forPeer(peerId, limit: limit) ?? const [];

  Future<List<TransferReceipt>> receiptsForPair(
    String pairId, {
    int limit = 100,
  }) async =>
      appState.transferReceipts?.forPair(pairId, limit: limit) ?? const [];

  Future<void> clearHistory() async => appState.transferReceipts?.clear();

  Future<void> clearReceipt(String receiptId) async =>
      appState.transferReceipts?.deleteReceipt(receiptId);
}

@immutable
class DeviceServicesSnapshot {
  const DeviceServicesSnapshot({
    required this.clipboardEnabled,
    required this.remoteControlEnabled,
  });

  final bool clipboardEnabled;
  final bool remoteControlEnabled;

  @override
  bool operator ==(Object other) =>
      other is DeviceServicesSnapshot &&
      other.clipboardEnabled == clipboardEnabled &&
      other.remoteControlEnabled == remoteControlEnabled;

  @override
  int get hashCode => Object.hash(clipboardEnabled, remoteControlEnabled);
}

class DeviceServicesController extends AppController<DeviceServicesSnapshot> {
  DeviceServicesController(super.appState);

  @override
  DeviceServicesSnapshot buildSnapshot() => DeviceServicesSnapshot(
        clipboardEnabled:
            appState.isStarted && appState.config.clipboardSyncEnabled,
        remoteControlEnabled:
            appState.isStarted && appState.remoteControlEnabled,
      );
}
