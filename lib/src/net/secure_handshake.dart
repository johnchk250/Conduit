import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as cryptography;

import '../core/identity.dart';
import 'secure_frame.dart';

const secureTransportVersion = 1;

class SecureHandshakeOffer {
  SecureHandshakeOffer({
    required this.keyPair,
    required this.publicKey,
    required this.nonce,
  });

  final cryptography.SimpleKeyPair keyPair;
  final cryptography.SimplePublicKey publicKey;
  final Uint8List nonce;

  Map<String, dynamic> toJson() => {
        'secureVersion': secureTransportVersion,
        'ephemeralKey': base64Encode(publicKey.bytes),
        'secureNonce': base64Encode(nonce),
      };
}

class SecureHandshake {
  static final _x25519 = cryptography.X25519();
  static final _hkdf = cryptography.Hkdf(
    hmac: cryptography.Hmac.sha256(),
    outputLength: 72,
  );

  static Future<SecureHandshakeOffer> createOffer() async {
    final pair = await _x25519.newKeyPair();
    return SecureHandshakeOffer(
      keyPair: pair,
      publicKey: await pair.extractPublicKey(),
      nonce: Uint8List.fromList(
        await (cryptography.SecretKeyData.random(length: 32)).extractBytes(),
      ),
    );
  }

  static Uint8List transcript({
    required Map<String, dynamic> initiator,
    required Map<String, dynamic> responder,
  }) {
    final canonical = jsonEncode({
      'protocol': 'conduit-secure-transport-v1',
      'initiator': _identityFields(initiator),
      'responder': _identityFields(responder),
    });
    return Uint8List.fromList(sha256.convert(utf8.encode(canonical)).bytes);
  }

  static Map<String, dynamic> _identityFields(Map<String, dynamic> value) => {
        'deviceId': value['deviceId'],
        'pubKey': value['pubKey'],
        'ephemeralKey': value['ephemeralKey'],
        'secureNonce': value['secureNonce'],
        'features': value['features'] ?? const <String>[],
        'secureVersion': value['secureVersion'],
      };

  static String sign(DeviceIdentity identity, Uint8List transcriptHash) =>
      base64Encode(identity.sign(transcriptHash));

  static bool verify(
    DeviceIdentity identity,
    Uint8List transcriptHash,
    String signature,
    String publicKey,
  ) {
    return identity.verify(
      transcriptHash,
      Uint8List.fromList(base64Decode(signature)),
      Uint8List.fromList(base64Decode(publicKey)),
    );
  }

  static Future<SecureFrameKeys> deriveKeys({
    required SecureHandshakeOffer local,
    required String remoteEphemeralKey,
    required Uint8List transcriptHash,
    required bool initiator,
  }) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: local.keyPair,
      remotePublicKey: cryptography.SimplePublicKey(
        base64Decode(remoteEphemeralKey),
        type: cryptography.KeyPairType.x25519,
      ),
    );
    final material = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: transcriptHash,
      info: utf8.encode('conduit-secure-transport-v1'),
    );
    final bytes = await material.extractBytes();
    final initiatorKey = cryptography.SecretKey(bytes.sublist(0, 32));
    final responderKey = cryptography.SecretKey(bytes.sublist(32, 64));
    final initiatorPrefix = Uint8List.fromList(bytes.sublist(64, 68));
    final responderPrefix = Uint8List.fromList(bytes.sublist(68, 72));
    return SecureFrameKeys(
      sendKey: initiator ? initiatorKey : responderKey,
      receiveKey: initiator ? responderKey : initiatorKey,
      sendNoncePrefix: initiator ? initiatorPrefix : responderPrefix,
      receiveNoncePrefix: initiator ? responderPrefix : initiatorPrefix,
    );
  }
}
