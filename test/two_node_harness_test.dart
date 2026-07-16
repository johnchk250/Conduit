import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/src/protocol/wire.dart';

import 'support/two_node_harness.dart';
import 'support/wait_until.dart';

void main() {
  test('fresh secure pairing persists pins and reconnects without a secret',
      () async {
    final harness = await TwoNodeHarness.create();
    addTearDown(harness.dispose);
    await harness.start();

    await harness.pairFresh();
    await waitUntil(
      () =>
          harness.nodeA.config.pairedPeers.length == 1 &&
          harness.nodeB.config.pairedPeers.length == 1,
      description: 'both identity pins to persist',
    );

    expect(
      harness.nodeA.config.pairedPeers.single.publicKeyB64,
      harness.nodeB.identity.publicKeyB64,
    );
    expect(
      harness.nodeB.config.pairedPeers.single.publicKeyB64,
      harness.nodeA.identity.publicKeyB64,
    );

    await harness.reconnectUsingPins();
    expect(
      harness.nodeA.manager.sessionFor(harness.nodeB.identity.deviceId),
      isNotNull,
    );

    await harness.syncFile(
      relativePath: 'nested/hello.txt',
      bytes: List<int>.generate(1024 * 1024 + 37, (index) => index % 251),
    );
  });

  test('restored peer deletion converges without creating a new tombstone',
      () async {
    final harness = await TwoNodeHarness.create();
    addTearDown(harness.dispose);
    await harness.start();
    await harness.pairFresh();

    final bytes = List<int>.generate(4096, (index) => index % 251);
    final pairA = await harness.syncFile(
      relativePath: 'restored.txt',
      bytes: bytes,
      direction: SyncDirection.twoWay,
    );
    final pairB = harness.nodeB.config.folderPairs
        .singleWhere((pair) => pair.id == pairA.id);
    final source = File(
        '${harness.nodeA.source.path}${Platform.pathSeparator}restored.txt');
    final destination = File(
        '${harness.nodeB.destination.path}${Platform.pathSeparator}restored.txt');

    await source.delete();
    await harness.nodeA.engine.reconcile(
      pairA,
      harness.nodeA.registry.openSessionFor(harness.nodeB.identity.deviceId),
    );
    await waitUntil(
      () => !destination.existsSync(),
      description: 'peer delete to reach the destination',
    );
    var history = await harness.nodeB.engine.vaultEntries(pairB);
    final historyDeadline = DateTime.now().add(const Duration(seconds: 5));
    while (history.isEmpty && DateTime.now().isBefore(historyDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      history = await harness.nodeB.engine.vaultEntries(pairB);
    }
    expect(history, isNotEmpty,
        reason: 'deleted bytes must enter version history');
    await harness.nodeB.engine.restoreVaultEntry(pairB, history.first);
    await waitUntil(
      () => source.existsSync() && destination.existsSync(),
      description: 'restored bytes to converge on both peers',
    );

    await harness.nodeA.engine.reconcile(
      pairA,
      harness.nodeA.registry.openSessionFor(harness.nodeB.identity.deviceId),
    );
    await harness.nodeB.engine.reconcile(
      pairB,
      harness.nodeB.registry.openSessionFor(harness.nodeA.identity.deviceId),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(await source.readAsBytes(), bytes);
    expect(await destination.readAsBytes(), bytes);
  });
}
