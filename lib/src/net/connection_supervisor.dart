import 'dart:async';

import '../core/config_store.dart';
import '../diag.dart';
import 'discovery.dart';
import 'peer_registry.dart';

/// Owns the policy "every paired peer should have a live session" and keeps
/// trying to make that true, independent of discovery beacons.
///
/// Before this class existed, reconnect happened ONLY when a discovery beacon
/// arrived (every 3s). That had two gaps:
///   - If beacons were lost (broadcast packet loss, peer briefly off-network),
///     nothing reconnected — a paired peer could stay disconnected until the
///     next lucky beacon.
///   - If a session went half-dead, `_maybeAutoConnect` saw `isClosed == false`
///     and refused to redial, so recovery waited for the heartbeat timeout.
///
/// The supervisor closes both gaps by running a periodic sweep (every
/// [sweepInterval]) that, for every paired peer with no live session and no
/// in-flight connect, attempts a connect using the last-known discovered
/// address. Failures back off exponentially per-peer so a permanently-offline
/// peer isn't hammered; success resets the backoff. A peer coming back online
/// is reconnected within ≤[sweepInterval] of being reachable.
///
/// This is deliberately separate from [Discovery]: discovery still broadcasts
/// and still notifies onPeer (which feeds the immediate-connect path), but the
/// supervisor is the reliable fallback that does not depend on beacons.
/// (Priority 10 of the hardening plan: discovery/connection separation.)
///
/// The supervisor reuses the existing [PeerConnectionManager.connect] path —
/// it owns no sockets and no transport code, just the reconnect policy.
class ConnectionSupervisor {
  ConnectionSupervisor({
    required PeerConnectionRegistry registry,
    required ConfigStore config,
    required DiscoveredPeerCache discoveredPeers,
    required Future<void> Function(DiscoveredPeer peer) connect,
    required bool Function(String peerId) isConnecting,
    required bool Function(String peerId) isSuppressed,
  })  : _registry = registry,
        _config = config,
        _discoveredPeers = discoveredPeers,
        _connect = connect,
        _isConnecting = isConnecting,
        _isSuppressed = isSuppressed;

  final PeerConnectionRegistry _registry;
  final ConfigStore _config;
  final DiscoveredPeerCache _discoveredPeers;
  final Future<void> Function(DiscoveredPeer peer) _connect;
  final bool Function(String peerId) _isConnecting;
  final bool Function(String peerId) _isSuppressed;

  Timer? _timer;
  static const sweepInterval = Duration(seconds: 5);
  static const _maxBackoff = Duration(seconds: 30);

  // Per-peer connect bookkeeping. Cleared on [noteConnected]; grown on
  // failure. The next-attempt time gates whether a sweep tries this peer.
  final _failures = <String, int>{};
  final _nextAttemptAt = <String, DateTime>{};
  final _lastBeaconSeenAt = <String, DateTime>{};

  static const _peerReappearedAfter = Duration(seconds: 20);

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(sweepInterval, (_) => _sweep());
    // Sweep immediately so a peer we were connected to at last shutdown is
    // reconnected without waiting a full interval.
    _sweep();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _failures.clear();
    _nextAttemptAt.clear();
    _lastBeaconSeenAt.clear();
  }

  /// Called by AppState when a session becomes live for [peerId]. Resets that
  /// peer's backoff so a future disconnect reconnects immediately.
  void noteConnected(String peerId) {
    _failures.remove(peerId);
    _nextAttemptAt.remove(peerId);
  }

  /// Called by AppState when a session for [peerId] is torn down. Schedules a
  /// reconnect attempt on the next sweep (subject to backoff).
  void noteDisconnected(String peerId) {
    // A session that was previously established deserves a fresh recovery
    // cycle. Keep exponential backoff for repeated failed dials, but do not
    // carry that history across a real connected→disconnected transition.
    _failures.remove(peerId);
    _nextAttemptAt.remove(peerId);
  }

  /// Record a discovery beacon without letting every repeated UDP packet
  /// bypass connection backoff. A changed endpoint or a peer that reappeared
  /// after being absent gets one immediate retry; continuous beacons from an
  /// unreachable peer continue to respect exponential backoff.
  void notePeerSeen(
    DiscoveredPeer peer, {
    required bool endpointChanged,
  }) {
    final paired = _config.pairedPeers.any(
      (candidate) => candidate.deviceId == peer.deviceId,
    );
    if (!paired) return;
    final now = DateTime.now();
    final previous = _lastBeaconSeenAt[peer.deviceId];
    _lastBeaconSeenAt[peer.deviceId] = now;
    final reappeared = previous == null ||
        now.difference(previous) >= _peerReappearedAfter;
    if (!endpointChanged && !reappeared) return;
    _failures.remove(peer.deviceId);
    _nextAttemptAt.remove(peer.deviceId);
    _sweepPeer(peer.deviceId, now);
  }

  /// Clear reconnect backoff and immediately retry one peer. A single broken
  /// session should not reset the backoff of every other paired device that is
  /// intentionally out of range.
  void retryPeerNow(String peerId) {
    _failures.remove(peerId);
    _nextAttemptAt.remove(peerId);
    _sweepPeer(peerId, DateTime.now());
  }

  /// Clear reconnect backoff and run an immediate sweep. Used by explicit
  /// reconnect boosts and by a confirmed network-route change, where every
  /// saved endpoint may have become valid or invalid at once.
  void retryNow() {
    _failures.clear();
    _nextAttemptAt.clear();
    _sweep();
  }

  /// One sweep pass. For each paired peer with no live session and no
  /// in-flight connect, attempt a connect if the per-peer backoff allows.
  ///
  /// Suppressed peers (user tapped Disconnect) are skipped entirely — the
  /// supervisor keeps a paired peer connected automatically, but an explicit
  /// user disconnect is honored until the user reconnects.
  void _sweep() {
    final now = DateTime.now();
    for (final peer in _config.pairedPeers) {
      _sweepPeer(peer.deviceId, now);
    }
  }

  void _sweepPeer(String id, DateTime now) {
    if (_isSuppressed(id)) return;
    if (_registry.openSessionFor(id) != null) return;
    if (_isConnecting(id)) return;
    final next = _nextAttemptAt[id];
    if (next != null && now.isBefore(next)) return;

    // We need a reachable address. Prefer the last discovery beacon; if we
    // haven't seen one yet, wait for discovery or a saved endpoint seed.
    final discovered = _discoveredPeers.forPeer(id);
    if (discovered == null) return;
    _attemptConnect(discovered);
  }

  Future<void> _attemptConnect(DiscoveredPeer peer) async {
    Diag.session('supervisor_dial', peer: peer.deviceId);
    try {
      await _connect(peer);
      // Success clears backoff. (noteConnected is also called from AppState
      // on session-ready; this is the belt-and-suspenders path.)
      _failures.remove(peer.deviceId);
      _nextAttemptAt.remove(peer.deviceId);
    } catch (_) {
      // Transient failure — back off exponentially, capped at [_maxBackoff].
      final previous = _failures[peer.deviceId] ?? 0;
      final n = previous >= 5 ? 5 : previous + 1;
      _failures[peer.deviceId] = n;
      final delayMs = (1 << n) * 1000; // 2s, 4s, 8s, 16s, 30s, ...
      final delay = Duration(milliseconds: delayMs) > _maxBackoff
          ? _maxBackoff
          : Duration(milliseconds: delayMs);
      _nextAttemptAt[peer.deviceId] = DateTime.now().add(delay);
      Diag.session('supervisor_dial_failed',
          peer: peer.deviceId,
          fields: {'failures': n, 'backoffMs': delay.inMilliseconds});
    }
  }
}

/// Read-only view over the AppState's discovered-peers cache, so the
/// supervisor doesn't need a direct reference to AppState (avoids a cycle).
abstract class DiscoveredPeerCache {
  DiscoveredPeer? forPeer(String deviceId);
}
