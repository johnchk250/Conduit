import 'dart:io';
import 'dart:typed_data';

import 'package:conduit/src/core/config_store.dart';
import 'package:conduit/src/core/identity.dart';
import 'package:conduit/src/net/discovery.dart';
import 'package:conduit/src/net/peer_registry.dart';
import 'package:conduit/src/net/peer_session.dart';
import 'package:conduit/src/protocol/wire.dart';
import 'package:conduit/src/storage/db_factory.dart';
import 'package:conduit/src/sync/engine.dart';
import 'package:conduit/src/sync/manifest.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;

import 'wait_until.dart';

class TwoNodeHarness {
  TwoNodeHarness._(this.root, this.nodeA, this.nodeB);

  final Directory root;
  final HarnessNode nodeA;
  final HarnessNode nodeB;

  static Future<TwoNodeHarness> create() async {
    final root = await Directory.systemTemp.createTemp('conduit_two_node_');
    final nodeA = await HarnessNode.create(
      Directory('${root.path}${Platform.pathSeparator}a'),
      id: 'AAAA-0001',
      name: 'Node A',
      platform: 'windows',
    );
    final nodeB = await HarnessNode.create(
      Directory('${root.path}${Platform.pathSeparator}b'),
      id: 'BBBB-0002',
      name: 'Node B',
      platform: 'android',
    );
    return TwoNodeHarness._(root, nodeA, nodeB);
  }

  Future<void> start() async {
    await nodeA.start();
    await nodeB.start();
  }

  Future<void> pairFresh() async {
    final secret = nodeB.manager.armGenericPairing();
    await nodeA.connectTo(nodeB, pairCode: secret);
    await waitUntil(
      () =>
          nodeA.isReady(nodeB.identity.deviceId) &&
          nodeB.isReady(nodeA.identity.deviceId),
      description: 'both secure sessions to exchange ready acknowledgements',
    );
  }

  Future<void> reconnectUsingPins() async {
    await nodeA.closeSession(nodeB.identity.deviceId);
    await nodeB.closeSession(nodeA.identity.deviceId);
    await nodeA.connectTo(nodeB);
    await waitUntil(
      () =>
          nodeA.isReady(nodeB.identity.deviceId) &&
          nodeB.isReady(nodeA.identity.deviceId),
      description: 'pinned reconnect to become ready',
    );
  }

  Future<FolderPair> syncFile({
    required String relativePath,
    required List<int> bytes,
    SyncDirection direction = SyncDirection.sendOnly,
  }) async {
    const pairId = 'integration-pair';
    final pair = FolderPair(
      id: pairId,
      name: 'Integration',
      localPath: nodeA.source.path,
      direction: direction,
      peerDeviceId: nodeB.identity.deviceId,
    );
    await nodeA.config.upsertPair(pair);
    await nodeA.engine.startPair(pair);
    nodeA.engine.sendFolderInvite(pair);

    await waitUntil(
      () => nodeB.pendingInvite?.pairId == pairId,
      description: 'folder invitation',
    );
    await nodeB.engine.acceptFolderInvite(
      nodeB.pendingInvite!,
      nodeB.destination.path,
    );
    await waitUntil(
      () => nodeA.engine.isPairAcceptedByPeer(pairId),
      description: 'folder acceptance',
    );

    await File(
      '${nodeA.source.path}${Platform.pathSeparator}${relativePath.replaceAll('/', Platform.pathSeparator)}',
    ).create(recursive: true).then((file) => file.writeAsBytes(bytes));
    final session = nodeA.registry.openSessionFor(nodeB.identity.deviceId);
    await nodeA.engine.reconcile(pair, session);
    final destination = File(
      '${nodeB.destination.path}${Platform.pathSeparator}${relativePath.replaceAll('/', Platform.pathSeparator)}',
    );
    await waitUntil(
      destination.existsSync,
      timeout: const Duration(seconds: 10),
      description: '$relativePath to arrive',
    );
    final received = await destination.readAsBytes();
    if (!_bytesEqual(received, bytes)) {
      throw StateError('Destination bytes differ for $relativePath.');
    }
    return pair;
  }

  Future<void> dispose() async {
    // Keep both engines alive until both transports have finished delivering
    // their final done/bye callbacks.
    await Future.wait([nodeA.stopTransport(), nodeB.stopTransport()]);
    await Future.wait([nodeA.disposeEngine(), nodeB.disposeEngine()]);
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  }
}

class HarnessNode {
  HarnessNode._({
    required this.root,
    required this.identity,
    required this.config,
  });

  final Directory root;
  final DeviceIdentity identity;
  final ConfigStore config;
  final PeerConnectionRegistry registry = PeerConnectionRegistry();
  final List<String> events = [];
  late final Directory source;
  late final Directory destination;
  late final Directory stateDirectory;

  late PeerConnectionManager manager;
  late SyncEngine engine;
  FolderPairInvite? pendingInvite;
  int? port;

  static Future<HarnessNode> create(
    Directory root, {
    required String id,
    required String name,
    required String platform,
  }) async {
    await root.create(recursive: true);
    final pair = ed.generateKey();
    final identity = DeviceIdentity(
      deviceId: id,
      name: name,
      platform: platform,
      privateKey: Uint8List.fromList(pair.privateKey.bytes),
      publicKey: Uint8List.fromList(pair.publicKey.bytes),
    );
    final config = ConfigStore.forTest(
      File('${root.path}${Platform.pathSeparator}config.json'),
      <String, dynamic>{},
    );
    return HarnessNode._(root: root, identity: identity, config: config);
  }

  Future<void> start() async {
    DbFactory.init();
    source = Directory('${root.path}${Platform.pathSeparator}source');
    destination = Directory('${root.path}${Platform.pathSeparator}destination');
    stateDirectory = Directory('${root.path}${Platform.pathSeparator}state');
    await source.create(recursive: true);
    await destination.create(recursive: true);
    await stateDirectory.create(recursive: true);
    engine = SyncEngine(
      fs: const LocalFileSystemAccess(),
      config: config,
      stateDir: stateDirectory,
      registry: registry,
      deviceId: identity.deviceId,
      onFolderInvite: (invite) => pendingInvite = invite,
    );
    manager = PeerConnectionManager(
      identity: identity,
      config: config,
      registry: registry,
      listenPort: 0,
      onSessionReady: (session) {
        registry.publish(session.peer.deviceId, session);
        engine.onPeerConnected(session);
        session.send({
          't': Msg.ready,
          'deviceId': identity.deviceId,
          'ack': false,
        });
        events.add('session:${session.peer.deviceId}');
        return true;
      },
      onPairingRequest: (_, __) {},
    );
    port = await manager.start();
  }

  bool isReady(String peerId) =>
      registry.openSessionFor(peerId)?.isLinkReady == true;

  Future<PeerSession> connectTo(
    HarnessNode other, {
    String? pairCode,
  }) {
    return manager.connect(
      target: DiscoveredPeer(
        deviceId: other.identity.deviceId,
        name: other.identity.name,
        platform: other.identity.platform,
        address: InternetAddress.loopbackIPv4,
        port: other.port!,
        publicKeyB64: other.identity.publicKeyB64,
      ),
      pairCode: pairCode,
      timeout: const Duration(seconds: 5),
    );
  }

  Future<void> closeSession(String peerId) async {
    final session = registry.sessionFor(peerId);
    if (session == null) return;
    registry.drop(peerId, session);
    await session.close();
  }

  Future<void> stopTransport() async {
    if (port == null) return;
    await manager.stop();
    port = null;
  }

  Future<void> disposeEngine() => engine.dispose();
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
