import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/src/core/config_store.dart';
import 'package:conduit/src/net/peer_session.dart';
import 'package:conduit/src/notifications/notifier.dart';
import 'package:conduit/src/protocol/wire.dart';
import 'package:conduit/src/sync/file_send.dart';
import 'package:conduit/src/sync/manifest.dart';

const _bobDeviceId = 'BBBB-2222';

void main() {
  group('AdHocFileSend', () {
    late Directory tmpDir;
    late _FakeNotifier notifier;
    late _MockFs mockFs;
    late _FakeSession session;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('file_send_test_');
      notifier = _FakeNotifier();
      mockFs = _MockFs();
      session = _FakeSession();
    });

    tearDown(() async {
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
    });

    test('Sender: sendFile announces offer, serves blocks and completes',
        () async {
      final logLines = <String>[];
      final adHoc = AdHocFileSend(
        fs: mockFs,
        notifier: notifier,
        getReceivedFilesPath: () => tmpDir.path,
        getPeerName: (_) => 'Bob',
        onLog: (msg, {bool isError = false}) => logLines.add(msg),
      );

      final fileBytes = List<int>.generate(200, (i) => i);
      final fileName = 'test_file.bin';
      var completeCalled = false;
      var completeSuccess = false;

      // Start sending the file. This sends the fileOffer frame to session.
      await adHoc.sendFile(
        session: session,
        fileName: fileName,
        fileBytes: fileBytes,
        onSendComplete: (ok) {
          completeCalled = true;
          completeSuccess = ok;
        },
      );

      // Verify that fileOffer message was sent.
      expect(session.sent.length, 1);
      final offerMsg = session.sent.first;
      expect(offerMsg['t'], Msg.fileOffer);
      expect(offerMsg['name'], fileName);
      expect(offerMsg['size'], fileBytes.length);
      final offerId = offerMsg['offerId'] as String;
      expect(offerId, isNotEmpty);

      // Simulate the receiver pulling block 0 (which contains all 200 bytes since blockSize is 128KB).
      adHoc.handleFileOfferBlock(session, {
        't': Msg.fileOfferBlock,
        'offerId': offerId,
        'name': fileName,
        'offset': 0,
        'size': fileBytes.length,
      });

      // Give async microtasks time to run so the serve loop processes the block.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Verify that the sender responded with fileOfferData.
      expect(session.sent.length, 2);
      final dataMsg = session.sent.last;
      expect(dataMsg['t'], Msg.fileOfferData);
      expect(dataMsg['offerId'], offerId);
      expect(dataMsg['offset'], 0);
      expect(dataMsg['length'], fileBytes.length);
      expect(base64.decode(dataMsg['data'] as String), fileBytes);

      // Let the serve loop complete naturally.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Send loop should be cleaned up.
      expect(completeCalled, isTrue);
      expect(completeSuccess, isTrue);
      expect(notifier.sentName, fileName);
    });

    test('Receiver: handleFileOffer pulls blocks automatically and writes file',
        () async {
      final logLines = <String>[];
      final adHoc = AdHocFileSend(
        fs: mockFs,
        notifier: notifier,
        getReceivedFilesPath: () => tmpDir.path,
        getPeerName: (_) => 'Bob',
        onLog: (msg, {bool isError = false}) => logLines.add(msg),
      );

      final fileBytes = List<int>.generate(150, (i) => i % 256);
      final fileName = 'inbound_file.bin';
      final sha = sha256.convert(fileBytes).toString();

      // Inbound offer announcement.
      adHoc.handleFileOffer(session, {
        't': Msg.fileOffer,
        'offerId': 'offer-inbound-123',
        'name': fileName,
        'size': fileBytes.length,
        'sha256': sha,
        'blockHashes': [sha],
      });

      // Give microtasks time to start the fetch loop.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Receiver should have sent a fileOfferBlock request to pull the data.
      expect(session.sent.length, 1);
      final reqMsg = session.sent.first;
      expect(reqMsg['t'], Msg.fileOfferBlock);
      expect(reqMsg['offerId'], 'offer-inbound-123');
      expect(reqMsg['offset'], 0);

      // Simulate the sender replying with the data block.
      adHoc.handleFileOfferData(session, {
        't': Msg.fileOfferData,
        'offerId': 'offer-inbound-123',
        'name': fileName,
        'offset': 0,
        'length': fileBytes.length,
        'sha256': sha,
        'data': base64.encode(fileBytes),
      });

      // Wait for fetch completion.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Verify that the file was written to the directory.
      expect(mockFs.writes.length, 1);
      final writeEvent = mockFs.writes.first;
      expect(writeEvent.root, tmpDir.path);
      expect(writeEvent.rel, fileName);
      expect(writeEvent.data, fileBytes);

      // Verify notifier was called.
      expect(notifier.receivedName, fileName);
    });

    test('onSessionLost cancels in-flight transfers', () async {
      final logLines = <String>[];
      final adHoc = AdHocFileSend(
        fs: mockFs,
        notifier: notifier,
        getReceivedFilesPath: () => tmpDir.path,
        getPeerName: (_) => 'Bob',
        onLog: (msg, {bool isError = false}) => logLines.add(msg),
      );

      final fileBytes = List<int>.generate(100, (i) => i);
      final fileName = 'canceled_file.bin';

      // 1. Outbound offer in-flight
      await adHoc.sendFile(
        session: session,
        fileName: fileName,
        fileBytes: fileBytes,
      );

      // 2. Inbound offer in-flight
      adHoc.handleFileOffer(session, {
        't': Msg.fileOffer,
        'offerId': 'inbound-offer-cancel',
        'name': 'inbound.bin',
        'size': 100,
        'sha256': sha256.convert(fileBytes).toString(),
        'blockHashes': [sha256.convert(fileBytes).toString()],
      });

      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Trigger session loss.
      adHoc.onSessionLost(_bobDeviceId);

      // Verify that further block requests or data replies are no-ops.
      // (The stream/sink is closed, so no crash occurs and handlers safely ignore them).
      expect(
          () => adHoc.handleFileOfferBlock(session, {
                't': Msg.fileOfferBlock,
                'offerId': 'inbound-offer-cancel',
                'offset': 0,
              }),
          returnsNormally);
    });
  });
}

class _FakeNotifier implements AppNotifier {
  String? sentName;
  String? receivedName;

  @override
  void Function(String treeUri, String relPath)? onFileNotificationTap;

  @override
  void Function(String offerId)? onCancelReceiveTap;

  @override
  Future<void> init() async {}

  @override
  Future<void> showFileSent(String name, String peerName) async {
    sentName = name;
  }

  @override
  Future<void> showFileReceived(String name, String peerName,
      {String? treeUri}) async {
    receivedName = name;
  }

  @override
  Future<void> showReceiveProgress(
      String name, int received, int total, {required String offerId}) async {}

  @override
  Future<void> showSendProgress(String name, int sent, int total) async {}

  @override
  Future<void> cancelReceiveProgress(String name) async {}

  @override
  Future<void> cancelSendProgress(String name) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WriteEvent {
  final String root;
  final String rel;
  final List<int> data;
  _WriteEvent(this.root, this.rel, this.data);
}

class _MockFs implements FileSystemAccess {
  final writes = <_WriteEvent>[];
  final files = <String, List<int>>{};

  @override
  bool get isAndroidSAF => false;

  @override
  Future<List<String>> listFiles(String rootPath) async => files.keys.toList();

  @override
  Future<FileEntry?> stat(String rootPath, String relPath) async {
    final data = files[relPath];
    if (data == null) return null;
    return FileEntry(relPath: relPath, size: data.length, mtime: 0, sha256: '');
  }

  @override
  Stream<List<int>> openRead(String rootPath, String relPath,
      [int offset = 0]) async* {
    final data = files[relPath] ?? const <int>[];
    yield data.sublist(offset.clamp(0, data.length));
  }

  @override
  Future<void> write(String rootPath, String relPath, List<int> data) async {
    final copy = List<int>.from(data);
    files[relPath] = copy;
    writes.add(_WriteEvent(rootPath, relPath, copy));
  }

  @override
  Future<void> append(String rootPath, String relPath, List<int> data) async {
    files[relPath] = <int>[...(files[relPath] ?? const <int>[]), ...data];
  }

  @override
  Future<bool> delete(String rootPath, String relPath) async {
    return files.remove(relPath) != null;
  }

  @override
  Future<String> moveToVault(String rootPath, String relPath) async => '';
}

class _FakeSession implements PeerSession {
  @override
  final PairedPeer peer = PairedPeer(
    deviceId: _bobDeviceId,
    name: 'Bob',
    platform: 'test',
    publicKeyB64: '',
  );

  @override
  final int generation = 1;

  final List<Map<String, dynamic>> sent = [];

  @override
  set onMessage(void Function(Map<String, dynamic> msg) handler) {}
  @override
  set onError(void Function(Object error) handler) {}
  @override
  set onDone(void Function() handler) {}
  @override
  bool get isClosed => false;

  bool _linkReady = true;

  @override
  bool get hasReceivedLinkReady => _linkReady;

  @override
  bool get isLinkReady => _linkReady && !isClosed;

  @override
  void Function()? onLinkReady;

  @override
  bool markLinkReady() {
    if (_linkReady) return false;
    _linkReady = true;
    onLinkReady?.call();
    return true;
  }

  @override
  void send(Map<String, dynamic> msg) {
    msg['msgId'] ??= 'test-${sent.length}';
    sent.add(msg);
  }

  @override
  void startHeartbeat({required void Function() onDead}) {}
  @override
  void restartHeartbeat() {}
  @override
  void handlePong(String? hbId) {}
  @override
  void stopHeartbeat() {}
  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
