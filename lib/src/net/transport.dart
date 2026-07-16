enum ConnectionTransport { lan, bluetooth }

enum PeerConnectionPhase { offline, connecting, connected }

enum PeerLinkQuality { offline, connecting, healthy, degraded, unstable }

class PeerConnectionSnapshot {
  const PeerConnectionSnapshot({
    required this.phase,
    this.transport,
    this.latestRttMs,
    this.missedHeartbeats = 0,
  });

  final PeerConnectionPhase phase;
  final ConnectionTransport? transport;
  final int? latestRttMs;
  final int missedHeartbeats;

  bool get isConnected => phase == PeerConnectionPhase.connected;

  PeerLinkQuality get quality {
    if (phase == PeerConnectionPhase.offline) return PeerLinkQuality.offline;
    if (phase == PeerConnectionPhase.connecting) {
      return PeerLinkQuality.connecting;
    }
    if (missedHeartbeats >= 4) return PeerLinkQuality.unstable;
    if (missedHeartbeats >= 2 || (latestRttMs != null && latestRttMs! >= 100)) {
      return PeerLinkQuality.degraded;
    }
    return PeerLinkQuality.healthy;
  }

  String get qualityLabel => switch (quality) {
        PeerLinkQuality.offline => 'Offline',
        PeerLinkQuality.connecting => 'Connecting',
        PeerLinkQuality.unstable => 'Unstable',
        PeerLinkQuality.degraded when latestRttMs != null =>
          'Spotty ($latestRttMs ms)',
        PeerLinkQuality.degraded => 'Spotty',
        PeerLinkQuality.healthy when latestRttMs == null => 'Connected',
        PeerLinkQuality.healthy when latestRttMs! < 30 =>
          'Excellent ($latestRttMs ms)',
        PeerLinkQuality.healthy => 'Good ($latestRttMs ms)',
      };
}

extension ConnectionTransportInfo on ConnectionTransport {
  String get label => switch (this) {
        ConnectionTransport.lan => 'LAN',
        ConnectionTransport.bluetooth => 'Bluetooth',
      };

  bool get isBandwidthConstrained => this == ConnectionTransport.bluetooth;

  int get priority => switch (this) {
        ConnectionTransport.lan => 2,
        ConnectionTransport.bluetooth => 1,
      };
}

bool isTransportUpgrade(
  ConnectionTransport current,
  ConnectionTransport candidate,
) =>
    candidate.priority > current.priority;

const int bluetoothLargeTransferLimitBytes = 10 * 1024 * 1024;
