import 'dart:convert';
import 'dart:math';

/// Machine-readable, always-on diagnostic stream for Conduit.
///
/// Emits one line per event to stdout (visible in the `flutter run` console,
/// and in platform logcat / debug output on a device):
///
///   [Conduit][diag] 2026-06-22T14:03:21.123456 {"event":"recv","msgId":"a3f01c-1","t":"ping"}
///
/// This is a SEPARATE channel from the engine's [SyncEvent] log, which feeds
/// the in-app Activity panel and is human-readable prose. [Diag] is the
/// parallel machine-readable stream used to trace message flow end-to-end
/// across two devices.
///
/// Every wire message carries a `msgId` (stamped in [FrameCodec.send] via
/// [nextMsgId]), so a send on device A and the matching recv on device B can
/// be correlated by grep. Ids are boot-prefixed so two app runs never collide.
///
/// Always on (the project decision was: diagnostic prints are cheap and make
/// any failure immediately localizable). To quiet it, filter the console —
/// the prefix `[Conduit][diag]` is stable.
class Diag {
  Diag._();

  // ---- msgId generation ------------------------------------------------

  /// Process-global boot prefix — random per app launch, so ids from this
  /// run never collide with another run's.
  static final String _boot = _randomBootHex();
  static int _seq = 0;
  static int _bulkFrames = 0;
  static int _heartbeatFrames = 0;
  static int _heartbeatEvents = 0;

  /// Next monotonic message id, e.g. `a3f01c-1`. Shared across all sessions
  /// so correlation-by-grep works regardless of which session sent it.
  static String nextMsgId() {
    _seq += 1;
    return '$_boot-${_seq.toRadixString(16)}';
  }

  static String _randomBootHex() {
    final r = Random();
    final buf = <int>[];
    for (var i = 0; i < 3; i++) {
      buf.add(r.nextInt(256));
    }
    return buf.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // ---- typed wrappers --------------------------------------------------

  /// Log an outgoing message. Call AFTER stamping `msg['msgId']`.
  static void send(Map<String, dynamic> msg, {String? peer, int? session}) {
    if (_skipBulkFrame(msg)) return;
    log('send',
        peer: peer,
        session: session,
        msgId: _str(msg['msgId']),
        msgType: _str(msg['t']));
  }

  /// Log an incoming message.
  static void recv(Map<String, dynamic> msg, {String? peer, int? session}) {
    if (_skipBulkFrame(msg)) return;
    log('recv',
        peer: peer,
        session: session,
        msgId: _str(msg['msgId']),
        msgType: _str(msg['t']));
  }

  /// Heartbeat lifecycle events: `hb_send`, `hb_dead`, `hb_pong`.
  static void heartbeat(
    String event, {
    String? peer,
    int? session,
    String? hbId,
    int? rttMs,
    int? missed,
  }) {
    if (event != 'hb_dead') {
      _heartbeatEvents++;
      if (_heartbeatEvents % 50 != 1) return;
    }
    log(event, peer: peer, session: session, fields: {
      if (hbId != null) 'hbId': hbId,
      if (rttMs != null) 'rttMs': rttMs,
      if (missed != null) 'missed': missed,
    });
  }

  /// Session lifecycle events: `session_ready`, `session_drop`, `gen_mismatch`, etc.
  static void session(
    String event, {
    String? peer,
    int? session,
    Map<String, dynamic>? fields,
  }) {
    log(event, peer: peer, session: session, fields: fields);
  }

  // ---- core emit -------------------------------------------------------

  /// Core emit. One structured line.
  static void log(
    String event, {
    String? peer,
    int? session,
    String? msgId,
    String? msgType,
    String? pairId,
    Map<String, dynamic>? fields,
  }) {
    final ts = DateTime.now().toIso8601String();
    final body = <String, dynamic>{
      'event': event,
      if (peer != null) 'peer': peer,
      if (session != null) 'session': session,
      if (msgId != null) 'msgId': msgId,
      if (msgType != null) 't': msgType,
      if (pairId != null) 'pairId': pairId,
      if (fields != null) ...fields,
    };
    // ignore: avoid_print
    print('[Conduit][diag] $ts ${jsonEncode(body)}');
  }

  static String? _str(Object? v) => v?.toString();

  static bool _skipBulkFrame(Map<String, dynamic> msg) {
    final type = _str(msg['t']);
    if (type == 'ping' || type == 'pong') {
      _heartbeatFrames++;
      return _heartbeatFrames % 50 != 1;
    }
    if (type != 'response' && type != 'fileOfferData') return false;
    _bulkFrames++;
    return _bulkFrames % 64 != 1;
  }
}
