import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'config_store.dart';

/// Persistent device identity: an Ed25519 keypair + a short human-friendly
/// device ID derived from the public key fingerprint. Stored on disk so it
/// survives restarts and lets peers recognise us across networks.
class DeviceIdentity {
  final String deviceId; // short fingerprint, e.g. "F3A9-21BC"
  String name; // user-facing name, e.g. "Office PC"
  final String platform; // "windows" | "android"
  final Uint8List privateKey;
  final Uint8List publicKey;

  DeviceIdentity({
    required this.deviceId,
    required this.name,
    required this.platform,
    required this.privateKey,
    required this.publicKey,
  });

  String get publicKeyB64 => base64.encode(publicKey);
  String get publicKeyHex =>
      publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'name': name,
        'platform': platform,
        'privateKeyB64': base64.encode(privateKey),
        'publicKeyB64': base64.encode(publicKey),
      };

  factory DeviceIdentity.fromJson(Map<String, dynamic> j) {
    final deviceId = j['deviceId'];
    final name = j['name'];
    final platform = j['platform'];
    if (deviceId is! String ||
        deviceId.isEmpty ||
        name is! String ||
        name.isEmpty ||
        platform is! String ||
        platform.isEmpty) {
      throw const FormatException('Invalid identity metadata');
    }
    try {
      final privateKey =
          Uint8List.fromList(base64.decode(j['privateKeyB64'] as String));
      final publicKey =
          Uint8List.fromList(base64.decode(j['publicKeyB64'] as String));
      // ed25519_edwards stores a private key as the 32-byte seed followed by
      // the 32-byte public key. The generated key pair therefore persists a
      // 64-byte private key; accepting only 32 bytes makes every restart
      // quarantine the valid identity and generate a new device ID.
      if (privateKey.length != ed.PrivateKeySize ||
          publicKey.length != ed.PublicKeySize) {
        throw const FormatException('Invalid Ed25519 key length');
      }
      return DeviceIdentity(
        deviceId: deviceId,
        name: name,
        platform: platform,
        privateKey: privateKey,
        publicKey: publicKey,
      );
    } catch (error) {
      if (error is FormatException) rethrow;
      throw FormatException('Invalid identity key material: $error');
    }
  }

  static Future<File> _identityFile() async {
    final dir = await _appSupportDir();
    return File(p.join(dir.path, 'identity.json'));
  }

  static Future<Directory> _appSupportDir() => ConfigStore.appSupportDir();

  /// Load existing identity, or create + persist a fresh one.
  static Future<DeviceIdentity> loadOrCreate({
    required String platform,
    String? desiredName,
  }) async {
    final file = await _identityFile();
    if (await file.exists()) {
      try {
        final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        return DeviceIdentity.fromJson(j);
      } catch (_) {
        await ConfigStore.quarantineCorruptJson(file);
        // corrupt — regenerate
      }
    }
    final fresh = _generate(platform: platform, name: desiredName);
    await ConfigStore.writeJsonAtomically(file, fresh.toJson());
    return fresh;
  }

  static DeviceIdentity _generate({required String platform, String? name}) {
    final pair = ed.generateKey();
    final pubBytes = Uint8List.fromList(pair.publicKey.bytes);
    final privBytes = Uint8List.fromList(pair.privateKey.bytes);
    // Device ID = first 8 hex chars of SHA256(pubkey), grouped XXXX-XXXX.
    final digest = sha256.convert(pubBytes);
    final hex = digest.toString().substring(0, 8).toUpperCase();
    final id = '${hex.substring(0, 4)}-${hex.substring(4, 8)}';
    final defaultName =
        name ?? (platform == 'windows' ? 'Windows PC' : 'Android Phone');
    return DeviceIdentity(
      deviceId: id,
      name: defaultName,
      platform: platform,
      privateKey: privBytes,
      publicKey: pubBytes,
    );
  }

  /// Sign an arbitrary message — used to authenticate the pairing code flow.
  Uint8List sign(Uint8List data) =>
      Uint8List.fromList(ed.sign(ed.PrivateKey(privateKey), data));

  bool verify(Uint8List data, Uint8List signature, Uint8List peerPub) =>
      ed.verify(ed.PublicKey(peerPub), data, signature);

  Future<void> rename(String newName) async {
    if (newName.trim().isEmpty) {
      throw ArgumentError.value(newName, 'newName', 'must not be empty');
    }
    final previous = name;
    name = newName.trim();
    final file = await _identityFile();
    try {
      await ConfigStore.writeJsonAtomically(file, toJson());
    } catch (_) {
      name = previous;
      rethrow;
    }
  }

  static const uuid = Uuid();
}
