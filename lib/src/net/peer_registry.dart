import '../net/peer_session.dart';

/// Single source of truth for "which session is currently live for peer X".
///
/// Step 4 of the fix plan: AppState and SyncEngine both used to keep their
/// OWN bookkeeping of connected sessions (AppState had `_connectedSessions`
/// + `_connectedPeerIds`; SyncEngine had `_connectedSessionForPeer`). Two
/// sources of truth meant they could disagree — and when they disagreed,
/// sends went to a session the registry considered dead, or the engine's
/// single mutable field got overwritten mid-flight by a churn reconnect.
///
/// This class is the ONE place that maps peerId → live PeerSession. Both
/// AppState and SyncEngine hold a reference to the same instance. Publish
/// happens when a session becomes ready; drop happens when it's torn down.
/// Lookups are O(1).
///
/// IMPORTANT: this is not a connection manager. It does not own sockets or
/// drive reconnect logic — that stays in AppState. It's just the shared
/// lookup table, so the two consumers never disagree about who's connected.
class PeerConnectionRegistry {
  final _sessions = <String, PeerSession>{};

  /// The live session for [peerId], or null if none.
  PeerSession? sessionFor(String peerId) => _sessions[peerId];

  /// The live, open session for [peerId], or null if there is no session or
  /// the stored socket/codec has already closed.
  PeerSession? openSessionFor(String peerId) {
    final session = _sessions[peerId];
    if (session == null || session.isClosed) return null;
    return session;
  }

  /// The generation number of the live session for [peerId], or null if none.
  /// Used to reject stale callbacks: any async work that captured an OLD
  /// session's generation compares against this and bails if they differ.
  int? generationOf(String peerId) => _sessions[peerId]?.generation;

  /// Publish a session for a peer. If a different session is already
  /// registered for this peer, the caller is responsible for closing the
  /// old one (we just track the new here). Returns the previous session so
  /// the caller can close it directly — never via id lookup, which would
  /// target the new one.
  PeerSession? publish(String peerId, PeerSession session) {
    final previous = _sessions[peerId];
    _sessions[peerId] = session;
    return previous;
  }

  /// Drop the session for [peerId] ONLY if it matches [expected]. This
  /// identity check is what prevents a late teardown callback from an OLD
  /// socket (e.g. a bye or socket.done firing after a reconnect) from
  /// evicting the NEW session that replaced it.
  ///
  /// Returns true if the drop happened, false if the registered session is
  /// different (already replaced) and should be left alone.
  bool drop(String peerId, PeerSession expected) {
    final current = _sessions[peerId];
    if (!identical(current, expected)) return false;
    _sessions.remove(peerId);
    return true;
  }

  /// Drop whatever is registered for [peerId], unconditionally. Use only
  /// when the caller is certain no replacement exists (e.g. app shutdown).
  void forceDrop(String peerId) => _sessions.remove(peerId);

  /// All currently-live peer ids.
  Iterable<String> get connectedPeerIds => _sessions.keys;

  /// Peer ids whose registered session is still open.
  Iterable<String> get openPeerIds =>
      _sessions.entries.where((e) => !e.value.isClosed).map((e) => e.key);

  /// Peer ids whose registered session completed the post-handshake ready ack.
  Iterable<String> get readyPeerIds =>
      _sessions.entries.where((e) => e.value.isLinkReady).map((e) => e.key);

  bool get isEmpty => _sessions.isEmpty;
}
