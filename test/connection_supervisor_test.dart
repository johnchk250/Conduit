import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/src/core/config_store.dart';
import 'package:conduit/src/net/connection_supervisor.dart';
import 'package:conduit/src/net/discovery.dart';
import 'package:conduit/src/net/peer_registry.dart';

void main() {
  test('retryNow bypasses reconnect backoff immediately', () async {
    final temp = await Directory.systemTemp.createTemp('conduit-supervisor-');
    addTearDown(() => temp.delete(recursive: true));
    final peer = PairedPeer(
      deviceId: 'peer-1',
      name: 'Laptop',
      platform: 'windows',
      publicKeyB64: 'test-key',
    );
    final config = ConfigStore.forTest(
      File('${temp.path}${Platform.pathSeparator}config.json'),
      {
        'pairedPeers': [peer.toJson()],
      },
    );
    final discovered = DiscoveredPeer(
      deviceId: peer.deviceId,
      name: peer.name,
      platform: peer.platform,
      address: InternetAddress.loopbackIPv4,
      port: 41828,
      publicKeyB64: peer.publicKeyB64,
    );
    var attempts = 0;
    final supervisor = ConnectionSupervisor(
      registry: PeerConnectionRegistry(),
      config: config,
      discoveredPeers: _PeerCache(discovered),
      connect: (_) async {
        attempts++;
        throw const SocketException('offline');
      },
      isConnecting: (_) => false,
      isSuppressed: (_) => false,
    );

    supervisor.start();
    await Future<void>.delayed(Duration.zero);
    expect(attempts, 1);

    supervisor.retryNow();
    await Future<void>.delayed(Duration.zero);
    supervisor.stop();
    expect(attempts, 2);
  });

  test('retryPeerNow does not reset unrelated offline peers', () async {
    final temp = await Directory.systemTemp.createTemp('conduit-supervisor-');
    addTearDown(() => temp.delete(recursive: true));
    final peer1 = PairedPeer(
      deviceId: 'peer-1',
      name: 'Laptop',
      platform: 'windows',
      publicKeyB64: 'key-1',
    );
    final peer2 = PairedPeer(
      deviceId: 'peer-2',
      name: 'Tablet',
      platform: 'android',
      publicKeyB64: 'key-2',
    );
    final config = ConfigStore.forTest(
      File('${temp.path}${Platform.pathSeparator}config.json'),
      {
        'pairedPeers': [peer1.toJson(), peer2.toJson()],
      },
    );
    final discovered = <String, DiscoveredPeer>{
      peer1.deviceId: DiscoveredPeer(
        deviceId: peer1.deviceId,
        name: peer1.name,
        platform: peer1.platform,
        address: InternetAddress.loopbackIPv4,
        port: 41828,
        publicKeyB64: peer1.publicKeyB64,
      ),
      peer2.deviceId: DiscoveredPeer(
        deviceId: peer2.deviceId,
        name: peer2.name,
        platform: peer2.platform,
        address: InternetAddress.loopbackIPv4,
        port: 41828,
        publicKeyB64: peer2.publicKeyB64,
      ),
    };
    final attempts = <String, int>{};
    final supervisor = ConnectionSupervisor(
      registry: PeerConnectionRegistry(),
      config: config,
      discoveredPeers: _PeerMapCache(discovered),
      connect: (peer) async {
        attempts.update(peer.deviceId, (count) => count + 1, ifAbsent: () => 1);
        throw const SocketException('offline');
      },
      isConnecting: (_) => false,
      isSuppressed: (_) => false,
    );

    supervisor.start();
    await Future<void>.delayed(Duration.zero);
    expect(attempts, {'peer-1': 1, 'peer-2': 1});

    supervisor.retryPeerNow('peer-1');
    await Future<void>.delayed(Duration.zero);
    supervisor.stop();
    expect(attempts, {'peer-1': 2, 'peer-2': 1});
  });

  test('unpaired discovery beacons are never dialled', () async {
    final temp = await Directory.systemTemp.createTemp('conduit-supervisor-');
    addTearDown(() => temp.delete(recursive: true));
    final config = ConfigStore.forTest(
      File('${temp.path}${Platform.pathSeparator}config.json'),
      const {'pairedPeers': <Map<String, dynamic>>[]},
    );
    final discovered = DiscoveredPeer(
      deviceId: 'unpaired-peer',
      name: 'Unknown',
      platform: 'windows',
      address: InternetAddress.loopbackIPv4,
      port: 41828,
      publicKeyB64: 'unknown-key',
    );
    var attempts = 0;
    final supervisor = ConnectionSupervisor(
      registry: PeerConnectionRegistry(),
      config: config,
      discoveredPeers: _PeerCache(discovered),
      connect: (_) async {
        attempts++;
      },
      isConnecting: (_) => false,
      isSuppressed: (_) => false,
    );

    supervisor.notePeerSeen(discovered, endpointChanged: true);
    await Future<void>.delayed(Duration.zero);

    expect(attempts, 0);
    supervisor.stop();
  });

  test('peer beacons respect backoff unless endpoint changed', () async {
    final temp = await Directory.systemTemp.createTemp('conduit-supervisor-');
    addTearDown(() => temp.delete(recursive: true));
    final peer = PairedPeer(
      deviceId: 'peer-1',
      name: 'Laptop',
      platform: 'windows',
      publicKeyB64: 'test-key',
    );
    final config = ConfigStore.forTest(
      File('${temp.path}${Platform.pathSeparator}config.json'),
      {
        'pairedPeers': [peer.toJson()],
      },
    );
    final discovered = DiscoveredPeer(
      deviceId: peer.deviceId,
      name: peer.name,
      platform: peer.platform,
      address: InternetAddress.loopbackIPv4,
      port: 41828,
      publicKeyB64: peer.publicKeyB64,
    );
    var attempts = 0;
    final supervisor = ConnectionSupervisor(
      registry: PeerConnectionRegistry(),
      config: config,
      discoveredPeers: _PeerCache(discovered),
      connect: (_) async {
        attempts++;
        throw const SocketException('offline');
      },
      isConnecting: (_) => false,
      isSuppressed: (_) => false,
    );

    supervisor.start();
    await Future<void>.delayed(Duration.zero);
    expect(attempts, 1);

    // A changed endpoint is a strong reachability signal and bypasses the old
    // address's backoff once.
    supervisor.notePeerSeen(discovered, endpointChanged: true);
    await Future<void>.delayed(Duration.zero);
    expect(attempts, 2);

    // Repeated unchanged beacons must not turn into a dial every few seconds.
    supervisor.notePeerSeen(discovered, endpointChanged: false);
    supervisor.notePeerSeen(discovered, endpointChanged: false);
    await Future<void>.delayed(Duration.zero);
    supervisor.stop();
    expect(attempts, 2);
  });
}

class _PeerCache implements DiscoveredPeerCache {
  const _PeerCache(this.peer);

  final DiscoveredPeer peer;

  @override
  DiscoveredPeer? forPeer(String deviceId) =>
      deviceId == peer.deviceId ? peer : null;
}

class _PeerMapCache implements DiscoveredPeerCache {
  const _PeerMapCache(this.peers);

  final Map<String, DiscoveredPeer> peers;

  @override
  DiscoveredPeer? forPeer(String deviceId) => peers[deviceId];
}
