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
  final String name; // user-facing name, e.g. "Office PC"
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

  factory DeviceIdentity.fromJson(Map<String, dynamic> j) => DeviceIdentity(
        deviceId: j['deviceId'] as String,
        name: j['name'] as String,
        platform: j['platform'] as String,
        privateKey:
            Uint8List.fromList(base64.decode(j['privateKeyB64'] as String)),
        publicKey:
            Uint8List.fromList(base64.decode(j['publicKeyB64'] as String)),
      );

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
        // corrupt — regenerate
      }
    }
    final fresh = _generate(platform: platform, name: desiredName);
    await file.writeAsString(jsonEncode(fresh.toJson()));
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
    final updated = DeviceIdentity(
      deviceId: deviceId,
      name: newName,
      platform: platform,
      privateKey: privateKey,
      publicKey: publicKey,
    );
    final file = await _identityFile();
    await file.writeAsString(jsonEncode(updated.toJson()));
  }

  static const uuid = Uuid();
}
