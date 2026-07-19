import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../core/config_store.dart';
import '../core/identity.dart';
import '../diag.dart';
import '../protocol/wire.dart';
import 'discovery.dart';
import 'peer_registry.dart';
import 'secure_frame.dart';
import 'secure_handshake.dart';
import 'transport.dart';
import 'bluetooth_bridge.dart';

/// Callback shape for an established (post-handshake) session with a peer.
///
/// Returns true when the app accepts the session as the live one. Returning
/// false closes this just-handshaken socket without publishing it.
typedef OnSessionReady = bool Function(PeerSession session);

/// State of an outgoing/incoming pairing attempt.
enum PairingState { idle, awaitingPeerConfirm, confirmed, rejected }

/// An armed, single-use, time-limited incoming pairing code. If
/// [boundPubKey] is non-null, the code is only accepted from a hello
/// claiming that exact pubkey (see [PeerConnectionManager.armPairingFor]);
/// otherwise any hello carrying the right code is accepted (see
/// [PeerConnectionManager.armGenericPairing]).
class _PendingPairCode {
  _PendingPairCode(
      {required this.code, required this.boundPubKey, required this.expiresAt});
  final String code;
  final String? boundPubKey;
  final DateTime expiresAt;
}

/// One established connection with a paired peer. Owns the socket + codec.
///
/// Message ownership model (Step 2 of the fix plan): there is exactly ONE
/// handler for incoming messages on this session, set via [onMessage].
/// Setting it forwards to [FrameCodec.onMessage] synchronously. This removes
/// the broadcast-stream silent-drop failure mode entirely: a decoded message
/// can never arrive at a moment when nobody owns the stream, because
/// reassignment is synchronous and there's no buffer to miss.
///
/// Lifecycle of [onMessage]:
///   1. During the handshake, the codec's onMessage points at a temporary
///      handshake handler (set by PeerConnectionManager before listen()).
///   2. After the handshake completes, PeerConnectionManager builds this
///      PeerSession and calls onSessionReady(session).
///   3. The engine's onPeerConnected does `session.onMessage = ...`, taking
///      over as the permanent owner. From that point, every message flows
///      straight to the engine with zero chance of being dropped.
class PeerSession {
  PeerSession({
    required this.peer,
    required this.socket,
    required this.codec,
    required this.initiatedByUs,
    this.features = const [],
    ConnectionTransport transport = ConnectionTransport.lan,
    String? transportEndpoint,
  }) : generation = _nextGeneration() {
    _sessionTransports[this] = transport;
    if (transportEndpoint != null) {
      _sessionTransportEndpoints[this] = transportEndpoint;
    }
  }

  final PairedPeer peer;
  final Socket socket;
  final FrameCodec codec;
  final bool initiatedByUs;
  final List<String> features;

  int? latestRttMs;
  final List<int> recentRttMs = [];
  VoidCallback? onHeartbeat;

  /// Monotonically-increasing per-connection number (process-global, so a NEW
  /// session for the same peer is always strictly greater than the OLD one it
  /// replaced). Used to reject stale callbacks from a superseded session: any
  /// captured async work compares the generation it closed over against the
  /// registry's current generation for this peer and bails out if they differ.
  final int generation;
  static int _genCounter = 0;
  static int _nextGeneration() => ++_genCounter;

  /// Wall-clock time of the last proof this session is actually alive, set at
  /// construction and refreshed by [restartHeartbeat] (which the engine calls
  /// on EVERY inbound message). Used by [PeerConnectionManager._onHello]'s
  /// duplicate-connection guard to tell a genuine simultaneous-connect race
  /// (the existing session is brand-new and unproven) apart from a half-dead
  /// socket that the peer is legitimately trying to reconnect past: a session
  /// that has received traffic within [_raceWindow] is considered live and is
  /// protected from a competing dial; one that hasn't is treated as stale and
  /// the new connection supersedes it.
  DateTime lastActivityAt = DateTime.now();

  /// Grace period during which a newly-established session is presumed to be
  /// the winning half of a simultaneous-connect race and a competing dial is
  /// rejected. Picked to comfortably exceed the 3.5s connect stagger
  /// (AppState._dialPeer) plus a full handshake + a heartbeat round-trip, so
  /// the *losing* dial of a real race still arrives inside this window and
  /// gets rejected (preserving the original manifest-corruption fix), while a
  /// reconnect that arrives once the session has gone silent for this long is
  /// a genuine "peer reconnected past our half-dead socket" and is accepted.
  static const _raceWindow = Duration(seconds: 8);

  /// The single owner of incoming messages for this session. Reassigning
  /// this is synchronous and instant — see class docs.
  set onMessage(void Function(Map<String, dynamic> msg) handler) =>
      codec.onMessage = handler;

  /// Error channel — fires on socket errors or malformed envelopes.
  set onError(void Function(Object error) handler) => codec.onError = handler;

  /// Done channel — fires once when the socket closes (either side).
  set onDone(void Function() handler) => codec.onDone = handler;

  /// The remote IP this socket is connected to. Used to detect that a
  /// previously-connected peer has moved to a new address.
  String get remoteAddress => socket.remoteAddress.address;

  /// True once the socket has closed (either side). Set by the codec's
  /// onDone/onError path. Used by AppState to decide whether a session is
  /// still worth keeping before redialing — see _maybeAutoConnect.
  bool get isClosed => codec.isClosed;

  bool _linkReady = false;
  bool get hasReceivedLinkReady => _linkReady;
  bool get isLinkReady => _linkReady && !isClosed;
  VoidCallback? onLinkReady;

  bool markLinkReady() {
    if (_linkReady) return false;
    _linkReady = true;
    Diag.session('link_ready', peer: peer.deviceId, session: generation);
    onLinkReady?.call();
    return true;
  }

  void send(Map<String, dynamic> msg) => codec.send(msg);

  Future<void> close() async {
    try {
      codec.send({'t': Msg.bye});
    } catch (_) {}
    await codec.close();
  }

  // ---- Heartbeat (Step 1 of the fix plan) --------------------------------
  //
  // TCP keepalive is unreliable for detecting a half-dead peer (Windows
  // defaults to ~2h). We run an app-level heartbeat: ping every [_hbInterval],
  // drop the session after [_hbMissedThreshold] consecutive unanswered pings.
  //
  // The heartbeat timer is fully owned by the session. The engine's message
  // handler calls [restartHeartbeat] every time any message arrives (any
  // traffic = alive), which resets the miss counter AND the periodic timer.
  // Only SILENCE for [_hbMissedThreshold] × [_hbInterval] triggers the dead
  // path.
  Timer? _heartbeat;
  VoidCallback? _onHeartbeatDead;
  int _missed = 0;

  /// Id of the most recent ping we sent, and when. A pong echoing this id
  /// proves liveness AND lets us measure RTT. Null before the first ping or
  /// after its pong has landed.
  String? _pendingPingId;
  DateTime? _pendingPingSentAt;
  int _pingSeq = 0;

  static const _hbInterval = Duration(seconds: 12);
  static const _hbMissedThreshold = 6;
  static const _autoTakeoverMissedThreshold = 2;

  bool get canBeSupersededByAutoReconnect {
    if (DateTime.now().difference(lastActivityAt) < _raceWindow) return false;
    return _missed >= _autoTakeoverMissedThreshold;
  }

  int get missedHeartbeats => _missed;

  /// Start the heartbeat timer. The peer answers each ping with a pong
  /// (handled in the engine); if we don't see enough pongs in a row, fire
  /// [onDead] so the caller can tear the session down.
  void startHeartbeat({required VoidCallback onDead}) {
    _onHeartbeatDead = onDead;
    _missed = 0;
    _pendingPingId = null;
    _pendingPingSentAt = null;
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(_hbInterval, (_) => _tick());
  }

  void _tick() {
    if (codec.isClosed) {
      _heartbeat?.cancel();
      return;
    }
    _missed++;
    onHeartbeat?.call();
    if (_missed >= _hbMissedThreshold) {
      _heartbeat?.cancel();
      Diag.heartbeat('hb_dead',
          peer: peer.deviceId, session: generation, missed: _missed);
      _onHeartbeatDead?.call();
      return;
    }
    _pingSeq += 1;
    final pingId = '$generation-$_pingSeq';
    _pendingPingId = pingId;
    _pendingPingSentAt = DateTime.now();
    Diag.heartbeat('hb_send',
        peer: peer.deviceId, session: generation, hbId: pingId);
    try {
      codec.send({'t': Msg.ping, 'hb': pingId});
    } catch (_) {
      _heartbeat?.cancel();
      Diag.heartbeat('hb_dead',
          peer: peer.deviceId, session: generation, missed: _missed);
      _onHeartbeatDead?.call();
    }
  }

  /// Handle a pong from the peer. If it echoes the id of the ping we most
  /// recently sent, record the round-trip time and clear the pending slot
  /// (so a subsequent dup pong is ignored). A bare pong from an older peer
  /// (no `hb` field) just clears the slot if one is pending — the miss
  /// counter is already reset by [restartHeartbeat] for any traffic.
  void handlePong(String? hbId) {
    if (_pendingPingId != null && (hbId == null || hbId == _pendingPingId)) {
      final sentAt = _pendingPingSentAt;
      final rttMs = sentAt == null
          ? null
          : DateTime.now().difference(sentAt).inMilliseconds;
      if (rttMs != null) {
        latestRttMs = rttMs;
        recentRttMs.add(rttMs);
        if (recentRttMs.length > 10) {
          recentRttMs.removeAt(0);
        }
      }
      Diag.heartbeat('hb_pong',
          peer: peer.deviceId,
          session: generation,
          hbId: _pendingPingId,
          rttMs: rttMs);
      _pendingPingId = null;
      _pendingPingSentAt = null;
      onHeartbeat?.call();
    }
  }

  /// Called by the engine whenever ANY message arrives from the peer (pong,
  /// manifest, chunk, etc.) — any traffic is proof of life. Resets the miss
  /// counter to zero and reschedules the next ping for a full interval away,
  // so a steady stream of traffic keeps the session alive indefinitely; only
  // SILENCE for [_hbMissedThreshold] × [_hbInterval] triggers the dead path.
  void restartHeartbeat() {
    if (_onHeartbeatDead == null) return; // heartbeat never started
    final wasMissed = _missed > 0;
    lastActivityAt = DateTime.now(); // proof of life for the dup-hello guard
    _missed = 0;
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(_hbInterval, (_) => _tick());
    if (wasMissed) {
      onHeartbeat?.call();
    }
  }

  void stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _onHeartbeatDead = null;
    _pendingPingId = null;
    _pendingPingSentAt = null;
  }
}

final Expando<ConnectionTransport> _sessionTransports =
    Expando<ConnectionTransport>('connectionTransport');
final Expando<String> _sessionTransportEndpoints =
    Expando<String>('connectionTransportEndpoint');

/// Transport metadata is kept outside the structural [PeerSession] interface.
/// Test doubles that implement PeerSession therefore remain source-compatible
/// and safely default to LAN unless explicitly constructed by production code.
extension PeerSessionTransport on PeerSession {
  ConnectionTransport get transport =>
      _sessionTransports[this] ?? ConnectionTransport.lan;

  String? get transportEndpoint => _sessionTransportEndpoints[this];

  bool get isBandwidthConstrained => transport.isBandwidthConstrained;
}

typedef VoidCallback = void Function();

/// Manages the listening socket, accepts incoming peer connections, performs
/// the hello/welcome/pairAccept handshake, and emits ready sessions.
///
/// Pairing flow (first-time):
///   initiator → peer:   hello{pairCode, pubKey, ...}
///   peer → initiator:   welcome{pubKey, ...}                  (if pairCode ok)
///   both:               rememberPeer(...) ; emit session ready
///
/// For an already-paired peer (recognised deviceId), pairCode is omitted and
/// only the pubkey is checked against the stored pin.
class PeerConnectionManager {
  PeerConnectionManager({
    required this.identity,
    required this.config,
    required this.registry,
    required this.onSessionReady,
    required this.onPairingRequest,
    this.resolveIncomingTransport,
    this.listenPort = kDefaultListenPort,
  });

  final DeviceIdentity identity;
  final ConfigStore config;

  /// Shared live-session registry (same instance AppState + SyncEngine hold).
  /// Used by [_onHello] to reject a second simultaneous dial from a peer we
  /// already have a live session with — see Part 1 of the manifest-corruption
  /// fix. Without this, two peers dialing each other at the same time each
  /// produce two sessions; the registry then evicts one by destroying its
  /// socket mid-handshake or mid-sync, corrupting the manifest exchange.
  final PeerConnectionRegistry registry;
  final OnSessionReady onSessionReady;
  final void Function(DiscoveredPeer peer, String code) onPairingRequest;
  final IncomingTransport Function(int remotePort)? resolveIncomingTransport;

  int listenPort;
  ServerSocket? _server;
  final Map<String, PeerSession> _active = {}; // deviceId -> session
  final _rand = Random.secure();
  _PendingPairCode? _pendingIncomingPairCode;
  static const _pairCodeTtl = Duration(minutes: 2);

  final sessionsController = StreamController<PeerSession>.broadcast();
  Stream<PeerSession> get sessionStream => sessionsController.stream;

  bool get isRunning => _server != null;

  /// Default TCP listen port for incoming peer connections. Kept stable
  /// across launches so the user's firewall rule keeps working. Falls back
  /// to an OS-assigned ephemeral port if busy.
  static const int kDefaultListenPort = 41828;

  Future<int> start() async {
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, listenPort);
    } on SocketException {
      final requested = listenPort;
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      // ignore: avoid_print
      print('[Conduit] port $requested busy, bound ephemeral '
          '${_server!.port}. Configure a firewall rule for the new port.');
    }
    listenPort = _server!.port;
    _server!.listen(_handleIncoming);
    return listenPort;
  }

  Future<void> stop() async {
    // Closing can trigger a done callback that removes from [_active].
    for (final s in _active.values.toList(growable: false)) {
      await s.close();
    }
    _active.clear();
    await _server?.close();
    _server = null;
  }

  /// Close a single peer session (if any) without touching the server socket.
  Future<void> stopSession(String deviceId) async {
    final s = _active.remove(deviceId);
    if (s != null) {
      try {
        await s.close();
      } catch (_) {}
    }
  }

  bool hasSession(String deviceId) => _active.containsKey(deviceId);

  // ---- Server side (accept) ----------------------------------------------
  //
  // The codec uses a single onMessage callback. During the handshake we point
  // it at a temporary handler that processes hello and (on success) hands off
  // to the permanent engine handler via _publishSession. There is no window
  // where a message can arrive unowned: the handler is set BEFORE listen()
  // starts pumping the socket.

  void _handleIncoming(Socket socket) async {
    // Perf: mirror the client-side setting in connectMultiHost — whichever
    // side dialed, both ends of the socket should skip Nagle's algorithm.
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    final codec = FrameCodec(socket);
    final secureOffer = await SecureHandshake.createOffer();
    // Temp handshake handler. Owns all messages until hello/welcome completes,
    // then _publishSession hands the codec to PeerSession and the engine
    // reassigns onMessage.
    codec.onMessage = (msg) async {
      final type = msg['t'] as String?;
      if (type == Msg.hello) {
        try {
          await _onHello(socket, codec, secureOffer, msg);
        } catch (e, st) {
          // ignore: avoid_print
          print('[Conduit] _onHello failed: $e\n$st');
          try {
            codec.send(
                {'t': Msg.error, 'message': 'internal error processing hello'});
          } catch (_) {}
          await socket.close();
        }
      }
      // Any other message during the handshake phase is unexpected; ignore.
    };
    codec.onError = (Object e) {
      // ignore: avoid_print
      print('[Conduit] server codec error: $e');
    };
    codec.listen();
  }

  Future<void> _onHello(
    Socket socket,
    FrameCodec codec,
    SecureHandshakeOffer secureOffer,
    Map<String, dynamic> hello,
  ) async {
    final incoming = resolveIncomingTransport?.call(socket.remotePort) ??
        const IncomingTransport(ConnectionTransport.lan);
    final peerDeviceId = hello['deviceId'] as String;
    final peerName = hello['name'] as String;
    final peerPlatform = hello['platform'] as String;
    final peerPubKey = hello['pubKey'] as String;
    if (hello['secureVersion'] != secureTransportVersion) {
      codec.send({
        't': Msg.error,
        'message':
            'This device uses an older insecure Conduit protocol. Update Conduit on both devices.',
      });
      await socket.close();
      return;
    }

    final known = config.pairedPeers.firstWhere(
      (p) => p.deviceId == peerDeviceId,
      orElse: () => PairedPeer(
        deviceId: peerDeviceId,
        name: peerName,
        platform: peerPlatform,
        publicKeyB64: peerPubKey,
      ),
    );

    final isAlreadyPaired =
        config.pairedPeers.any((p) => p.deviceId == peerDeviceId);
    final forceTakeover = hello['takeover'] == true && isAlreadyPaired;

    if (!isAlreadyPaired) {
      final pending = _pendingIncomingPairCode;
      final proof = hello['pairingProof'] as String?;
      if (pending == null ||
          proof == null ||
          !_constantTimeEquals(
            proof,
            _pairingProof(pending.code, hello),
          )) {
        codec.send({
          't': Msg.error,
          'message': 'pairing required: wrong/missing code'
        });
        await socket.close();
        return;
      }
      if (DateTime.now().isAfter(pending.expiresAt)) {
        _pendingIncomingPairCode = null;
        codec.send(
            {'t': Msg.error, 'message': 'pairing required: code expired'});
        await socket.close();
        return;
      }
      if (pending.boundPubKey != null && peerPubKey != pending.boundPubKey) {
        codec.send({'t': Msg.error, 'message': 'pubkey mismatch'});
        await socket.close();
        return;
      }
    } else {
      if (peerPubKey != known.publicKeyB64) {
        codec.send({'t': Msg.error, 'message': 'pinned pubkey mismatch'});
        await socket.close();
        return;
      }
    }

    // Part 1 of the manifest-corruption fix: reject a duplicate dial. If we
    // already have a live, non-closed session for this peer, a second dial is
    // the losing half of a simultaneous-connect race (both sides dialed each
    // other). Keeping the existing session and rejecting this hello means
    // exactly one session survives — no eviction, no socket destruction
    // mid-sync. The dialer of the rejected hello gets this error, its
    // _handshake throws, its _dialPeer catch swallows it, and no churn
    // follows. (The registry's identity-guarded drop already made eviction
    // non-looping, but eviction still corrupted in-flight manifest/fetch
    // work — preventing it here is the clean fix.)
    //
    // BUT a flat reject also blocks a legitimate reconnect past a half-dead
    // socket. The safe middle ground is: keep an existing open session unless
    // our heartbeat has already started missing replies. A merely idle socket
    // is not stale; replacing it on every late duplicate hello creates the
    // visible connect/disconnect churn reported from the Activity screen.
    //
    // A takeover flag is treated as intent, not permission. Older builds used
    // takeover on every automatic reconnect; accepting that unconditionally
    // lets two healthy sockets force-replace each other forever. So a takeover
    // still has to pass the same stale-session test before it can supersede an
    // open connection.
    final existing = registry.sessionFor(peerDeviceId);
    if (existing != null &&
        !existing.isClosed &&
        !isTransportUpgrade(existing.transport, incoming.transport) &&
        !existing.canBeSupersededByAutoReconnect) {
      Diag.session('dup_hello_rejected',
          peer: peerDeviceId,
          session: existing.generation,
          fields: {
            'takeover': forceTakeover,
            'silentMs': DateTime.now()
                .difference(existing.lastActivityAt)
                .inMilliseconds,
            'missed': existing.missedHeartbeats,
          });
      codec.send({'t': Msg.error, 'message': 'duplicate connection'});
      await socket.close();
      return;
    }
    if (existing != null) {
      Diag.session(forceTakeover ? 'dup_hello_takeover' : 'dup_hello_supersede',
          peer: peerDeviceId,
          session: existing.generation,
          fields: {
            'silentMs': DateTime.now()
                .difference(existing.lastActivityAt)
                .inMilliseconds,
            'missed': existing.missedHeartbeats,
          });
    }
    final features = (hello['features'] as List?)?.cast<String>().toList() ??
        const <String>[];
    final welcome = <String, dynamic>{
      't': Msg.welcome,
      'deviceId': identity.deviceId,
      'name': identity.name,
      'platform': identity.platform,
      'pubKey': identity.publicKeyB64,
      'features': [
        'device_status_v1',
        'phone_alert_v1',
        'transfer_receipt_v1',
      ],
      ...secureOffer.toJson(),
    };
    final transcript = SecureHandshake.transcript(
      initiator: hello,
      responder: welcome,
    );
    welcome['signature'] = SecureHandshake.sign(identity, transcript);
    codec.send(welcome);

    final finish = await waitForMessage(codec, 'secure_finish',
        timeout: const Duration(seconds: 10));
    if (!SecureHandshake.verify(
      identity,
      transcript,
      finish['signature'] as String,
      peerPubKey,
    )) {
      throw StateError('secure handshake signature mismatch');
    }
    final keys = await SecureHandshake.deriveKeys(
      local: secureOffer,
      remoteEphemeralKey: hello['ephemeralKey'] as String,
      transcriptHash: transcript,
      initiator: false,
    );
    codec.send({'t': 'secure_switch'});
    codec.enableSecurity(keys);
    await waitForMessage(codec, 'secure_confirm',
        timeout: const Duration(seconds: 10));
    codec.send({'t': 'secure_confirmed'});
    if (!isAlreadyPaired) _pendingIncomingPairCode = null;

    final peer = PairedPeer(
      deviceId: peerDeviceId,
      name: peerName,
      platform: peerPlatform,
      publicKeyB64: peerPubKey,
    );
    if (!isAlreadyPaired) {
      await config.rememberPeer(peer);
    }
    _publishSession(
      peer,
      socket,
      codec,
      initiatedByUs: false,
      features: features,
      transport: incoming.transport,
      transportEndpoint: incoming.endpointId,
    );
  }

  bool _publishSession(
    PairedPeer peer,
    Socket socket,
    FrameCodec codec, {
    required bool initiatedByUs,
    List<String> features = const [],
    ConnectionTransport transport = ConnectionTransport.lan,
    String? transportEndpoint,
  }) {
    final session = PeerSession(
      peer: peer,
      socket: socket,
      codec: codec,
      initiatedByUs: initiatedByUs,
      features: features,
      transport: transport,
      transportEndpoint: transportEndpoint,
    );
    // The codec is ALREADY being pumped (started in _handleIncoming /
    // _handshake). Its onMessage currently points at the temp handshake
    // handler. onSessionReady MUST synchronously reassign it to the engine's
    // permanent handler — AppState._onSessionReady does this by calling
    // _engine.onPeerConnected(session), which sets session.onMessage.
    // Any message arriving between here and that reassignment still hits the
    // temp handler, which is harmless (post-hello messages during handshake
    // are unexpected and ignored). The first message AFTER the reassignment
    // hits the engine. There is no drop window.
    if (!onSessionReady(session)) {
      try {
        socket.destroy();
      } catch (_) {}
      return false;
    }
    _active[peer.deviceId] = session;
    sessionsController.add(session);
    socket.done.then((_) {
      if (identical(_active[peer.deviceId], session)) {
        _active.remove(peer.deviceId);
      }
    });
    return true;
  }

  // ---- Pairing code (incoming side) --------------------------------------

  String armPairingFor(DiscoveredPeer peer) {
    final code = _newPairingSecret();
    _pendingIncomingPairCode = _PendingPairCode(
      code: code,
      boundPubKey: peer.publicKeyB64,
      expiresAt: DateTime.now().add(_pairCodeTtl),
    );
    return code;
  }

  String armGenericPairing() {
    final code = _newPairingSecret();
    _pendingIncomingPairCode = _PendingPairCode(
      code: code,
      boundPubKey: null,
      expiresAt: DateTime.now().add(_pairCodeTtl),
    );
    return code;
  }

  String _newPairingSecret() {
    // Two pronounceable pseudo-words keep manual laptop pairing typeable
    // without reducing the secret to a readily guessed numeric PIN. Each
    // word contains five independently generated consonant-vowel syllables:
    // (16 * 6)^10 gives the complete phrase about 66 bits of entropy.
    const consonants = 'bcdfghjklmnprstv';
    const vowels = 'aeiouy';
    String word() {
      final out = StringBuffer();
      for (var i = 0; i < 5; i++) {
        out
          ..write(consonants[_rand.nextInt(consonants.length)])
          ..write(vowels[_rand.nextInt(vowels.length)]);
      }
      return out.toString();
    }

    return '${word()} ${word()}';
  }

  // ---- Client side (connect out) -----------------------------------------

  Future<PeerSession> connect({
    required DiscoveredPeer target,
    String? pairCode,
    Duration timeout = const Duration(seconds: 10),
    bool forceTakeover = false,
  }) {
    return connectMultiHost(
      deviceId: target.deviceId,
      name: target.name,
      platform: target.platform,
      publicKeyB64: target.publicKeyB64,
      hosts: [target.address],
      port: target.port,
      pairCode: pairCode,
      timeout: timeout,
      forceTakeover: forceTakeover,
    );
  }

  /// Connect through a native RFCOMM-to-loopback proxy.
  Future<PeerSession> connectBluetooth({
    required DiscoveredPeer target,
    required int localProxyPort,
    String? pairCode,
    Duration timeout = const Duration(seconds: 15),
    bool forceTakeover = false,
  }) async {
    final isPaired =
        config.pairedPeers.any((p) => p.deviceId == target.deviceId);
    if (!isPaired && pairCode == null) {
      throw StateError(
          'Not paired with ${target.deviceId}; pairCode required.');
    }
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      localProxyPort,
      timeout: timeout,
    );
    try {
      return await _handshake(
        socket: socket,
        deviceId: target.deviceId,
        isPaired: isPaired,
        pairCode: pairCode,
        timeout: timeout,
        forceTakeover: forceTakeover,
        transport: ConnectionTransport.bluetooth,
        transportEndpoint: target.transportEndpoint,
      );
    } catch (_) {
      await socket.close().catchError((_) {});
      rethrow;
    }
  }

  Future<PeerSession> connectMultiHost({
    required String deviceId,
    required String name,
    required String platform,
    required String publicKeyB64,
    required List<InternetAddress> hosts,
    required int port,
    String? pairCode,
    Duration timeout = const Duration(seconds: 10),
    bool forceTakeover = false,
  }) async {
    final isPaired = config.pairedPeers.any((p) => p.deviceId == deviceId);
    if (!isPaired && pairCode == null) {
      throw StateError('Not paired with $deviceId; pairCode required.');
    }
    if (hosts.isEmpty) {
      throw StateError('No candidate host for $deviceId.');
    }

    final perHost = const Duration(seconds: 3);

    Object? lastError;
    for (final host in hosts) {
      Socket socket;
      try {
        socket = await Socket.connect(host, port, timeout: perHost);
      } catch (e) {
        lastError = e;
        continue;
      }
      // Perf: Dart sockets do not enable TCP_NODELAY by default, so small
      // successive writes (e.g. the 4-byte length prefix + JSON payload in
      // secure_frame.dart) can sit briefly in the kernel's send buffer
      // waiting for Nagle's algorithm to coalesce them. That's invisible for
      // one-off control messages but adds real, avoidable latency to the
      // request/response round-trip block_transfer.dart and file_send.dart
      // depend on for every 1 MiB block — exactly the latency the ad-hoc
      // send performance fix (see fetchFileBlockLevel's pipelineDepth) is
      // designed around. Best-effort: some platforms/socket states can
      // reject the option, which must never fail a connection that would
      // otherwise work fine with Nagle's algorithm left on.
      try {
        socket.setOption(SocketOption.tcpNoDelay, true);
      } catch (_) {}
      try {
        return await _handshake(
          socket: socket,
          deviceId: deviceId,
          isPaired: isPaired,
          pairCode: pairCode,
          timeout: timeout,
          forceTakeover: forceTakeover,
          transport: ConnectionTransport.lan,
        );
      } catch (e) {
        lastError = e;
        try {
          await socket.close();
        } catch (_) {}
      }
    }
    throw lastError ??
        SocketException('Could not connect to any host for $deviceId');
  }

  /// Connect to an undiscovered peer using a user-entered LAN endpoint.
  /// The authenticated welcome supplies the peer identity that discovery or
  /// a QR token would normally provide.
  Future<PeerSession> connectManual({
    required List<InternetAddress> hosts,
    required int port,
    required String pairCode,
    Duration timeout = const Duration(seconds: 10),
  }) {
    return connectMultiHost(
      deviceId: '',
      name: 'Manual peer',
      platform: 'unknown',
      publicKeyB64: '',
      hosts: hosts,
      port: port,
      pairCode: pairCode,
      timeout: timeout,
    );
  }

  /// Run the hello → welcome handshake over an already-connected socket.
  ///
  /// Step 2 fix: set the codec's onMessage to a temp handler BEFORE listen(),
  /// send hello, await welcome via waitForMessage(codec, ...) (which uses
  /// Completer + onMessage reassignment, not a stream), then build the session
  /// and publish. There is no moment when a decoded message has no owner.
  Future<PeerSession> _handshake({
    required Socket socket,
    required String deviceId,
    required bool isPaired,
    String? pairCode,
    required Duration timeout,
    bool forceTakeover = false,
    ConnectionTransport transport = ConnectionTransport.lan,
    String? transportEndpoint,
  }) async {
    final codec = FrameCodec(socket);
    final secureOffer = await SecureHandshake.createOffer();

    final hello = <String, dynamic>{
      't': Msg.hello,
      'deviceId': identity.deviceId,
      'name': identity.name,
      'platform': identity.platform,
      'pubKey': identity.publicKeyB64,
      'features': [
        'device_status_v1',
        'phone_alert_v1',
        'transfer_receipt_v1',
      ],
      ...secureOffer.toJson(),
    };
    if (pairCode != null) {
      hello['pairingProof'] = _pairingProof(pairCode, hello);
    }
    if (forceTakeover && isPaired) hello['takeover'] = true;

    // Listen FIRST (so onDone/onError are wired), then set a temp onMessage
    // that just drops everything that isn't the welcome — waitForMessage
    // temporarily takes over onMessage for the duration of the await.
    codec.onError = (Object e) {
      // ignore: avoid_print
      print('[Conduit] client codec error: $e');
    };
    codec.listen();

    codec.send(hello);

    final welcome = await waitForMessage(codec, Msg.welcome, timeout: timeout);
    if (welcome['secureVersion'] != secureTransportVersion) {
      throw StateError(
        'This device uses an older insecure Conduit protocol. Update Conduit on both devices.',
      );
    }
    final transcript = SecureHandshake.transcript(
      initiator: hello,
      responder: welcome,
    );
    if (!SecureHandshake.verify(
      identity,
      transcript,
      welcome['signature'] as String,
      welcome['pubKey'] as String,
    )) {
      throw StateError('secure handshake signature mismatch');
    }
    final features = (welcome['features'] as List?)?.cast<String>().toList() ??
        const <String>[];
    final peer = PairedPeer(
      deviceId: welcome['deviceId'] as String,
      name: welcome['name'] as String,
      platform: welcome['platform'] as String,
      publicKeyB64: welcome['pubKey'] as String,
    );

    PairedPeer? expected;
    if (isPaired) {
      expected = config.pairedPeers.firstWhere(
        (candidate) => candidate.deviceId == deviceId,
      );
    } else {
      for (final candidate in config.pairedPeers) {
        if (candidate.deviceId == peer.deviceId) {
          expected = candidate;
          break;
        }
      }
    }
    if (expected != null) {
      if (peer.deviceId != expected.deviceId ||
          peer.publicKeyB64 != expected.publicKeyB64) {
        throw StateError('paired peer identity mismatch');
      }
    }

    codec.send({
      't': 'secure_finish',
      'signature': SecureHandshake.sign(identity, transcript),
    });
    final keys = await SecureHandshake.deriveKeys(
      local: secureOffer,
      remoteEphemeralKey: welcome['ephemeralKey'] as String,
      transcriptHash: transcript,
      initiator: true,
    );
    await waitForMessage(codec, 'secure_switch', timeout: timeout);
    codec.enableSecurity(keys);
    codec.send({'t': 'secure_confirm'});
    await waitForMessage(codec, 'secure_confirmed', timeout: timeout);

    if (expected == null) {
      await config.rememberPeer(peer);
    }

    final accepted = _publishSession(
      peer,
      socket,
      codec,
      initiatedByUs: true,
      features: features,
      transport: transport,
      transportEndpoint: transportEndpoint,
    );
    if (!accepted) {
      throw StateError('connection superseded by existing session');
    }
    final session = _active[peer.deviceId];
    if (session == null) {
      throw StateError('connection was not registered after handshake');
    }
    return session;
  }

  PeerSession? sessionFor(String deviceId) => _active[deviceId];
}

String _pairingProof(String secret, Map<String, dynamic> hello) {
  final input = utf8.encode(jsonEncode({
    'deviceId': hello['deviceId'],
    'pubKey': hello['pubKey'],
    'ephemeralKey': hello['ephemeralKey'],
    'secureNonce': hello['secureNonce'],
    'secureVersion': hello['secureVersion'],
  }));
  final normalizedSecret =
      secret.trim().toLowerCase().replaceAll(RegExp(r'[\s-]+'), ' ');
  return base64Encode(
      Hmac(sha256, utf8.encode(normalizedSecret)).convert(input).bytes);
}

bool _constantTimeEquals(String left, String right) {
  final a = utf8.encode(left);
  final b = utf8.encode(right);
  var difference = a.length ^ b.length;
  for (var i = 0; i < a.length || i < b.length; i++) {
    difference |= a[i % a.length] ^ b[i % b.length];
  }
  return difference == 0;
}
