import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/identity.dart';
import 'secure_handshake.dart';
import 'transport.dart';

/// A peer discovered on the local network.
class DiscoveredPeer {
  final String deviceId;
  final String name;
  final String platform;
  final InternetAddress address;
  final int port;
  final String publicKeyB64;
  final ConnectionTransport transport;
  final String? transportEndpoint;

  DiscoveredPeer({
    required this.deviceId,
    required this.name,
    required this.platform,
    required this.address,
    required this.port,
    required this.publicKeyB64,
    this.transport = ConnectionTransport.lan,
    this.transportEndpoint,
  });

  @override
  String toString() => '$name ($deviceId) @ ${address.address}:$port';
}

/// UDP beacon broadcaster + listener for LAN auto-discovery.
///
/// Each peer broadcasts a small JSON beacon every [interval] to the LAN
/// broadcast address. Listeners decode and surface peers via [onPeer].
///
/// Beacons are unencrypted but only carry public identity (device id, name,
/// platform, public key, listen port) — never secrets. Authentication of a
/// real connection happens over TLS during pairing.
class Discovery {
  Discovery({
    required this.self,
    required this.listenPort,
    this.port = 41827, // Conduit discovery UDP port
    this.interval = const Duration(seconds: 3),
    required this.onPeer,
  });

  final DeviceIdentity self;
  final int listenPort;
  final int port;
  final Duration interval;
  final void Function(DiscoveredPeer peer) onPeer;

  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  final _seen = <String, DateTime>{}; // deviceId -> last seen
  Timer? _sweepTimer;

  static const _sweepInterval = Duration(minutes: 1);
  static const _staleAfter = Duration(minutes: 5);

  // ---- Beacon backoff (Roadmap Phase 0.3) --------------------------------
  //
  // The beacon is the #1 phone battery drain: every UDP send forces the Wi-Fi
  // radio active, and the radio stays up ~1–2s after each send, so at the 3s
  // fast cadence it essentially never sleeps. So we run FAST only when it
  // matters — for ~30s after startup or a reconnect, to (re)establish the link
  // — and drop to SLOW while at least one session is live. The persistent
  // session + ConnectionSupervisor already cover re-acquisition, so the slow
  // cadence is purely for "let a newly-appeared peer notice us".
  //
  // [setBeaconMode] reschedules the broadcast timer with the new period. The
  // listener side (receive path) is unchanged.
  static const _fastInterval = Duration(seconds: 3);
  static const _recoveryInterval = Duration(seconds: 15);
  static const _idleInterval = Duration(minutes: 1);
  static const _stableInterval = Duration(minutes: 1);
  BeaconMode _mode = BeaconMode.fast;
  bool _boosted = false;
  DateTime _fastModeStartedAt = DateTime.now();

  Duration get _currentInterval {
    if (_boosted) return _fastInterval;
    if (_mode == BeaconMode.stable) return _stableInterval;
    final elapsed = DateTime.now().difference(_fastModeStartedAt);
    if (elapsed < const Duration(seconds: 30)) return _fastInterval;
    if (elapsed < const Duration(minutes: 5)) return _recoveryInterval;
    return _idleInterval;
  }

  /// Switch the broadcast cadence between [BeaconMode.fast] (3s — used right
  /// after startup / a reconnect so peers find us quickly) and
  /// [BeaconMode.stable] (1m — used once at least one session is live, so the
  /// Wi-Fi radio gets to sleep between beacons). Idempotent: a no-op if the
  /// mode is already current. Fast mode automatically backs off from 3 seconds
  /// to 15 seconds and then 1 minute when a peer remains unavailable.
  void setBeaconMode(BeaconMode mode) {
    if (mode == _mode) return;
    _mode = mode;
    if (mode == BeaconMode.fast) _fastModeStartedAt = DateTime.now();
    final running = _broadcastTimer;
    if (running == null) return; // not started — start() will pick it up
    running.cancel();
    _scheduleBroadcast();
  }

  /// Temporarily force the fastest beacon cadence. The caller owns the timer
  /// that turns this off; regular fast-mode backoff is suspended while active.
  void setBoosted(bool enabled) {
    if (_boosted == enabled) return;
    _boosted = enabled;
    final running = _broadcastTimer;
    if (running == null) return;
    running.cancel();
    if (enabled) _broadcast();
    _scheduleBroadcast();
  }

  Future<void> start() async {
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
    _socket!.broadcastEnabled = true;

    _broadcast(); // immediate first beacon
    _scheduleBroadcast();

    // sweep stale peers out periodically
    _sweepTimer = Timer.periodic(_sweepInterval, (_) => _sweep());

    _socket!.listen((event) {
      if (event == RawSocketEvent.read) {
        final dg = _socket!.receive();
        if (dg == null) return;
        _handleDatagram(dg);
      }
    });
  }

  Future<void> stop() async {
    _broadcastTimer?.cancel();
    _sweepTimer?.cancel();
    _socket?.close();
    _socket = null;
    _seen.clear();
  }

  /// Fire an immediate beacon outside the periodic timer's schedule. Used on
  /// app resume (after background/sleep) so peers learn our current address
  /// without waiting up to the full [interval] — important when the network
  /// may have changed (new Wi-Fi, woke from Doze) and our beacon was missed.
  void reannounce() {
    if (_socket == null) return; // not started yet, or stopped
    _broadcast();
  }

  void _scheduleBroadcast() {
    _broadcastTimer = Timer(_currentInterval, () {
      if (_socket == null) return;
      _broadcast();
      _scheduleBroadcast();
    });
  }

  void _broadcast() {
    final payload = jsonEncode({
      'v': 1,
      'secureTransportVersion': secureTransportVersion,
      'deviceId': self.deviceId,
      'name': self.name,
      'platform': self.platform,
      'pubKey': self.publicKeyB64,
      'port': listenPort,
    });
    try {
      _socket?.send(
        utf8.encode(payload),
        InternetAddress('255.255.255.255'),
        port,
      );
    } catch (_) {
      // ignore transient send failures
    }
  }

  void _handleDatagram(Datagram dg) {
    try {
      final j = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
      if (j['v'] != 1) return;
      final id = j['deviceId'] as String;
      if (id == self.deviceId) return; // ourselves
      _seen[id] = DateTime.now();
      onPeer(DiscoveredPeer(
        deviceId: id,
        name: j['name'] as String,
        platform: j['platform'] as String,
        address: dg.address,
        port: j['port'] as int,
        publicKeyB64: j['pubKey'] as String,
      ));
    } catch (_) {
      // malformed beacon — ignore
    }
  }

  void _sweep() {
    final now = DateTime.now();
    _seen.removeWhere((_, t) => now.difference(t) > _staleAfter);
  }

  /// Encode this device's identity + listening port (and, optionally, a
  /// one-time pairing code) into a QR payload for the manual-connect flow.
  ///
  /// If [pairCode] is supplied it is embedded in the token; the scanner then
  /// auto-uses it and the user never has to type anything. The server-side
  /// handshake still verifies the code (single-use, consumed on pair), so
  /// embedding it does not weaken security — observing the QR is equivalent to
  /// observing the code typed aloud, and the code is valid only for one pair.
  ///
  /// [hosts] is the ranked list of candidate local IPs (best first). The QR
  /// carries all of them so the scanner can try each in turn — this matters
  /// because a PC often has a VPN/virtual adapter (CloudflareWARP, WSL, …)
  /// whose address the phone can't reach; by trying all candidates we avoid
  /// relying on a single heuristic pick.
  ///
  /// Decoded by [decodeConnectToken] / [decodeConnectTokenFull].
  String encodeConnectToken({
    InternetAddress? address,
    List<String> hosts = const [],
    String? pairCode,
    bool bluetoothAvailable = false,
  }) {
    final host = address?.address ?? '';
    // Dedup + preserve order: primary address first, then any extras.
    final all = <String>[if (host.isNotEmpty) host, ...hosts]
        .where((h) => h.isNotEmpty)
        .toSet()
        .toList();
    return jsonEncode({
      'v': 1,
      'secureTransportVersion': secureTransportVersion,
      'type': 'conduit-connect',
      'deviceId': self.deviceId,
      'name': self.name,
      'platform': self.platform,
      'pubKey': self.publicKeyB64,
      'host': all.isNotEmpty ? all.first : '',
      'hosts': all,
      'port': listenPort,
      if (bluetoothAvailable) 'bluetooth': true,
      if (pairCode != null) 'pairCode': pairCode,
    });
  }

  /// Decode a connect token, returning the peer info, all candidate hosts
  /// (best first), and any pairing code embedded in it. Returns null if the
  /// token is malformed or carries no reachable host at all.
  static ({
    DiscoveredPeer peer,
    List<InternetAddress> hosts,
    String? pairCode,
    bool bluetoothAvailable,
  })? decodeConnectTokenFull(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['type'] != 'conduit-connect') return null;
      // Prefer the explicit `hosts` list; fall back to the single `host`
      // field for tokens produced by older builds.
      final rawHosts = (j['hosts'] as List<dynamic>?)?.cast<String>() ??
          [
            if ((j['host'] as String?)?.isNotEmpty ?? false) j['host'] as String
          ];
      final bluetoothAvailable = j['bluetooth'] == true;
      if (rawHosts.isEmpty && !bluetoothAvailable) return null;
      final hosts = rawHosts.map(InternetAddress.new).toList();
      return (
        peer: DiscoveredPeer(
          deviceId: j['deviceId'] as String,
          name: j['name'] as String,
          platform: j['platform'] as String,
          address: hosts.isEmpty ? InternetAddress.loopbackIPv4 : hosts.first,
          port: j['port'] as int,
          publicKeyB64: j['pubKey'] as String,
        ),
        hosts: hosts,
        pairCode: j['pairCode'] as String?,
        bluetoothAvailable: bluetoothAvailable,
      );
    } catch (_) {
      return null;
    }
  }

  /// Back-compat wrapper: returns just the peer, ignoring any embedded code.
  static DiscoveredPeer? decodeConnectToken(String raw) {
    return decodeConnectTokenFull(raw)?.peer;
  }
}

/// Beacon cadence modes for [Discovery.setBeaconMode] (Roadmap Phase 0.3).
enum BeaconMode {
  /// Fast broadcast (3s) — used for ~30s after startup/reconnect to establish
  /// the link quickly.
  fast,

  /// Slower broadcast (1m) — used once a session is live, letting the Wi-Fi
  /// radio sleep between beacons.
  stable,
}

/// Discover the local network interfaces' IPv4 addresses, sorted so that the
/// most likely-to-be-reachable address comes first.
///
/// A common failure on PCs is that a VPN client (CloudflareWARP, Tailscale,
/// OpenVPN) or a virtual bridge (WSL, Hyper-V, Docker, VirtualBox, VMWare)
/// installs a virtual adapter that Dart's `NetworkInterface.list` returns
/// *before* the real Wi-Fi/Ethernet adapter. If we pick that address for the
/// QR token, the phone (on real Wi-Fi) can never reach it →
/// `Connection timed out`. So we filter and rank here.
///
/// Ranking (best first):
///   1. RFC1918 private addresses on a non-virtual adapter
///   2. Other private addresses
///   3. Everything else (public, etc.) — last resort
///
/// Virtual/VPN adapter names are detected by substring match on the interface
/// name (case-insensitive).
Future<List<String>> localIpAddresses() async {
  // Substrings that identify virtual / tunnel adapters. Matched
  // case-insensitively against the interface name reported by the OS.
  const virtualHints = [
    'warp', // Cloudflare WARP
    'tailscale',
    'wireguard',
    'openvpn',
    'tun', // generic tun/tap
    'tap',
    'vethernet', // Hyper-V / WSL
    'vEthernet',
    'docker',
    'virtualbox',
    'vmware',
    'vmnet',
    'hyperv',
    'loopback pseudo',
    'bluetooth',
  ];

  bool isVirtual(String name) {
    final lower = name.toLowerCase();
    return virtualHints.any((h) => lower.contains(h.toLowerCase()));
  }

  final ranked = <_CandidateIp>[];
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    for (final iface in interfaces) {
      final virtual = isVirtual(iface.name);
      for (final addr in iface.addresses) {
        if (addr.isLoopback) continue;
        // A /32 mask on a non-PPP adapter is a strong VPN-tunnel signal
        // (CloudflareWARP uses 172.16.0.2/32). Treat as virtual.
        final tunnel = iface.addresses.length == 1 &&
            addr.type == InternetAddressType.IPv4 &&
            _looksLikeTunnel(addr);
        final score = _rankScore(addr, virtual: virtual || tunnel);
        ranked.add(_CandidateIp(addr.address, score));
      }
    }
  } catch (_) {
    // ignore — caller falls back to manual entry
  }
  ranked.sort((a, b) => b.score.compareTo(a.score));
  return ranked.map((c) => c.address).toList();
}

class _CandidateIp {
  final String address;
  final int score;
  _CandidateIp(this.address, this.score);
}

/// Heuristic: a /32 host route is almost always a VPN tunnel (WARP, some
/// Tailscale configs). We can't read the mask directly from Dart, so we use
/// the address itself: WARP hands out 172.16.x.x/32, Tailscale 100.64.x.x/32.
/// Treat the CGNAT range 100.64.0.0/10 and a couple of telltale ranges as
/// tunnel-like.
bool _looksLikeTunnel(InternetAddress a) {
  final b = a.rawAddress;
  if (b.length != 4) return false;
  // 100.64.0.0/10 — CGNAT, used by Tailscale & co.
  if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return true;
  // 172.16.x.x with a /32 (CloudflareWARP pattern) — we can't see the mask,
  // but combined with the isVirtual name check this is covered there. Keep
  // this function conservative.
  return false;
}

int _rankScore(InternetAddress a, {required bool virtual}) {
  var score = 0;
  if (isRfcPrivate(a)) score += 100; // real LAN ranges
  if (!virtual) score += 50; // prefer non-virtual adapters
  return score;
}

bool isRfcPrivate(InternetAddress a) {
  final b = a.rawAddress;
  if (b.length != 4) return false;
  if (b[0] == 10) return true;
  if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
  if (b[0] == 192 && b[1] == 168) return true;
  return false;
}
