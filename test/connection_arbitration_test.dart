import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;

import 'package:conduit/src/core/config_store.dart';
import 'package:conduit/src/core/identity.dart';
import 'package:conduit/src/net/discovery.dart';
import 'package:conduit/src/net/peer_registry.dart';
import 'package:conduit/src/net/peer_session.dart';

void main() {
  test('automatic takeover cannot replace a healthy existing session',
      () async {
    final tmp = await Directory.systemTemp.createTemp('conduit_conn_test_');
    final alice = _identity(
      id: 'AAAA-1111',
      name: 'Alice',
      platform: 'windows',
      keySeed: 1,
    );
    final bob = _identity(
      id: 'BBBB-2222',
      name: 'Bob',
      platform: 'android',
      keySeed: 2,
    );

    final alicePeer = _peerFrom(alice);
    final bobPeer = _peerFrom(bob);
    final serverRegistry = PeerConnectionRegistry();
    final existing = _HealthySession(peer: bobPeer);
    serverRegistry.publish(bob.deviceId, existing);

    late PeerConnectionManager server;
    late PeerConnectionManager client;
    var serverReadyCalls = 0;
    var clientReadyCalls = 0;

    try {
      final aliceConfig = ConfigStore.forTest(
        File('${tmp.path}/alice.json'),
        {
          'pairedPeers': [bobPeer.toJson()],
        },
      );
      final bobConfig = ConfigStore.forTest(
        File('${tmp.path}/bob.json'),
        {
          'pairedPeers': [alicePeer.toJson()],
        },
      );

      server = PeerConnectionManager(
        identity: alice,
        config: aliceConfig,
        registry: serverRegistry,
        listenPort: 0,
        onSessionReady: (session) {
          serverReadyCalls++;
          return true;
        },
        onPairingRequest: (_, __) {},
      );
      final port = await server.start();

      client = PeerConnectionManager(
        identity: bob,
        config: bobConfig,
        registry: PeerConnectionRegistry(),
        onSessionReady: (session) {
          clientReadyCalls++;
          return true;
        },
        onPairingRequest: (_, __) {},
      );

      await expectLater(
        client.connect(
          target: DiscoveredPeer(
            deviceId: alice.deviceId,
            name: alice.name,
            platform: alice.platform,
            address: InternetAddress.loopbackIPv4,
            port: port,
            publicKeyB64: alice.publicKeyB64,
          ),
          timeout: const Duration(seconds: 1),
          forceTakeover: true,
        ),
        throwsA(isA<StateError>()),
      );

      expect(serverReadyCalls, 0,
          reason: 'the duplicate hello is rejected before publication');
      expect(clientReadyCalls, 0,
          reason: 'the rejected duplicate must not become current locally');
      expect(serverRegistry.sessionFor(bob.deviceId), same(existing));
    } finally {
      await server.stop();
      await client.stop();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  });

  test('secure handshake exchanges a stable reverse reconnect port', () async {
    final tmp = await Directory.systemTemp.createTemp('conduit_route_test_');
    final alice = _generatedIdentity(
      id: 'AAAA-1111',
      name: 'Alice',
      platform: 'windows',
    );
    final bob = _generatedIdentity(
      id: 'BBBB-2222',
      name: 'Bob',
      platform: 'android',
    );
    late PeerConnectionManager aliceManager;
    late PeerConnectionManager bobManager;
    PeerSession? aliceSession;
    PeerSession? bobSession;

    try {
      final aliceConfig = ConfigStore.forTest(
        File('${tmp.path}/alice.json'),
        {
          'pairedPeers': [_peerFrom(bob).toJson()],
        },
      );
      final bobConfig = ConfigStore.forTest(
        File('${tmp.path}/bob.json'),
        {
          'pairedPeers': [_peerFrom(alice).toJson()],
        },
      );
      aliceManager = PeerConnectionManager(
        identity: alice,
        config: aliceConfig,
        registry: PeerConnectionRegistry(),
        listenPort: 0,
        onSessionReady: (session) {
          aliceSession = session;
          return true;
        },
        onPairingRequest: (_, __) {},
      );
      bobManager = PeerConnectionManager(
        identity: bob,
        config: bobConfig,
        registry: PeerConnectionRegistry(),
        listenPort: 0,
        onSessionReady: (session) {
          bobSession = session;
          return true;
        },
        onPairingRequest: (_, __) {},
      );
      final alicePort = await aliceManager.start();
      final bobPort = await bobManager.start();

      await bobManager.connect(
        target: DiscoveredPeer(
          deviceId: alice.deviceId,
          name: alice.name,
          platform: alice.platform,
          address: InternetAddress.loopbackIPv4,
          port: alicePort,
          publicKeyB64: alice.publicKeyB64,
        ),
        timeout: const Duration(seconds: 2),
      );
      await Future<void>.delayed(Duration.zero);

      expect(aliceSession, isNotNull);
      expect(bobSession, isNotNull);
      expect(aliceSession!.remoteListenPort, bobPort);
      expect(bobSession!.remoteListenPort, alicePort);
    } finally {
      await aliceManager.stop();
      await bobManager.stop();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  });
}

DeviceIdentity _identity({
  required String id,
  required String name,
  required String platform,
  required int keySeed,
}) {
  return DeviceIdentity(
    deviceId: id,
    name: name,
    platform: platform,
    privateKey: Uint8List.fromList(List<int>.filled(32, keySeed)),
    publicKey: Uint8List.fromList(List<int>.filled(32, keySeed + 10)),
  );
}

DeviceIdentity _generatedIdentity({
  required String id,
  required String name,
  required String platform,
}) {
  final pair = ed.generateKey();
  return DeviceIdentity(
    deviceId: id,
    name: name,
    platform: platform,
    privateKey: Uint8List.fromList(pair.privateKey.bytes),
    publicKey: Uint8List.fromList(pair.publicKey.bytes),
  );
}

PairedPeer _peerFrom(DeviceIdentity identity) {
  return PairedPeer(
    deviceId: identity.deviceId,
    name: identity.name,
    platform: identity.platform,
    publicKeyB64: identity.publicKeyB64,
  );
}

class _HealthySession implements PeerSession {
  _HealthySession({required this.peer});

  @override
  final PairedPeer peer;

  @override
  final int generation = 1;

  @override
  final bool initiatedByUs = false;

  @override
  DateTime lastActivityAt = DateTime.now();

  @override
  bool get canBeSupersededByAutoReconnect => false;

  @override
  int get missedHeartbeats => 0;

  @override
  bool get isClosed => false;

  bool _linkReady = true;

  @override
  bool get hasReceivedLinkReady => _linkReady;

  @override
  bool get isLinkReady => _linkReady && !isClosed;

  @override
  void Function()? onLinkReady;

  @override
  bool markLinkReady() {
    if (_linkReady) return false;
    _linkReady = true;
    onLinkReady?.call();
    return true;
  }

  @override
  void send(Map<String, dynamic> msg) {}

  @override
  void stopHeartbeat() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
