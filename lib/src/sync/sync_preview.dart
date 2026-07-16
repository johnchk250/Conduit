import 'dart:collection';

import '../net/transport.dart';
import '../protocol/wire.dart';
import '../storage/index_db.dart';
import 'index_diff.dart';

enum SyncPreviewFreshness {
  live,
  staleLocal,
  stalePeer,
  offlineCached,
  unavailable,
}

enum SyncPreviewDirection { receive, send }

enum SyncPreviewAction {
  receiveCreate,
  receiveUpdate,
  receiveConflictWinner,
  sendCreate,
  sendUpdate,
  sendConflictWinner,
  advertiseDelete,
}

enum SyncPreviewReason {
  missingLocally,
  missingOnPeer,
  peerVersionNewer,
  localVersionNewer,
  concurrentPeerWins,
  concurrentLocalWins,
  equalVersionDifferentDiskBytes,
  resurrection,
}

enum SyncPreviewTransportDisposition { transferable, deferredOnBluetooth }

class SyncPreviewItem {
  const SyncPreviewItem({
    required this.relPath,
    required this.action,
    required this.reason,
    required this.sizeBytes,
    required this.direction,
    required this.transportDisposition,
  });

  final String relPath;
  final SyncPreviewAction action;
  final SyncPreviewReason reason;
  final int sizeBytes;
  final SyncPreviewDirection direction;
  final SyncPreviewTransportDisposition transportDisposition;
}

class SyncPreviewTotals {
  const SyncPreviewTotals({
    required this.receiveCount,
    required this.receiveBytes,
    required this.sendCount,
    required this.sendBytes,
    required this.conflictCount,
    required this.deletionAdvertisementCount,
    required this.bluetoothDeferredCount,
    required this.bluetoothDeferredBytes,
  });

  final int receiveCount;
  final int receiveBytes;
  final int sendCount;
  final int sendBytes;
  final int conflictCount;
  final int deletionAdvertisementCount;
  final int bluetoothDeferredCount;
  final int bluetoothDeferredBytes;
}

class SyncPreview {
  SyncPreview({
    required this.pairId,
    required this.peerId,
    required this.capturedAt,
    required this.localGeneration,
    required this.peerGeneration,
    required this.freshness,
    required List<SyncPreviewItem> items,
    required this.totals,
    required List<String> limitations,
  })  : items = UnmodifiableListView(items),
        limitations = UnmodifiableListView(limitations);

  final String pairId;
  final String peerId;
  final DateTime capturedAt;
  final int localGeneration;
  final int peerGeneration;
  final SyncPreviewFreshness freshness;
  final List<SyncPreviewItem> items;
  final SyncPreviewTotals totals;
  final List<String> limitations;

  List<SyncPreviewItem> get deferredItems => items
      .where((item) =>
          item.transportDisposition ==
          SyncPreviewTransportDisposition.deferredOnBluetooth)
      .toList(growable: false);

  SyncPreview withFreshness(SyncPreviewFreshness value) => SyncPreview(
        pairId: pairId,
        peerId: peerId,
        capturedAt: capturedAt,
        localGeneration: localGeneration,
        peerGeneration: peerGeneration,
        freshness: value,
        items: items,
        totals: totals,
        limitations: limitations,
      );
}

class SyncPreviewInputs {
  SyncPreviewInputs({
    required List<IndexEntry> localLive,
    required List<IndexEntry> peerLive,
    required List<IndexEntry> localTombstones,
    required this.localGeneration,
    required this.peerGeneration,
    required this.peerUpdatedAt,
    required this.connected,
    required this.transport,
  })  : localLive = UnmodifiableListView(List.of(localLive)),
        peerLive = UnmodifiableListView(List.of(peerLive)),
        localTombstones = UnmodifiableListView(List.of(localTombstones));

  final List<IndexEntry> localLive;
  final List<IndexEntry> peerLive;
  final List<IndexEntry> localTombstones;
  final int localGeneration;
  final int peerGeneration;
  final DateTime? peerUpdatedAt;
  final bool connected;
  final ConnectionTransport? transport;
}

SyncPreview assembleSyncPreview({
  required FolderPair pair,
  required SyncPreviewInputs inputs,
  required DateTime capturedAt,
}) {
  if (inputs.peerGeneration == 0 && inputs.peerLive.isEmpty) {
    return SyncPreview(
      pairId: pair.id,
      peerId: pair.peerDeviceId ?? '',
      capturedAt: capturedAt,
      localGeneration: inputs.localGeneration,
      peerGeneration: inputs.peerGeneration,
      freshness: SyncPreviewFreshness.unavailable,
      items: const [],
      totals: const SyncPreviewTotals(
        receiveCount: 0,
        receiveBytes: 0,
        sendCount: 0,
        sendBytes: 0,
        conflictCount: 0,
        deletionAdvertisementCount: 0,
        bluetoothDeferredCount: 0,
        bluetoothDeferredBytes: 0,
      ),
      limitations: const [
        'The peer must reconnect before Conduit can build a forecast.',
        'Preview is informational and does not pause automatic sync.',
      ],
    );
  }

  final incoming = pair.direction == SyncDirection.sendOnly
      ? const <Need>[]
      : indexDiff(localLive: inputs.localLive, peerLive: inputs.peerLive);
  final outgoing = pair.direction == SyncDirection.receiveOnly
      ? const <Need>[]
      : indexDiff(localLive: inputs.peerLive, peerLive: inputs.localLive);
  final localByPath = {
    for (final entry in inputs.localLive) entry.relPath: entry
  };
  final peerByPath = {
    for (final entry in inputs.peerLive) entry.relPath: entry
  };
  final constrained = inputs.transport == ConnectionTransport.bluetooth;
  final items = <SyncPreviewItem>[
    for (final need in incoming)
      _item(
        need: need,
        direction: SyncPreviewDirection.receive,
        other: localByPath[need.relPath],
        constrained: constrained,
      ),
    for (final need in outgoing)
      _item(
        need: need,
        direction: SyncPreviewDirection.send,
        other: peerByPath[need.relPath],
        constrained: constrained,
      ),
    if (pair.direction != SyncDirection.receiveOnly)
      for (final tombstone in inputs.localTombstones)
        SyncPreviewItem(
          relPath: tombstone.relPath,
          action: SyncPreviewAction.advertiseDelete,
          reason: SyncPreviewReason.localVersionNewer,
          sizeBytes: 0,
          direction: SyncPreviewDirection.send,
          transportDisposition: SyncPreviewTransportDisposition.transferable,
        ),
  ];

  var receiveBytes = 0;
  var sendBytes = 0;
  var conflicts = 0;
  var deletes = 0;
  var deferredCount = 0;
  var deferredBytes = 0;
  for (final item in items) {
    if (item.action == SyncPreviewAction.advertiseDelete) deletes++;
    if (item.direction == SyncPreviewDirection.receive) {
      receiveBytes += item.sizeBytes;
    } else {
      sendBytes += item.sizeBytes;
    }
    if (item.action == SyncPreviewAction.receiveConflictWinner ||
        item.action == SyncPreviewAction.sendConflictWinner) {
      conflicts++;
    }
    if (item.transportDisposition ==
        SyncPreviewTransportDisposition.deferredOnBluetooth) {
      deferredCount++;
      deferredBytes += item.sizeBytes;
    }
  }

  return SyncPreview(
    pairId: pair.id,
    peerId: pair.peerDeviceId ?? '',
    capturedAt: capturedAt,
    localGeneration: inputs.localGeneration,
    peerGeneration: inputs.peerGeneration,
    freshness: inputs.connected
        ? SyncPreviewFreshness.live
        : SyncPreviewFreshness.offlineCached,
    items: items,
    totals: SyncPreviewTotals(
      receiveCount: incoming.length,
      receiveBytes: receiveBytes,
      sendCount: outgoing.length,
      sendBytes: sendBytes,
      conflictCount: conflicts,
      deletionAdvertisementCount: deletes,
      bluetoothDeferredCount: deferredCount,
      bluetoothDeferredBytes: deferredBytes,
    ),
    limitations: const [
      'Based on snapshots captured at the time shown.',
      'Conduit applies confirmed peer deletions automatically. Preview does not pause sync.',
    ],
  );
}

SyncPreviewItem _item({
  required Need need,
  required SyncPreviewDirection direction,
  required IndexEntry? other,
  required bool constrained,
}) {
  final conflict = need.reason == NeedReason.concurrentPeerWins;
  final create = other == null || other.deleted;
  final action = switch ((direction, conflict, create)) {
    (SyncPreviewDirection.receive, true, _) =>
      SyncPreviewAction.receiveConflictWinner,
    (SyncPreviewDirection.send, true, _) =>
      SyncPreviewAction.sendConflictWinner,
    (SyncPreviewDirection.receive, false, true) =>
      SyncPreviewAction.receiveCreate,
    (SyncPreviewDirection.receive, false, false) =>
      SyncPreviewAction.receiveUpdate,
    (SyncPreviewDirection.send, false, true) => SyncPreviewAction.sendCreate,
    (SyncPreviewDirection.send, false, false) => SyncPreviewAction.sendUpdate,
  };
  final reason = switch ((direction, need.reason)) {
    (_, NeedReason.resurrection) => SyncPreviewReason.resurrection,
    (SyncPreviewDirection.receive, NeedReason.missingLocally) =>
      SyncPreviewReason.missingLocally,
    (SyncPreviewDirection.send, NeedReason.missingLocally) =>
      SyncPreviewReason.missingOnPeer,
    (SyncPreviewDirection.receive, NeedReason.peerVersionNewer) =>
      SyncPreviewReason.peerVersionNewer,
    (SyncPreviewDirection.send, NeedReason.peerVersionNewer) =>
      SyncPreviewReason.localVersionNewer,
    (SyncPreviewDirection.receive, NeedReason.concurrentPeerWins) =>
      SyncPreviewReason.concurrentPeerWins,
    (SyncPreviewDirection.send, NeedReason.concurrentPeerWins) =>
      SyncPreviewReason.concurrentLocalWins,
    (_, NeedReason.equalVersionDifferentDiskBytes) =>
      SyncPreviewReason.equalVersionDifferentDiskBytes,
  };
  return SyncPreviewItem(
    relPath: need.relPath,
    action: action,
    reason: reason,
    sizeBytes: need.peer.size,
    direction: direction,
    transportDisposition:
        constrained && need.peer.size > bluetoothLargeTransferLimitBytes
            ? SyncPreviewTransportDisposition.deferredOnBluetooth
            : SyncPreviewTransportDisposition.transferable,
  );
}
