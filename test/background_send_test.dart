// Focused test for the Windows "Send to Conduit" background flow
// (lib/src/app_state.dart).
//
// A Windows Explorer "Send to" delivery must never open, focus, resize, or
// reveal the full Flutter window. Instead AppState decides:
//   * exactly one connected peer  -> auto-send the whole batch in the
//     background, reporting start/progress/complete to the native SendPopup
//     over the `conduit/shell` channel (windows/runner/send_popup.cpp);
//   * zero or multiple peers      -> keep the files pending in
//     [pendingSharedFiles] WITHOUT any popup and without picking a peer.
//
// These tests drive AppState's real share handler (via a @visibleForTesting
// seam) with a fake subclass that supplies a controlled connected-peer set
// and records engine sends. The `conduit/shell` channel is mocked so the
// popup calls are asserted instead of hitting the native runner.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/src/app_state.dart';
import 'package:conduit/src/core/config_store.dart';
import 'package:conduit/src/core/identity.dart';

import 'support/test_dependencies.dart';
import 'support/wait_until.dart';

const _shellChannel = MethodChannel('conduit/shell');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Windows background Send-to', () {
    late Directory supportDir;
    late _FakeAppState appState;
    late List<MethodCall> shellCalls;

    setUp(() async {
      supportDir =
          await Directory.systemTemp.createTemp('background_send_test_');
      final configFile =
          File('${supportDir.path}${Platform.pathSeparator}config.json');
      appState = _FakeAppState(
        ConfigStore.forTest(configFile, const <String, dynamic>{}),
        supportDir,
      );
      shellCalls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_shellChannel, (MethodCall call) async {
        shellCalls.add(call);
        return null;
      });
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_shellChannel, null);
      appState.dispose();
      try {
        await supportDir.delete(recursive: true);
      } catch (_) {}
    });

    Future<List<String>> writeFiles(List<String> names) async {
      final paths = <String>[];
      for (final name in names) {
        final f = File('${supportDir.path}${Platform.pathSeparator}$name');
        await f.writeAsString('hello $name');
        paths.add(f.path);
      }
      return paths;
    }

    test(
        'exactly one connected peer auto-sends a background batch with '
        'popup events and no pending queue', () async {
      final paths = await writeFiles(['a.txt', 'b.txt']);
      appState.connectedPeersOverride = [_peer('peer-1', 'Phone')];

      await appState.handleIncomingSharedFilesForTest(paths);

      // The batch runs fire-and-forget (the share-channel handler must not
      // block on a transfer), so wait for the engine calls to land.
      await waitUntil(
        () => appState.sendAdHocCalls.length == 2,
        description: 'background batch to reach the send engine',
      );

      // The whole batch went straight to the engine with the single peer.
      expect(appState.sendAdHocCalls.length, 2);
      expect(
        appState.sendAdHocCalls.every((c) => c.peerId == 'peer-1'),
        isTrue,
      );
      expect(appState.sendAdHocCalls.map((c) => c.fileName),
          orderedEquals(['a.txt', 'b.txt']));
      // Nothing was queued for the Send panel.
      expect(appState.pendingSharedFiles, isNull);
      // Popup lifecycle was reported through the shell channel.
      final show = shellCalls.firstWhere((c) => c.method == 'sendPopupShow');
      expect((show.arguments as Map)['peerName'], 'Phone');
      expect((show.arguments as Map)['batchTotal'], 2);
      expect(shellCalls.any((c) => c.method == 'sendPopupProgress'), isTrue);
      final complete =
          shellCalls.firstWhere((c) => c.method == 'sendPopupComplete');
      expect((complete.arguments as Map)['success'], true);
      // No window show/focus is possible anymore: the old send-widget mode
      // and SendWidgetScreen were removed.
      expect(shellCalls.where((c) => c.method == 'sendPopupHide'), isEmpty);
    });

    test('zero connected peers keeps files pending with no popup and no send',
        () async {
      final paths = await writeFiles(['only.txt']);

      await appState.handleIncomingSharedFilesForTest(paths);

      expect(appState.pendingSharedFiles, isNotNull);
      expect(appState.pendingSharedFiles!.length, 1);
      expect(appState.pendingSharedFilesAutoStart, isFalse);
      expect(appState.sendAdHocCalls, isEmpty);
      expect(
        shellCalls.where((c) => c.method.startsWith('sendPopup')),
        isEmpty,
      );
    });

    test('multiple connected peers keeps files pending without picking one',
        () async {
      final paths = await writeFiles(['only.txt']);
      appState.connectedPeersOverride = [
        _peer('peer-1', 'Laptop'),
        _peer('peer-2', 'Tablet'),
      ];

      await appState.handleIncomingSharedFilesForTest(paths);

      expect(appState.pendingSharedFiles, isNotNull);
      expect(appState.pendingSharedFilesAutoStart, isFalse);
      expect(appState.sendAdHocCalls, isEmpty);
      expect(
        shellCalls.where((c) => c.method.startsWith('sendPopup')),
        isEmpty,
      );
    });
  });
}

PairedPeer _peer(String deviceId, String name) => PairedPeer(
      deviceId: deviceId,
      name: name,
      platform: 'android',
      publicKeyB64: 'aGVsbG8=',
    );

/// Minimal AppState stub: supplies a controlled connected-peer set and
/// records engine sends. `start()` is never called — the real one needs live
/// sockets and platform channels.
class _FakeAppState extends AppState {
  _FakeAppState(this._config, Directory supportDir)
      : super(
          dependencies: testDependencies(
            identity: _identity,
            config: _config,
            supportDirectory: supportDir,
          ),
        );

  static final DeviceIdentity _identity = DeviceIdentity(
    deviceId: 'TEST-0001',
    name: 'Test device',
    platform: 'windows',
    privateKey: Uint8List.fromList(List<int>.filled(32, 1)),
    publicKey: Uint8List.fromList(List<int>.filled(32, 11)),
  );

  final ConfigStore _config;

  List<PairedPeer> connectedPeersOverride = const [];
  final List<({String peerId, String fileName})> sendAdHocCalls = [];

  @override
  ConfigStore get config => _config;

  @override
  List<PairedPeer> get pairedPeers => _config.pairedPeers;

  @override
  List<PairedPeer> get connectedPeers => connectedPeersOverride;

  @override
  Future<bool> sendAdHocFile({
    required String peerId,
    required String fileName,
    List<int>? fileBytes,
    String? safUri,
    String? filePath,
    int? fileSize,
    void Function(bool success)? onComplete,
    void Function(int sent, int total)? onProgress,
  }) async {
    sendAdHocCalls.add((peerId: peerId, fileName: fileName));
    final size = fileSize ?? 0;
    onProgress?.call(size, size);
    onComplete?.call(true);
    return true;
  }
}
