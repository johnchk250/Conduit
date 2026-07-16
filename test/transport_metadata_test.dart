import 'dart:io';

import 'package:conduit/src/core/config_store.dart';
import 'package:conduit/src/net/peer_session.dart';
import 'package:conduit/src/net/secure_frame.dart';
import 'package:conduit/src/net/transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sessions retain Bluetooth transport metadata', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = server.first;
    final client =
        await Socket.connect(InternetAddress.loopbackIPv4, server.port);
    final peerSocket = await accepted;
    final session = PeerSession(
      peer: PairedPeer(
        deviceId: 'peer',
        name: 'Peer',
        platform: 'android',
        publicKeyB64: 'key',
      ),
      socket: client,
      codec: FrameCodec(client),
      initiatedByUs: true,
      transport: ConnectionTransport.bluetooth,
      transportEndpoint: 'endpoint-1',
    );

    expect(session.transport, ConnectionTransport.bluetooth);
    expect(session.transportEndpoint, 'endpoint-1');
    expect(session.isBandwidthConstrained, isTrue);

    await session.close();
    await peerSocket.close();
    await server.close();
  });

  test('transport policy prefers LAN and pauses files over 10 MiB', () {
    expect(ConnectionTransport.lan.priority,
        greaterThan(ConnectionTransport.bluetooth.priority));
    expect(
      isTransportUpgrade(
        ConnectionTransport.bluetooth,
        ConnectionTransport.lan,
      ),
      isTrue,
    );
    expect(
      isTransportUpgrade(
        ConnectionTransport.lan,
        ConnectionTransport.bluetooth,
      ),
      isFalse,
    );
    expect(ConnectionTransport.bluetooth.isBandwidthConstrained, isTrue);
    expect(bluetoothLargeTransferLimitBytes, 10 * 1024 * 1024);
  });

  test('a live session is never presented as reconnecting', () {
    const snapshot = PeerConnectionSnapshot(
      phase: PeerConnectionPhase.connected,
      transport: ConnectionTransport.bluetooth,
      missedHeartbeats: 4,
    );

    expect(snapshot.isConnected, isTrue);
    expect(snapshot.quality, PeerLinkQuality.unstable);
    expect(snapshot.qualityLabel, 'Unstable');
  });

  test('connecting is only used when no authenticated session is live', () {
    const snapshot = PeerConnectionSnapshot(
      phase: PeerConnectionPhase.connecting,
      transport: ConnectionTransport.bluetooth,
    );

    expect(snapshot.isConnected, isFalse);
    expect(snapshot.quality, PeerLinkQuality.connecting);
    expect(snapshot.qualityLabel, 'Connecting');
  });

  test('connection lifecycle keeps phase separate from transport quality', () {
    const offline = PeerConnectionSnapshot(
      phase: PeerConnectionPhase.offline,
    );
    const connectingBluetooth = PeerConnectionSnapshot(
      phase: PeerConnectionPhase.connecting,
      transport: ConnectionTransport.bluetooth,
    );
    const connectedBluetooth = PeerConnectionSnapshot(
      phase: PeerConnectionPhase.connected,
      transport: ConnectionTransport.bluetooth,
    );
    const unstableBluetooth = PeerConnectionSnapshot(
      phase: PeerConnectionPhase.connected,
      transport: ConnectionTransport.bluetooth,
      missedHeartbeats: 4,
    );
    const connectedLan = PeerConnectionSnapshot(
      phase: PeerConnectionPhase.connected,
      transport: ConnectionTransport.lan,
      latestRttMs: 12,
    );

    expect(offline.qualityLabel, 'Offline');
    expect(connectingBluetooth.qualityLabel, 'Connecting');
    expect(connectedBluetooth.qualityLabel, 'Connected');
    expect(unstableBluetooth.isConnected, isTrue);
    expect(unstableBluetooth.qualityLabel, 'Unstable');
    expect(
      isTransportUpgrade(
        unstableBluetooth.transport!,
        connectedLan.transport!,
      ),
      isTrue,
    );
    expect(connectedLan.qualityLabel, 'Excellent (12 ms)');
  });
}
