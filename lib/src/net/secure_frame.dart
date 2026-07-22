import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../diag.dart';

class SecureFrameKeys {
  const SecureFrameKeys({
    required this.sendKey,
    required this.receiveKey,
    required this.sendNoncePrefix,
    required this.receiveNoncePrefix,
  });

  final SecretKey sendKey;
  final SecretKey receiveKey;
  final Uint8List sendNoncePrefix;
  final Uint8List receiveNoncePrefix;
}

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
  SecureFrameKeys? _secureKeys;
  int _sendSequence = 0;
  int _receiveSequence = 0;
  Future<void> _sendChain = Future.value();
  Future<void> _receiveChain = Future.value();
  static final _aead = Chacha20.poly1305Aead();

  void enableSecurity(SecureFrameKeys keys) {
    if (_secureKeys != null) throw StateError('secure framing already enabled');
    if (keys.sendNoncePrefix.length != 4 ||
        keys.receiveNoncePrefix.length != 4) {
      throw ArgumentError('nonce prefixes must be four bytes');
    }
    _secureKeys = keys;
  }

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
  final _raw = _ByteQueue();

  void _onData(List<int> data) {
    _raw.add(data);
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
        final b = _raw.read(4);
        final len = (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
        final cap = _secureKeys == null ? 64 * 1024 : _maxEnvelopeBytes;
        if (len < 0 || len > cap) {
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
      final raw = _raw.read(len);
      _pendingLen = null;
      _receiveChain = _receiveChain.then((_) => _decodeFrame(raw)).catchError(
        (Object e) {
          _closed = true;
          onError?.call(e);
          _socket.destroy();
        },
      );
    }
  }

  Future<void> _decodeFrame(List<int> raw) async {
    final keys = _secureKeys;
    List<int> clear;
    if (keys == null) {
      clear = raw;
    } else {
      if (raw.length < 1 + 8 + 16 || raw.first != 1) {
        throw const FormatException('invalid secure record');
      }
      final header = Uint8List.fromList(raw.sublist(0, 9));
      final sequence = ByteData.sublistView(header).getUint64(1);
      if (sequence != _receiveSequence) {
        throw FormatException('unexpected secure sequence: $sequence');
      }
      final cipherText = raw.sublist(9, raw.length - 16);
      final mac = Mac(raw.sublist(raw.length - 16));
      clear = await _aead.decrypt(
        SecretBox(cipherText,
            nonce: _nonce(keys.receiveNoncePrefix, sequence), mac: mac),
        secretKey: keys.receiveKey,
        aad: _aad(keys.receiveNoncePrefix, sequence, cipherText.length),
      );
      _receiveSequence++;
    }
    final msg = _decodePayload(clear);
    Diag.recv(msg);
    onMessage?.call(msg);
  }

  Future<void> send(Map<String, dynamic> msg) {
    if (_closed) return Future.value();
    // Universal msgId stamping: every wire message gets a correlation id.
    // Any caller can pass its own (e.g. a request/response correlation); if
    // absent, we mint one here. This is the single chokepoint — there is no
    // other path to the socket — so the invariant "every message has a
    // msgId" holds structurally.
    msg['msgId'] ??= Diag.nextMsgId();
    Diag.send(msg);
    final keys = _secureKeys;
    if (keys == null) {
      _writeFrame(_encodePayload(msg));
      return _socket.flush();
    }
    final queued = Map<String, dynamic>.from(msg);
    _sendChain = _sendChain.then((_) async {
      if (_closed) return;
      if (_sendSequence == 0xFFFFFFFFFFFFFFFF) {
        throw StateError('secure sequence exhausted');
      }
      final sequence = _sendSequence;
      final payload = _encodePayload(queued);
      final box = await _aead.encrypt(
        payload,
        secretKey: keys.sendKey,
        nonce: _nonce(keys.sendNoncePrefix, sequence),
        aad: _aad(keys.sendNoncePrefix, sequence, payload.length),
      );
      final record = BytesBuilder(copy: false)
        ..addByte(1)
        ..add((ByteData(8)..setUint64(0, sequence)).buffer.asUint8List())
        ..add(box.cipherText)
        ..add(box.mac.bytes);
      _writeFrame(record.takeBytes());
      await _socket.flush();
      _sendSequence++;
    }).catchError((Object e) {
      _closed = true;
      onError?.call(e);
      _socket.destroy();
    });
    return _sendChain;
  }

  static Uint8List _encodePayload(Map<String, dynamic> msg) {
    final data = msg['data'];
    if (data is List<int>) {
      final metadata = Map<String, dynamic>.from(msg)..remove('data');
      final json = utf8.encode(jsonEncode(metadata));
      final header = ByteData(5)
        ..setUint8(0, 1)
        ..setUint32(1, json.length);
      return (BytesBuilder(copy: false)
            ..add(header.buffer.asUint8List())
            ..add(json)
            ..add(data))
          .takeBytes();
    }
    return Uint8List.fromList(utf8.encode(jsonEncode(msg)));
  }

  static Map<String, dynamic> _decodePayload(List<int> clear) {
    if (clear.isNotEmpty && clear.first == 1) {
      if (clear.length < 5) throw const FormatException('short binary frame');
      final bytes = clear is Uint8List ? clear : Uint8List.fromList(clear);
      final jsonLength = ByteData.sublistView(bytes, 1, 5).getUint32(0);
      final dataOffset = 5 + jsonLength;
      if (dataOffset > bytes.length) {
        throw const FormatException('invalid binary frame metadata length');
      }
      final msg = jsonDecode(utf8.decode(bytes.sublist(5, dataOffset)))
          as Map<String, dynamic>;
      msg['data'] = Uint8List.sublistView(bytes, dataOffset);
      return msg;
    }
    return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
  }

  void _writeFrame(List<int> payload) {
    final header = ByteData(4)..setUint32(0, payload.length);
    _socket.add(header.buffer.asUint8List());
    _socket.add(payload);
  }

  Future<void> flushPendingWrites() => _sendChain;

  static Uint8List _nonce(Uint8List prefix, int sequence) {
    final nonce = Uint8List(12)..setRange(0, 4, prefix);
    ByteData.sublistView(nonce).setUint64(4, sequence);
    return nonce;
  }

  static Uint8List _aad(Uint8List direction, int sequence, int length) {
    final data = ByteData(18)
      ..setUint8(0, 1)
      ..setUint8(1, 1)
      ..setUint64(6, sequence)
      ..setUint32(14, length);
    final bytes = data.buffer.asUint8List()..setRange(2, 6, direction);
    return bytes;
  }

  Future<void> close() async {
    _closed = true;
    try {
      await _sendChain;
    } catch (_) {}
    await _socket.close();
  }
}

class _ByteQueue {
  final ListQueue<Uint8List> _chunks = ListQueue<Uint8List>();
  int _headOffset = 0;
  int length = 0;

  void add(List<int> data) {
    if (data.isEmpty) return;
    _chunks.add(data is Uint8List ? data : Uint8List.fromList(data));
    length += data.length;
  }

  Uint8List read(int count) {
    if (count > length) throw RangeError.range(count, 0, length);
    final out = Uint8List(count);
    var written = 0;
    while (written < count) {
      final head = _chunks.first;
      final available = head.length - _headOffset;
      final take = available < count - written ? available : count - written;
      out.setRange(written, written + take, head, _headOffset);
      written += take;
      _headOffset += take;
      if (_headOffset == head.length) {
        _chunks.removeFirst();
        _headOffset = 0;
      }
    }
    length -= count;
    return out;
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
