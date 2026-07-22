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
