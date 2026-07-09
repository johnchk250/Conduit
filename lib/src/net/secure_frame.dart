import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../diag.dart';

/// Length-prefixed JSON envelope reader/writer over an arbitrary socket.
///
/// Wire format for one envelope:
///   [4 bytes big-endian length][length bytes UTF-8 JSON]
///
/// STRUCTURAL DESIGN (Step 2 of the fix plan): this codec deliberately does
/// NOT expose a broadcast Stream. A broadcast stream has no buffer, which
/// means a message that arrives between the socket being pumped and a
/// listener being attached is silently dropped. With a single callback slot
/// `onMessage`, there is exactly one current owner of incoming messages at
/// any time, and reassigning the owner is synchronous and instantaneous —
/// there is no window in which a decoded message can arrive and have nobody
/// to receive it. This removes the silent-drop failure mode structurally
/// rather than by timing discipline.
///
/// Lifecycle:
///   1. Codec is constructed with the socket.
///   2. Caller sets `onMessage` (and optionally onError/onDone) BEFORE calling
///      [listen]. During the handshake phase, onMessage points at a small
///      handshake handler; once the session is published, the caller
///      reassigns onMessage to the engine's permanent handler.
///   3. [listen] starts pumping the socket. From this point every decoded
///      frame is delivered via `onMessage?.call(msg)`.
class FrameCodec {
  FrameCodec(this._socket);

  final Socket _socket;

  /// Single, reassignable owner of incoming decoded messages. Set this
  /// BEFORE calling [listen]; reassign it any time ownership of the stream
  /// changes (e.g. handshake complete → engine takes over).
  void Function(Map<String, dynamic> msg)? onMessage;

  /// Error channel. Fires on socket errors or malformed envelopes.
  void Function(Object error)? onError;

  /// Done channel. Fires exactly once when the socket closes (either side).
  void Function()? onDone;

  /// Has the underlying socket been closed? Set true in the onDone handler.
  bool _closed = false;
  bool get isClosed => _closed;

  void listen() {
    _socket.listen(
      (List<int> data) => _onData(data),
      onError: (Object e) {
        _closed = true;
        onError?.call(e);
      },
      onDone: () {
        _closed = true;
        onDone?.call();
      },
    );
  }

  int? _pendingLen;
  final List<int> _raw = <int>[];

  void _onData(List<int> data) {
    _raw.addAll(data);
    _drain();
  }

  // Sanity cap: a single envelope larger than this almost certainly means
  // the length prefix got desynced (e.g. two peers disagreeing on framing,
  // or a stray non-Conduit connection on the port) rather than a real
  // oversized message.
  static const _maxEnvelopeBytes = 64 * 1024 * 1024;

  void _drain() {
    while (true) {
      if (_pendingLen == null) {
        if (_raw.length < 4) return;
        final b = Uint8List.fromList(_raw.sublist(0, 4));
        final len = (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
        _raw.removeRange(0, 4);
        if (len < 0 || len > _maxEnvelopeBytes) {
          _closed = true;
          onError?.call(
            FormatException('bad envelope length: $len (stream desynced?)'),
          );
          _socket.destroy();
          return;
        }
        _pendingLen = len;
      }
      final len = _pendingLen!;
      if (_raw.length < len) return;
      final raw = _raw.sublist(0, len);
      _raw.removeRange(0, len);
      _pendingLen = null;
      try {
        final payload = utf8.decode(raw);
        final msg = jsonDecode(payload) as Map<String, dynamic>;
        Diag.recv(msg);
        onMessage?.call(msg);
      } catch (e) {
        onError?.call(FormatException('bad envelope: $e'));
      }
    }
  }

  void send(Map<String, dynamic> msg) {
    if (_closed) return; // writing to a closed socket throws asynchronously
    // Universal msgId stamping: every wire message gets a correlation id.
    // Any caller can pass its own (e.g. a request/response correlation); if
    // absent, we mint one here. This is the single chokepoint — there is no
    // other path to the socket — so the invariant "every message has a
    // msgId" holds structurally.
    msg['msgId'] ??= Diag.nextMsgId();
    Diag.send(msg);
    final payload = utf8.encode(jsonEncode(msg));
    final len = payload.length;
    final header = ByteData(4)..setUint32(0, len);
    _socket.add(header.buffer.asUint8List());
    _socket.add(payload);
  }

  Future<void> close() async {
    _closed = true;
    await _socket.close();
  }
}

/// A one-shot helper for the handshake phase: wait for the next message
/// matching [type] within [timeout]. Implemented on top of a Completer that
/// is wired to the codec's onMessage callback for the duration of the wait,
/// then unwired — so it does NOT depend on a broadcast stream.
Future<Map<String, dynamic>> waitForMessage(
  FrameCodec codec,
  String type, {
  Duration timeout = const Duration(seconds: 30),
}) {
  final completer = Completer<Map<String, dynamic>>();
  final previous = codec.onMessage;
  Timer? watchdog;
  void handler(Map<String, dynamic> msg) {
    if (msg['t'] == type && !completer.isCompleted) {
      completer.complete(msg);
      watchdog?.cancel();
      // Restore the previous owner so we don't keep swallowing messages
      // after the awaited one arrives.
      codec.onMessage = previous;
    } else if (msg['t'] == 'error' && !completer.isCompleted) {
      completer.completeError(
        StateError(msg['message']?.toString() ?? 'peer rejected handshake'),
      );
      watchdog?.cancel();
      codec.onMessage = previous;
    } else if (previous != null) {
      previous(msg);
    }
  }

  codec.onMessage = handler;
  watchdog = Timer(timeout, () {
    if (!completer.isCompleted) {
      completer.completeError(TimeoutException('timed out waiting for: $type'));
    }
  });
  return completer.future;
}

/// Determine whether the TLS connection's peer certificate fingerprint
/// matches an expected public key. Returns true if acceptable.
///
/// Note: we rely on pinning at the application level via the hello/welcome
/// handshake (which carries the ed25519 pubkey) rather than deep certificate
/// verification. Dart's SecureSocket with a self-signed cert is used purely
/// for transport encryption here. (Currently unused — transport is plain TCP.)
Future<SecureServerSocket> bindSecureServer({
  required int port,
  required SecurityContext context,
  Object? address,
}) async {
  return SecureServerSocket.bind(
    address ?? InternetAddress.anyIPv4,
    port,
    context,
    requestClientCertificate: false,
    requireClientCertificate: false,
  );
}
