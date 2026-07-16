import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit/src/net/secure_frame.dart';
import 'package:conduit/src/net/secure_handshake.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('roles derive matching opposite-direction keys', () async {
    final initiator = await SecureHandshake.createOffer();
    final responder = await SecureHandshake.createOffer();
    final transcript = Uint8List.fromList(List<int>.generate(32, (i) => i));

    final a = await SecureHandshake.deriveKeys(
      local: initiator,
      remoteEphemeralKey: _b64(responder.publicKey.bytes),
      transcriptHash: transcript,
      initiator: true,
    );
    final b = await SecureHandshake.deriveKeys(
      local: responder,
      remoteEphemeralKey: _b64(initiator.publicKey.bytes),
      transcriptHash: transcript,
      initiator: false,
    );

    expect(await a.sendKey.extractBytes(), await b.receiveKey.extractBytes());
    expect(await a.receiveKey.extractBytes(), await b.sendKey.extractBytes());
    expect(
      await a.sendKey.extractBytes(),
      isNot(await a.receiveKey.extractBytes()),
    );
  });

  test('encrypted frames round-trip in FIFO order', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<Socket>();
    server.listen(accepted.complete);
    final clientSocket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    final serverSocket = await accepted.future;

    final a = FrameCodec(clientSocket);
    final b = FrameCodec(serverSocket);
    final keyA = SecretKey(List<int>.filled(32, 1));
    final keyB = SecretKey(List<int>.filled(32, 2));
    a.enableSecurity(SecureFrameKeys(
      sendKey: keyA,
      receiveKey: keyB,
      sendNoncePrefix: Uint8List.fromList([1, 2, 3, 4]),
      receiveNoncePrefix: Uint8List.fromList([5, 6, 7, 8]),
    ));
    b.enableSecurity(SecureFrameKeys(
      sendKey: keyB,
      receiveKey: keyA,
      sendNoncePrefix: Uint8List.fromList([5, 6, 7, 8]),
      receiveNoncePrefix: Uint8List.fromList([1, 2, 3, 4]),
    ));
    final received = <int>[];
    final done = Completer<void>();
    b.onMessage = (message) {
      received.add(message['n'] as int);
      if (received.length == 3) done.complete();
    };
    a.listen();
    b.listen();

    a.send({'t': 'test', 'n': 1});
    a.send({'t': 'test', 'n': 2});
    a.send({'t': 'test', 'n': 3});
    await done.future.timeout(const Duration(seconds: 5));

    expect(received, [1, 2, 3]);
    await a.close();
    await b.close();
    await server.close();
  });
}

String _b64(List<int> bytes) {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final output = StringBuffer();
  for (var i = 0; i < bytes.length; i += 3) {
    final a = bytes[i];
    final b = i + 1 < bytes.length ? bytes[i + 1] : 0;
    final c = i + 2 < bytes.length ? bytes[i + 2] : 0;
    final value = (a << 16) | (b << 8) | c;
    output
      ..write(alphabet[(value >> 18) & 63])
      ..write(alphabet[(value >> 12) & 63])
      ..write(i + 1 < bytes.length ? alphabet[(value >> 6) & 63] : '=')
      ..write(i + 2 < bytes.length ? alphabet[value & 63] : '=');
  }
  return output.toString();
}
