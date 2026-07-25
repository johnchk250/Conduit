import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../protocol/wire.dart';

/// A peer device we've paired with. Stored locally so reconnection on a new
/// network requires no re-pairing.
class PairedPeer {
  final String deviceId;
  final String name;
  final String platform;
  final String publicKeyB64;

  PairedPeer({
    required this.deviceId,
    required this.name,
    required this.platform,
    required this.publicKeyB64,
  });

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'deviceId': deviceId,
      'name': name,
      'platform': platform,
      'publicKeyB64': publicKeyB64,
    };
  }

  factory PairedPeer.fromJson(Map<String, dynamic> j) {
    return PairedPeer(
      deviceId: j['deviceId'] as String,
      name: j['name'] as String,
      platform: j['platform'] as String,
      publicKeyB64: j['publicKeyB64'] as String,
    );
  }
}

/// Persistent JSON store for folder pairs and paired peers.
/// Lives next to identity.json in app support dir.
class ConfigStore {
  ConfigStore._(this._file, this._data);

  /// Test-only constructor: build a [ConfigStore] backed by [file] with a
  /// pre-populated [data] map, WITHOUT touching the real APPDATA path (which
  /// `load()` always writes to and would leak test state across runs). Production
  /// code uses [load]; tests use this so each test owns its config in a temp dir.
  @visibleForTesting
  factory ConfigStore.forTest(File file, Map<String, dynamic> data) =>
      ConfigStore._(file, Map<String, dynamic>.from(data));

  final File _file;
  final Map<String, dynamic> _data;

  static Future<ConfigStore> load() async {
    final dir = await _appSupportDir();
    final file = File(p.join(dir.path, 'config.json'));
    Map<String, dynamic> data;
    if (await file.exists()) {
      try {
        data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      } catch (_) {
        data = <String, dynamic>{};
      }
    } else {
      data = <String, dynamic>{};
    }
    // Drop the obsolete v1/v2 engine toggle from older configs.
    if (data.remove('useNewEngine') != null) {
      try {
        await file.writeAsString(jsonEncode(data));
      } catch (_) {
        // Best-effort cleanup; the flag is ignored either way.
      }
    }
    return ConfigStore._(file, data);
  }

  /// App-private support directory: `%APPDATA%\Conduit` on Windows, the
  /// path_provider app support dir on Android. Used by config, identity, AND
  /// sync metadata (Index DBs). Public so other components resolve the
  /// same directory without re-deriving it.
  ///
  /// ## Windows auto-migration (Polish)
  /// The app was previously named "FolderSync" and used `%APPDATA%\FolderSync`.
  /// On first run under the new name we check whether the old directory exists;
  /// if so, we copy its contents into the new directory so the user's identity,
  /// config, and paired-peer list are preserved without re-pairing. The old
  /// directory is left in place (not deleted) so a downgrade still works.
  static Future<Directory> appSupportDir() async {
    if (Platform.isWindows) {
      final appdata = Platform.environment['APPDATA']!;
      final newDir = Directory(p.join(appdata, 'Conduit'));
      if (!await newDir.exists()) {
        await newDir.create(recursive: true);
        // Auto-migrate from the old FolderSync directory if it exists.
        final oldDir = Directory(p.join(appdata, 'FolderSync'));
        if (await oldDir.exists()) {
          await _migrateDir(oldDir, newDir);
        }
      }
      return newDir;
    }
    return getApplicationSupportDirectory();
  }

  /// Copy every file from [src] into [dst] (one level — no subdirectory
  /// traversal needed; the app support dir only contains flat JSON/DB files).
  /// Best-effort: a file that can't be copied is skipped, not fatal.
  static Future<void> _migrateDir(Directory src, Directory dst) async {
    await for (final entity in src.list()) {
      if (entity is! File) continue;
      try {
        final target = File(p.join(dst.path, p.basename(entity.path)));
        if (!await target.exists()) {
          await entity.copy(target.path);
        }
      } catch (_) {
        // best-effort — a missing file is less bad than a crash
      }
    }
  }

  static Future<Directory> _appSupportDir() => appSupportDir();

  Future<void> _persist() async {
    await _file.writeAsString(jsonEncode(_data));
  }

  List<FolderPair> get folderPairs {
    final list = _data['folderPairs'];
    if (list is! List) {
      return const <FolderPair>[];
    }
    return list
        .map((e) => FolderPair.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<void> upsertPair(FolderPair pair) async {
    final pairs = <FolderPair>[...folderPairs];
    final idx = pairs.indexWhere((fp) => fp.id == pair.id);
    if (idx >= 0) {
      pairs[idx] = pair;
    } else {
      pairs.add(pair);
    }
    final json = pairs.map((fp) => fp.toJson()).toList();
    _data['folderPairs'] = json;
    await _persist();
  }

  Future<void> removePair(String id) async {
    final remaining = folderPairs
        .where((fp) => fp.id != id)
        .map((fp) => fp.toJson())
        .toList();
    _data['folderPairs'] = remaining;
    await _persist();
  }

  List<PairedPeer> get pairedPeers {
    final list = _data['pairedPeers'];
    if (list is! List) {
      return const <PairedPeer>[];
    }
    return list
        .map((e) => PairedPeer.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<void> rememberPeer(PairedPeer peer) async {
    final peers = <PairedPeer>[...pairedPeers];
    final idx = peers.indexWhere((pp) => pp.deviceId == peer.deviceId);
    if (idx >= 0) {
      peers[idx] = peer;
    } else {
      peers.add(peer);
    }
    _data['pairedPeers'] = peers.map((pp) => pp.toJson()).toList();
    await _persist();
  }

  Future<void> forgetPeer(String deviceId) async {
    final remaining = pairedPeers
        .where((pp) => pp.deviceId != deviceId)
        .map((pp) => pp.toJson())
        .toList();
    _data['pairedPeers'] = remaining;
    final rawEndpoints = _data['peerEndpoints'];
    if (rawEndpoints is Map) {
      final endpoints = Map<String, dynamic>.from(rawEndpoints);
      endpoints.remove(deviceId);
      _data['peerEndpoints'] = endpoints;
    }
    final rawBluetoothEndpoints = _data['peerBluetoothEndpoints'];
    if (rawBluetoothEndpoints is Map) {
      final endpoints = Map<String, dynamic>.from(rawBluetoothEndpoints);
      endpoints.remove(deviceId);
      _data['peerBluetoothEndpoints'] = endpoints;
    }
    await _persist();
  }

  /// Best known LAN endpoint for [deviceId].
  ///
  /// Older builds stored one map per peer. Current builds retain a small,
  /// ordered history so a laptop/phone can try the address it used at home,
  /// work, or a previous DHCP lease without re-pairing. Production callers
  /// persist routes only after the pinned secure handshake succeeds, so the
  /// first entry is the most recently authenticated route.
  Map<String, dynamic>? peerEndpoint(String deviceId) {
    final candidates = peerEndpointCandidates(deviceId);
    return candidates.isEmpty ? null : candidates.first;
  }

  /// Ordered LAN routes for [deviceId], newest/most successful first.
  ///
  /// The returned maps always contain `address` and integer `port`; timestamps
  /// are preserved when available for diagnostics and ordering. This method is
  /// intentionally backwards-compatible with the legacy single-map shape.
  List<Map<String, dynamic>> peerEndpointCandidates(String deviceId) {
    final rawEndpoints = _data['peerEndpoints'];
    if (rawEndpoints is! Map) return const <Map<String, dynamic>>[];
    final raw = rawEndpoints[deviceId];
    final items = raw is List
        ? raw
        : raw is Map
            ? <dynamic>[raw]
            : const <dynamic>[];
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final item in items) {
      if (item is! Map) continue;
      final address = item['address'];
      final port = item['port'];
      if (address is! String || address.isEmpty || port is! num) continue;
      final intPort = port.toInt();
      if (intPort <= 0 || intPort > 65535) continue;
      final key = '$address:$intPort';
      if (!seen.add(key)) continue;
      out.add(<String, dynamic>{
        'address': address,
        'port': intPort,
        if (item['updatedAt'] is String) 'updatedAt': item['updatedAt'],
        if (item['lastSuccessfulAt'] is String)
          'lastSuccessfulAt': item['lastSuccessfulAt'],
      });
    }
    return out;
  }

  /// Remember a LAN route without discarding previously working addresses.
  ///
  /// Call this only after the pinned secure handshake has completed. The route
  /// is promoted to the front and marked as a successful endpoint; public UDP
  /// discovery candidates stay in memory until authentication succeeds.
  Future<void> rememberPeerEndpoint({
    required String deviceId,
    required String address,
    required int port,
  }) async {
    if (address.isEmpty || port <= 0 || port > 65535) return;
    final now = DateTime.now().toIso8601String();
    final existingCandidates = peerEndpointCandidates(deviceId);
    final candidates = existingCandidates
        .where((entry) =>
            entry['address'] != address || (entry['port'] as int) != port)
        .map(Map<String, dynamic>.from)
        .toList();
    candidates.insert(0, <String, dynamic>{
      'address': address,
      'port': port,
      'updatedAt': now,
      'lastSuccessfulAt': now,
    });

    // A few recent routes cover DHCP churn and multiple regular networks while
    // keeping reconnect attempts bounded. Failed stale routes naturally age
    // out as newer authenticated routes are promoted.
    if (candidates.length > 8) {
      candidates.removeRange(8, candidates.length);
    }

    final rawEndpoints = _data['peerEndpoints'];
    final endpoints = rawEndpoints is Map
        ? Map<String, dynamic>.from(rawEndpoints)
        : <String, dynamic>{};
    endpoints[deviceId] = candidates;
    _data['peerEndpoints'] = endpoints;
    await _persist();
  }

  String? bluetoothEndpoint(String deviceId) {
    final raw = _data['peerBluetoothEndpoints'];
    if (raw is! Map) return null;
    final value = raw[deviceId];
    return value is String && value.isNotEmpty ? value : null;
  }

  String? peerIdForBluetoothEndpoint(String endpointId) {
    final raw = _data['peerBluetoothEndpoints'];
    if (raw is! Map) return null;
    for (final entry in raw.entries) {
      if (entry.value == endpointId) return entry.key.toString();
    }
    return null;
  }

  Future<void> rememberPeerBluetoothEndpoint({
    required String deviceId,
    required String endpointId,
  }) async {
    if (deviceId.isEmpty || endpointId.isEmpty) return;
    final raw = _data['peerBluetoothEndpoints'];
    final endpoints =
        raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    if (endpoints[deviceId] == endpointId) return;
    endpoints[deviceId] = endpointId;
    _data['peerBluetoothEndpoints'] = endpoints;
    await _persist();
  }

  bool get bluetoothEnabled => _data['bluetoothEnabled'] != false;

  Future<void> setBluetoothEnabled(bool value) async {
    _data['bluetoothEnabled'] = value;
    await _persist();
  }

  /// Feature flag for clipboard sync (Roadmap Phase 2). Off by default for
  /// privacy: the clipboard can contain passwords / 2FA codes, so the user must
  /// opt in. When true, the PC watches its clipboard and pushes to a connected
  /// phone automatically. Android receives those pushes in the background and
  /// can send its current clipboard manually from the Clipboard screen. When
  /// false, no `clipboardPush` is ever sent or acted on.
  bool get clipboardSyncEnabled => _data['clipboardSyncEnabled'] == true;

  Future<void> setClipboardSyncEnabled(bool value) async {
    _data['clipboardSyncEnabled'] = value;
    await _persist();
  }

  /// Path where ad-hoc received files are saved (Roadmap Phase 3a).
  ///
  /// On Android this is a SAF tree URI (same format as [FolderPair.localPath]).
  /// On Windows it is an absolute directory path. Null until the user has
  /// configured it (first send-to-this-device event prompts if unset) or until
  /// [setReceivedFilesPath] is called from Settings. Once set, it persists
  /// until the user changes it via Settings.
  String? get receivedFilesPath => _data['receivedFilesPath'] as String?;

  Future<void> setReceivedFilesPath(String path) async {
    _data['receivedFilesPath'] = path;
    await _persist();
  }

  /// Feature flag for remote command execution (Roadmap Phase 4). Off by
  /// default. Only meaningful on the PC side — when true, the PC acts on
  /// [Msg.runCommand] frames received from a connected phone. When false, all
  /// such frames are silently ignored regardless of source. The phone-side UI
  /// reflects the remote-side state (received via a ping handshake) so it can
  /// show a "Remote control disabled on PC" notice.
  bool get remoteControlEnabled => _data['remoteControlEnabled'] == true;

  Future<void> setRemoteControlEnabled(bool value) async {
    _data['remoteControlEnabled'] = value;
    await _persist();
  }

  /// Whether the persistent Android foreground-service notification is shown
  /// with a status-bar icon (true, default) or silently in the drawer only
  /// (false). Has no effect on non-Android platforms.
  bool get showPersistentNotification =>
      _data['showPersistentNotification'] != false; // default true

  Future<void> setShowPersistentNotification(bool value) async {
    _data['showPersistentNotification'] = value;
    await _persist();
  }

  /// Battery-saver mode. Android provider events still trigger after a short
  /// quiet window, but the single fallback folder traversal is reduced to once
  /// every 8 hours while connected and disabled while the peer is offline.
  /// Reconnecting
  /// performs an immediate catch-up reconcile. Default false.
  bool get batterySaverMode => _data['batterySaverMode'] == true;

  Future<void> setBatterySaverMode(bool value) async {
    _data['batterySaverMode'] = value;
    await _persist();
  }

  /// Whether the user allows the peer to locate/alert this phone (Roadmap Phase P2).
  /// Default true — alerts are enabled out-of-the-box; the user can disable
  /// them in Android Settings → "Allow phone alerts" if they don't want this.
  bool get allowPlayPhoneAlert => _data['allowPlayPhoneAlert'] != false;

  Future<void> setAllowPlayPhoneAlert(bool value) async {
    _data['allowPlayPhoneAlert'] = value;
    await _persist();
  }

  /// Versioned first-run state. A version allows later releases to introduce
  /// only newly required setup instead of replaying the complete wizard.
  int get onboardingVersion =>
      (_data['onboardingVersion'] as num?)?.toInt() ?? 0;

  Future<void> setOnboardingVersion(int value) async {
    _data['onboardingVersion'] = value;
    await _persist();
  }

  /// Stored device status snapshots for offline staleness reference.
  Map<String, dynamic> get deviceStatusSnapshots {
    final snapshots = _data['deviceStatusSnapshots'];
    if (snapshots is! Map) return <String, dynamic>{};
    return Map<String, dynamic>.from(snapshots);
  }

  Future<void> saveDeviceStatusSnapshot(
      String deviceId, Map<String, dynamic> snapshot) async {
    final snapshots = Map<String, dynamic>.from(deviceStatusSnapshots);
    snapshots[deviceId] = snapshot;
    _data['deviceStatusSnapshots'] = snapshots;
    await _persist();
  }

  Future<void> removeDeviceStatusSnapshot(String deviceId) async {
    final snapshots = Map<String, dynamic>.from(deviceStatusSnapshots);
    snapshots.remove(deviceId);
    _data['deviceStatusSnapshots'] = snapshots;
    await _persist();
  }
}
