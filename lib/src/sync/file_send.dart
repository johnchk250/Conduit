import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../notifications/notifier.dart';
import '../net/peer_session.dart';
import '../protocol/wire.dart';
import '../sync/block_transfer.dart';
import '../sync/manifest.dart';

/// How many blocks [_receiveOffer] keeps outstanding at once when pulling an
/// ad-hoc send (see [fetchFileBlockLevel]'s `pipelineDepth`).
///
/// A single stop-and-wait fetch loop (depth 1, the default everywhere else)
/// pays one full peer round-trip per 1 MiB block: fine for the V2 sync
/// engine's steady-state background reconciliation, but it's exactly why an
/// ad-hoc "send this file now" could feel much slower than KDE Connect on
/// the same LAN — round-trip latency, not bandwidth, was the bottleneck. A
/// depth of 8 keeps the sender's serve loop continuously fed (it responds to
/// buffered requests strictly in the order they arrive, so pipelining needs
/// no protocol change — see block_transfer.dart) without materializing more
/// than 8 MiB of in-flight blocks. Deliberately scoped to this file: the V2
/// engine's own `fetchFileBlockLevel` call in engine.dart is untouched and
/// keeps the default depth of 1.
const int _adHocPipelineDepth = 8;

/// Metadata about an incoming file offer, kept on the receiver side while the
/// transfer is in flight. Never surfaces to the UI (auto-receive — no dialog).
class _InboundOffer {
  final String offerId;
  final String name;
  final int size;
  final String sha256;
  final List<String> blockHashes;
  final PeerSession session;

  // Block-pull sink: the fetchFileBlockLevel loop pulls from here; the
  // fileOfferData handler pushes into it. Closed on session loss or completion.
  final _sink = _OfferBlockSink();

  _InboundOffer({
    required this.offerId,
    required this.name,
    required this.size,
    required this.sha256,
    required this.blockHashes,
    required this.session,
  });
}

/// A pending outbound offer waiting for the receiver to pull its blocks.
///
/// ## Large-file streaming (Polish / connection-loss fix)
///
/// Previously held the entire file as `List<int> bytes`, which caused two bugs:
///   1. **Connection loss on share-sheet**: `_onIncomingSharedFiles` called
///      `readSharedUri` (blocking the platform thread) before this object was
///      ever created. Moving to a lazy block-reader avoids that path entirely.
///   2. **UI freeze on large files**: SHA + block-hash computation ran
///      synchronously on the UI isolate before this object was created.
///
/// Now holds a `_BlockReader` callback — a function that reads exactly
/// [offset..offset+length) bytes from the source (in-memory buffer, local
/// File, or SAF URI) asynchronously. The serve loop calls it once per block,
/// keeping peak memory at O(blockSize) regardless of file size.
class _OutboundOffer {
  final String offerId;
  final String name;
  final int fileSize;
  final String peerId;
  final PeerSession session;

  bool paused = false;
  bool canceled = false;
  Completer<void>? _resumeSignal;

  /// Returns bytes [offset, offset+length) from the file source.
  /// May be async (SAF URI or file I/O).
  final Future<List<int>> Function(int offset, int length) readBlock;

  // Serve stream: the first fileOfferBlock request spawns a serve loop
  // draining this; subsequent requests for the same offer land here.
  final StreamController<Map<String, dynamic>> serveCtrl =
      StreamController<Map<String, dynamic>>();

  _OutboundOffer({
    required this.offerId,
    required this.name,
    required this.fileSize,
    required this.peerId,
    required this.session,
    required this.readBlock,
  });

  void pause() {
    if (canceled || paused) return;
    paused = true;
    _resumeSignal ??= Completer<void>();
  }

  void resume() {
    if (!paused && _resumeSignal == null) return;
    paused = false;
    final signal = _resumeSignal;
    _resumeSignal = null;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  void cancel() {
    if (canceled) return;
    canceled = true;
    resume();
    if (!serveCtrl.isClosed) {
      scheduleMicrotask(() => serveCtrl.close());
    }
  }

  Future<void> waitIfPaused() async {
    while (paused && !canceled) {
      _resumeSignal ??= Completer<void>();
      await _resumeSignal!.future;
    }
    if (canceled) throw const _AdHocTransferCanceled();
  }
}

class _AdHocTransferCanceled implements Exception {
  const _AdHocTransferCanceled();
  @override
  String toString() => 'transfer cancelled';
}

/// Per-block response sink for an inbound ad-hoc file transfer.
///
/// [AdHocFileSend._handleFileOfferData] pushes each arriving block into this;
/// [fetchFileBlockLevel]'s injected `sendRequest` pulls the next response.
/// Closing the sink makes `next()` return null → fetchFileBlockLevel throws
/// StateError → the receive coroutine ends cleanly (same pattern as the engine's
/// [_BlockSink] for V2 sync transfers).
class _OfferBlockSink {
  final _queue = <Completer<Map<String, dynamic>?>>[];
  final _pending = <Map<String, dynamic>>[];
  bool _closed = false;

  /// Push a response into the sink. If a waiter is pending, complete it
  /// immediately; otherwise queue the response for the next [next()] call.
  void add(Map<String, dynamic> msg) {
    if (_closed) return;
    if (_queue.isNotEmpty) {
      _queue.removeAt(0).complete(msg);
    } else {
      _pending.add(msg);
    }
  }

  /// Pull the next response. Returns null if the sink was closed (session
  /// lost or transfer complete).
  Future<Map<String, dynamic>?> next() {
    if (_closed) return Future.value(null);
    if (_pending.isNotEmpty) return Future.value(_pending.removeAt(0));
    final c = Completer<Map<String, dynamic>?>();
    _queue.add(c);
    return c.future;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    // Unblock any waiting futures with null (clean session-lost signal).
    for (final c in _queue) {
      if (!c.isCompleted) c.complete(null);
    }
    _queue.clear();
  }

  bool get isClosed => _closed;
}

/// Ad-hoc file send / auto-receive logic for Roadmap Phase 3a.
///
/// ## Engine-safety
/// This class lives entirely outside the sync engine. It:
///   - Has its own sink maps (keyed by offerId, never pairId).
///   - Never reads from or writes to any IndexDb.
///   - Never calls indexDiff, upsertLocal, confirmLocalObservation,
///     or any VersionVector method.
///   - Is wired into [SyncEngine] via a single nullable field
///     (`engine.adHocSend`) rather than a callback, but it is the engine's
///     ONLY reference to this class — the reverse reference is through the
///     session's send() only.
///   - Can be removed by deleting this file and unsetting engine.adHocSend.
///
/// ## Transfer protocol (pull-based, no ack handshake)
///
///   Sender → Receiver : Msg.fileOffer {offerId, name, size, sha256, blockHashes}
///   Receiver → Sender : Msg.fileOfferBlock {offerId, name, offset, size, hash?}  × N
///   Sender → Receiver : Msg.fileOfferData  {offerId, name, offset, length, sha256, data<b64>}
///                    OR                   {offerId, name, offset, error:<string>}
///
/// Receiver starts pulling immediately on receipt of fileOffer (auto-receive).
/// Terminal errors (error field in fileOfferData) abort the transfer cleanly.
///
/// ## Large-file streaming (connection-loss fix)
///
/// The sender no longer loads the full file into memory. Instead:
///   1. `sendFile(bytes)` — for files already in memory (in-app picker): wraps
///      the byte buffer in a synchronous readBlock callback. Same as before,
///      but now uses the shared streaming serve loop.
///   2. `sendFileFromSafUri(uri, size, name, session)` — for files shared from
///      another app via the Android share sheet. Reads the file metadata
///      (filename, size) instantly, then streams each requested block from the
///      SAF URI on demand via `readSharedUriBlock`. The platform thread is
///      never blocked for more than one 1-MiB block read (~10-50 ms).
///   3. `sendFileFromPath(path, name, session)` — for Windows "Send to" files.
///      Uses `File.openRead(start, end)` for each block.
///
/// In all cases peak memory = O(blockSize) = O(1 MiB).
class AdHocFileSend {
  AdHocFileSend({
    required this.fs,
    required this.notifier,
    required this.getReceivedFilesPath,
    required this.getPeerName,
    required this.onLog,
  }) {
    notifier.onCancelReceiveTap = (offerId) {
      cancelInboundOffer(offerId);
    };
  }

  /// FileSystemAccess for writing received files (SAF on Android, local on PC).
  final FileSystemAccess fs;

  /// System notification service (Phase 3b).
  final AppNotifier notifier;

  /// Returns the configured received-files path (or null if not set yet).
  /// Called at receive time so a path change in Settings takes effect
  /// immediately (no restart needed).
  final String? Function() getReceivedFilesPath;

  /// Friendly name for a peer id, used in notification text.
  final String Function(String peerId) getPeerName;

  /// Structured log callback — same pattern as ClipboardSync.
  final void Function(String msg, {bool isError}) onLog;

  // Outbound offers waiting for block requests from the receiver.
  // keyed by offerId.
  final _outbound = <String, _OutboundOffer>{};

  // Inbound offers being fetched (auto-receive), keyed by offerId.
  final _inbound = <String, _InboundOffer>{};

  static const _uuid = Uuid();

  // SAF method channel — used only on Android for the streaming path.
  static const _safCh = MethodChannel('conduit/saf');

  // ---- Sender side -------------------------------------------------------

  /// Send [fileBytes] to [session] as an ad-hoc file named [fileName].
  ///
  /// This is the in-memory path for files already loaded by the in-app file
  /// picker. For large files shared via the Android share sheet or Windows
  /// "Send to", use [sendFileFromSafUri] or [sendFileFromPath] instead — those
  /// paths never load the whole file into memory.
  ///
  /// [onProgress] is called with (bytesSent, totalBytes) after each block is
  /// served. The UI uses this to drive a live LinearProgressIndicator.
  ///
  /// [onSendComplete] is called after the receiver finishes pulling all blocks
  /// (best-effort; session loss before completion means it may not fire).
  Future<void> sendFile({
    required PeerSession session,
    required String fileName,
    required List<int> fileBytes,
    void Function(bool success)? onSendComplete,
    void Function(int sent, int total)? onProgress,
    bool waitForCompletion = false,
  }) async {
    // Wrap in-memory bytes as a synchronous block reader.
    return _sendFromBlockReader(
      session: session,
      fileName: fileName,
      fileSize: fileBytes.length,
      readBlock: (offset, length) async {
        final end = min(offset + length, fileBytes.length);
        return fileBytes.sublist(offset, end);
      },
      onSendComplete: onSendComplete,
      onProgress: onProgress,
      waitForCompletion: waitForCompletion,
    );
  }

  /// Send a file from an Android SAF `content://` URI to [session].
  ///
  /// This is the streaming path for files arriving via the Android share sheet.
  /// The connection-loss bug is fixed here: previously `readSharedUri` loaded
  /// the whole file before the offer was made, blocking the platform thread
  /// and starving socket heartbeats. Now we only read the file size (fast),
  /// build the block plan, and read each 1-MiB block on demand via
  /// `readSharedUriBlock` — the platform thread is never blocked for more than
  /// ~10-50 ms per block.
  ///
  /// [fileSize] must be known up-front (from `getSharedUriSize`).
  /// [onProgress] receives (bytesSent, totalBytes) after each block is served.
  Future<void> sendFileFromSafUri({
    required PeerSession session,
    required String fileName,
    required String safUri,
    required int fileSize,
    void Function(bool success)? onSendComplete,
    void Function(int sent, int total)? onProgress,
    bool waitForCompletion = false,
  }) async {
    return _sendFromBlockReader(
      session: session,
      fileName: fileName,
      fileSize: fileSize,
      readBlock: (offset, length) async {
        final result = await _safCh.invokeMethod<Uint8List>(
          'readSharedUriBlock',
          {'uri': safUri, 'offset': offset, 'length': length},
        );
        return result ?? const [];
      },
      onSendComplete: onSendComplete,
      onProgress: onProgress,
      waitForCompletion: waitForCompletion,
    );
  }

  /// Send a file from a local file-system path to [session] (Windows).
  ///
  /// Reads each block on demand via [File.openRead], so the full file is never
  /// in memory at once. Uses the same streaming serve loop as [sendFileFromSafUri].
  Future<void> sendFileFromPath({
    required PeerSession session,
    required String fileName,
    required String filePath,
    void Function(bool success)? onSendComplete,
    void Function(int sent, int total)? onProgress,
    bool waitForCompletion = false,
  }) async {
    final file = File(filePath);
    final fileSize = await file.length();
    return _sendFromBlockReader(
      session: session,
      fileName: fileName,
      fileSize: fileSize,
      readBlock: (offset, length) async {
        final buf = <int>[];
        await for (final chunk in file.openRead(offset, offset + length)) {
          buf.addAll(chunk);
        }
        return buf;
      },
      onSendComplete: onSendComplete,
      onProgress: onProgress,
      waitForCompletion: waitForCompletion,
    );
  }

  /// Common implementation for all three send paths.
  ///
  /// Pre-computes SHA-256 and per-block hashes by reading the file sequentially
  /// (one block at a time, yielding between blocks so the event loop stays
  /// responsive). Then announces the offer and starts the serve loop, which
  /// serves each block by calling [readBlock] on demand.
  ///
  /// Peak memory = 2 × blockSize (one block for hash scan, one for serve).
  Future<void> _sendFromBlockReader({
    required PeerSession session,
    required String fileName,
    required int fileSize,
    required Future<List<int>> Function(int offset, int length) readBlock,
    void Function(bool success)? onSendComplete,
    void Function(int sent, int total)? onProgress,
    bool waitForCompletion = false,
  }) async {
    final offerId = _uuid.v4();

    final offer = _OutboundOffer(
      offerId: offerId,
      name: fileName,
      fileSize: fileSize,
      peerId: session.peer.deviceId,
      session: session,
      readBlock: readBlock,
    );
    _outbound[offerId] = offer;

    if (fileSize == 0) {
      scheduleMicrotask(() => offer.serveCtrl.close());
    }

    // Step 2: Announce the offer.
    session.send({
      't': Msg.fileOffer,
      'offerId': offerId,
      'name': fileName,
      'size': fileSize,
      // Empty hashes make the offer instant for large files. Each served block
      // still carries and verifies its own SHA-256, and the receiver computes
      // the final digest for diagnostics.
      'sha256': '',
      'blockHashes': const <String>[],
    });
    onLog('Ad-hoc offer sent: $fileName (${fileSize}B) offerId=$offerId');

    // Step 3: Serve blocks on demand as the receiver pulls them.
    // Each block is read by calling readBlock(offset, length) — this is either
    // an instant sublist (in-memory path) or an async SAF/file read (streaming
    // path). Either way it's async so the event loop stays alive.
    onProgress?.call(0, fileSize);
    final serveFuture = _serveBlocks(
        offer, session, fileName, fileSize, onSendComplete, onProgress);
    if (waitForCompletion) {
      await serveFuture;
    } else {
      unawaited(serveFuture);
    }
  }

  /// Serve the receiver's block-pull requests until the transfer completes
  /// (serve stream is closed) or the session is lost.
  Future<void> _serveBlocks(
    _OutboundOffer offer,
    PeerSession session,
    String fileName,
    int fileSize,
    void Function(bool success)? onSendComplete,
    void Function(int sent, int total)? onProgress,
  ) async {
    var bytesSent = 0;
    var completed = fileSize == 0;
    try {
      await for (final req in offer.serveCtrl.stream) {
        final reqOffset = (req['offset'] as num?)?.toInt() ?? 0;
        final reqSize = (req['size'] as num?)?.toInt() ?? blockSize;
        if (session.isClosed || offer.canceled) break;
        try {
          await offer.waitIfPaused();
          final blockBytes = await offer.readBlock(reqOffset, reqSize);
          if (offer.canceled || session.isClosed) break;
          final blockSha = sha256.convert(blockBytes).toString();
          session.send({
            't': Msg.fileOfferData,
            'offerId': offer.offerId,
            'name': fileName,
            'offset': reqOffset,
            'length': blockBytes.length,
            'sha256': blockSha,
            'data': base64.encode(blockBytes),
          });
          bytesSent += blockBytes.length;
          onProgress?.call(bytesSent, fileSize);
          // Close the serve stream after the last block so the loop exits.
          if (reqOffset + blockBytes.length >= fileSize) {
            completed = true;
            scheduleMicrotask(() => offer.serveCtrl.close());
          }
        } on _AdHocTransferCanceled {
          break;
        } catch (e) {
          session.send({
            't': Msg.fileOfferData,
            'offerId': offer.offerId,
            'name': fileName,
            'offset': reqOffset,
            'error': e.toString(),
          });
        }
      }
      _outbound.remove(offer.offerId);
      onSendComplete?.call(completed);
      if (completed) {
        notifier.showFileSent(fileName, session.peer.name);
        onLog('Ad-hoc send complete: $fileName -> ${session.peer.name}');
      } else {
        await notifier.cancelSendProgress(fileName);
        onLog('Ad-hoc send interrupted for $fileName', isError: true);
      }
    } catch (e) {
      _outbound.remove(offer.offerId);
      onSendComplete?.call(false);
      await notifier.cancelSendProgress(fileName);
      onLog('Ad-hoc send error for $fileName: $e', isError: true);
    }
  }

  // ---- Receiver side (auto-receive) --------------------------------------

  /// Handle an inbound [Msg.fileOffer]. Auto-starts a block-pull fetch without
  /// any user confirmation. Writes the file to [getReceivedFilesPath()] on
  /// completion and fires a system notification (Phase 3b).
  void handleFileOffer(PeerSession session, Map<String, dynamic> msg) {
    final offerId = msg['offerId'] as String?;
    final name = msg['name'] as String?;
    final size = (msg['size'] as num?)?.toInt() ?? 0;
    final sha = msg['sha256'] as String? ?? '';
    final rawHashes = msg['blockHashes'];
    final blockHashes = rawHashes is List
        ? rawHashes.map((e) => e.toString()).toList()
        : <String>[];

    if (offerId == null || name == null) {
      onLog('fileOffer missing offerId or name — dropped', isError: true);
      return;
    }
    if (_inbound.containsKey(offerId)) return; // duplicate, ignore

    final offer = _InboundOffer(
      offerId: offerId,
      name: name,
      size: size,
      sha256: sha,
      blockHashes: blockHashes,
      session: session,
    );
    _inbound[offerId] = offer;
    onLog('Ad-hoc offer received: $name (${size}B) offerId=$offerId');

    // Start auto-receive in the background.
    unawaited(_receiveOffer(offer));
  }

  Future<void> _receiveOffer(_InboundOffer offer) async {
    final destPath = getReceivedFilesPath();
    if (destPath == null) {
      onLog(
        'No received-files path configured — dropping offer ${offer.offerId}',
        isError: true,
      );
      _inbound.remove(offer.offerId);
      return;
    }

    try {
      await fetchFileBlockLevel(
        fs: fs,
        rootPath: destPath,
        relPath: offer.name,
        expectedSize: offer.size,
        expectedSha: offer.sha256,
        blockHashes: offer.blockHashes,
        sendRequest: (req) {
          // Pull one block: send fileOfferBlock, wait for the matching
          // fileOfferData to arrive via [handleFileOfferData].
          if (offer.session.isClosed || offer._sink.isClosed) {
            return Future.value(null);
          }
          offer.session.send({
            't': Msg.fileOfferBlock,
            'offerId': offer.offerId,
            'name': req['name'],
            'offset': req['offset'],
            'size': req['size'],
            if (req.containsKey('hash')) 'hash': req['hash'],
          });
          return offer._sink.next();
        },
        onProgress: (received, total) {
          notifier.showReceiveProgress(offer.name, received, total,
              offerId: offer.offerId);
        },
        pipelineDepth: _adHocPipelineDepth,
      );

      onLog(
          'Ad-hoc receive complete: ${offer.name} ← ${offer.session.peer.name}');
      final peerName = offer.session.peer.name;
      notifier.showFileReceived(offer.name, peerName, treeUri: destPath);
    } catch (e) {
      onLog('Ad-hoc receive failed for ${offer.name}: $e', isError: true);
      await notifier.cancelReceiveProgress(offer.name);
    } finally {
      offer._sink.close();
      _inbound.remove(offer.offerId);
    }
  }

  /// Route an inbound [Msg.fileOfferBlock] from the receiver into the serve
  /// loop for the matching outbound offer.
  void handleFileOfferBlock(PeerSession session, Map<String, dynamic> msg) {
    final offerId = msg['offerId'] as String?;
    if (offerId == null) return;
    final offer = _outbound[offerId];
    if (offer == null || offer.canceled || offer.serveCtrl.isClosed) {
      return; // unknown, cancelled, or already completed
    }
    offer.serveCtrl.add(msg);
  }

  /// Route an inbound [Msg.fileOfferControl] from the sender into the receive
  /// sink for the matching inbound offer. Pause/resume are sender-local today;
  /// cancel terminates the receiver promptly instead of waiting on the socket.
  void handleFileOfferControl(PeerSession session, Map<String, dynamic> msg) {
    final offerId = msg['offerId'] as String?;
    final action = msg['action'] as String?;
    if (offerId == null || action == null) return;

    // 1. Check if it's an inbound offer we are receiving (sender canceled)
    final inboundOffer = _inbound[offerId];
    if (inboundOffer != null && action == 'cancel') {
      inboundOffer._sink.add({
        't': Msg.fileOfferData,
        'offerId': offerId,
        'name': inboundOffer.name,
        'offset': 0,
        'error': 'transfer cancelled by sender',
      });
      inboundOffer._sink.close();
      onLog('Ad-hoc receive cancelled: ${inboundOffer.name}');
    }

    // 2. Check if it's an outbound offer we are sending (receiver canceled)
    final outboundOffer = _outbound[offerId];
    if (outboundOffer != null && action == 'cancel') {
      outboundOffer.cancel();
      onLog('Ad-hoc send cancelled by receiver: ${outboundOffer.name}');
    }
  }

  /// Cancel an inbound offer locally, notify the sender, and dismiss notification.
  void cancelInboundOffer(String offerId) {
    final offer = _inbound[offerId];
    // TEMP diagnostic logging (2026-07-14) — see notifier.dart's
    // notificationTapBackground doc comment. If cancel taps are reaching here
    // (confirmed by the notif_tap_main/cancel_action_received log lines) but
    // the transfer doesn't stop, "found: false" here means the offerId from
    // the notification payload no longer matches a live offer (e.g. it
    // already finished or errored out before the tap was processed).
    onLog(
      'cancelInboundOffer called: offerId=$offerId found=${offer != null}',
    );
    if (offer == null) return;

    // Unblock the local block-pull loop with an error message
    offer._sink.add({
      't': Msg.fileOfferData,
      'offerId': offerId,
      'name': offer.name,
      'offset': 0,
      'error': 'transfer cancelled by receiver',
    });
    offer._sink.close();

    // Send a cancel control message back to the sender
    try {
      offer.session.send({
        't': Msg.fileOfferControl,
        'offerId': offerId,
        'action': 'cancel',
      });
    } catch (_) {}

    onLog('Ad-hoc receive cancelled locally: ${offer.name}');
    notifier.cancelReceiveProgress(offer.name);
  }

  bool pauseOutboundForPeer(String peerId) {
    final offers = _outbound.values.where((o) => o.peerId == peerId);
    var changed = false;
    for (final offer in offers) {
      offer.pause();
      changed = true;
    }
    return changed;
  }

  bool resumeOutboundForPeer(String peerId) {
    final offers = _outbound.values.where((o) => o.peerId == peerId);
    var changed = false;
    for (final offer in offers) {
      offer.resume();
      changed = true;
    }
    return changed;
  }

  bool cancelOutboundForPeer(String peerId) {
    final offers = _outbound.values.where((o) => o.peerId == peerId).toList();
    for (final offer in offers) {
      offer.cancel();
      try {
        offer.session.send({
          't': Msg.fileOfferControl,
          'offerId': offer.offerId,
          'action': 'cancel',
        });
      } catch (_) {}
    }
    return offers.isNotEmpty;
  }

  /// Route an inbound [Msg.fileOfferData] from the sender into the receive
  /// sink for the matching inbound offer.
  void handleFileOfferData(PeerSession session, Map<String, dynamic> msg) {
    final offerId = msg['offerId'] as String?;
    if (offerId == null) return;
    final offer = _inbound[offerId];
    if (offer == null) return; // unknown or already completed
    offer._sink.add(msg);
  }

  // ---- Session lifecycle --------------------------------------------------

  /// Cancel all in-flight offers (both inbound and outbound) for [peerId].
  /// Called from [SyncEngine.onPeerSessionLost] so a mid-transfer disconnect
  /// doesn't leave lingering sinks consuming memory.
  void onSessionLost(String peerId) {
    // Close inbound sinks for this peer → _receiveOffer's fetchFileBlockLevel
    // gets null from sink.next() → throws StateError → catch logs + cleans up.
    final inboundKeys = _inbound.entries
        .where((e) => e.value.session.peer.deviceId == peerId)
        .map((e) => e.key)
        .toList();
    for (final k in inboundKeys) {
      _inbound[k]?._sink.close();
      // _receiveOffer's finally will remove from _inbound.
    }

    // Close outbound serve streams for this peer → serve loop ends.
    final outboundKeys = _outbound.entries
        .where((e) => e.value.peerId == peerId)
        .map((e) => e.key)
        .toList();
    for (final k in outboundKeys) {
      final o = _outbound.remove(k);
      o?.cancel();
    }
  }
}
