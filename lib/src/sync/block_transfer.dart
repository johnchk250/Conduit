import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../protocol/wire.dart';
import 'manifest.dart';

/// Block size for V2 transfers (REDESIGN.md §(5)). Matches the legacy
/// `serveFile` chunk size so wire bandwidth characteristics are unchanged;
/// large enough that per-block framing overhead is negligible, small enough
/// that a corrupted block re-fetch is cheap.
const int blockSize = 1 << 20; // 1 MiB

/// Suffix for a partial block-level download (REDESIGN.md §(5)). The receiver
/// writes verified blocks here and atomically renames to the final name only
/// once the whole file is filled AND its SHA-256 matches the Index entry.
const syncPartSuffix = '.syncpart';

/// Thrown by [fetchFileBlockLevel] when the peer reports a terminal error for
/// a block (typically: source file vanished between Index advertise and
/// Request). The caller (the engine's needs-queue processor) catches this and
/// drops the file from the queue — it does NOT retry (REDESIGN.md §(5):
/// "A missing source file = ONE terminal error"). The next IndexUpdate from
/// the peer re-adds the file to the queue if it reappears.
class TerminalFetchError implements Exception {
  final String relPath;
  final String reason;
  TerminalFetchError(this.relPath, this.reason);
  @override
  String toString() => 'TerminalFetchError($relPath): $reason';
}

/// Send a single `request` for one block of [relPath] at [offset], expecting a
/// `response` of [size] bytes hashing to [blockHash]. The receiver-side pull is
/// [fetchFileBlockLevel]; this is the per-block request primitive the engine
/// uses. Exposed for tests; production code goes through [fetchFileBlockLevel].
typedef BlockSinkProvider = Future<Map<String, dynamic>?> Function();

/// Fetch a file block-by-block from the peer, writing verified blocks to a
/// `.<name>.syncpart` temp file and atomically renaming once complete.
///
/// ## Algorithm (REDESIGN.md §(5))
///
/// 1. Compute the block plan from [expectedSize]: ceil(size / blockSize)
///    blocks at offsets 0, B, 2B, ... Each block has an expected sha from
///    [blockHashes] when the peer supplied them (else we verify only on the
///    final whole-file hash).
/// 2. Resume: if `.<name>.syncpart` already exists with the right prefix of
///    bytes (verified against [blockHashes] when available), skip the blocks
///    already present. This makes a transfer survive a mid-download reconnect.
/// 3. For each outstanding block, send a `request` and await the `response`.
///    Verify the block sha (when known). Write at the block's offset.
/// 4. Once all blocks are filled, compute the whole-file SHA-256. If it equals
///    [expectedSha], atomically rename `.<name>.syncpart` → final name. Else
///    throw (the caller will not rename; the corrupt `.syncpart` is left in
///    place and reused/overwritten on the next attempt).
///
/// ## Terminal errors
///
/// A `response` carrying an `error` field throws [TerminalFetchError]. The
/// engine's needs-queue loop catches it and removes the file from the queue —
/// it does NOT retry. This is the fix for flaw #2 (the whole-file fetch loop
/// that retried a missing source file every ~4s forever).
///
/// [sendRequest] sends one `request` frame and returns the matching `response`
/// (or null if the session died / sink closed). It's injected so this function
/// is testable without a real socket — the engine wires it to its block-sink
/// registry, tests wire it to a fake.
///
/// [pipelineDepth] caps how many `request`s may be outstanding at once
/// (default 1 — the original, unchanged stop-and-wait behavior: send one
/// block request, await its response, only then send the next). Every
/// existing caller (the V2 engine's needs-queue processor, and every test in
/// block_transfer_test.dart) omits this argument, so nothing about their
/// behavior changes. Ad-hoc file sends (file_send.dart) pass a higher depth
/// — see that file for why a single stop-and-wait fetch loop under-uses a
/// fast LAN link. Blocks are still verified and applied to [accumulated] /
/// hashed into the running digest in strict ascending order regardless of
/// depth, so resume-from-`.syncpart` and the final whole-file SHA check are
/// unaffected by pipelining; only the wire scheduling of requests changes.
Future<String> fetchFileBlockLevel({
  required FileSystemAccess fs,
  required String rootPath,
  required String relPath,
  required int expectedSize,
  required String expectedSha,
  required List<String> blockHashes,
  required Future<Map<String, dynamic>?> Function(Map<String, dynamic> request)
      sendRequest,
  void Function(int received, int total)? onProgress,
  int pipelineDepth = 1,
  // Roadmap Phase 6.4 (version-restore) — fires with the vault destination
  // path and the SIZE OF THE OLD FILE THAT WAS VAULTED (not the new
  // incoming size) whenever an existing file is vaulted before being
  // overwritten by this fetch. Optional, defaults to null/no-op: every
  // pre-Phase-6 caller (and every existing test) is unaffected. See
  // _replacePartWithFinal.
  void Function(String vaultPath, int oldSizeBytes)? onVaulted,
}) async {
  final partRel = '$relPath$syncPartSuffix';
  final totalBlocks = (expectedSize + blockSize - 1) ~/ blockSize;

  final digestAcc = AccumulatorSink<Digest>();
  final digestSink = sha256.startChunkedConversion(digestAcc);

  // Resume: reuse only a fully verified .syncpart prefix. If the part file is
  // absent, lacks peer block hashes, or contains extra/corrupt bytes, discard it
  // and restart cleanly. New blocks are appended as they are verified, so a
  // reconnect can resume from the last durable block instead of starting over.
  final existingPart = await fs.stat(rootPath, partRel);
  int resumeBytes = 0;
  if (existingPart != null && blockHashes.isNotEmpty) {
    var okPrefix = 0;
    final completeBlocks = existingPart.size ~/ blockSize;
    for (var i = 0;
        i < completeBlocks && i < totalBlocks && i < blockHashes.length;
        i++) {
      final start = i * blockSize;
      final chunk =
          await readFileBlock(fs, rootPath, partRel, start, blockSize);
      if (chunk.length != blockSize) break;
      if (sha256.convert(chunk).toString() != blockHashes[i]) break;
      digestSink.add(chunk);
      okPrefix = start + chunk.length;
    }
    if (okPrefix > 0 && okPrefix == existingPart.size) {
      resumeBytes = okPrefix;
      onProgress?.call(resumeBytes, expectedSize);
    } else {
      await fs.delete(rootPath, partRel);
    }
  } else if (existingPart != null) {
    await fs.delete(rootPath, partRel);
  }

  // Request outstanding blocks in order, pipelining up to [pipelineDepth] of
  // them at once (depth 1 — the default — is the original stop-and-wait loop,
  // byte-for-byte: prime one request, await it, prime the next).
  //
  // Each `sendRequest` round-trip pays a full peer round-trip (socket write +
  // wait for the matching response). At depth 1, an N-block file costs
  // N × round-trip-time even on a LAN where the round trip is a couple of
  // milliseconds and bandwidth is otherwise sitting idle the whole time.
  // Depth > 1 keeps several requests outstanding simultaneously so the
  // peer's serve loop — which itself processes requests strictly in the
  // order they arrive; see `_serveBlocks` in file_send.dart and
  // `serveFileBlockLevel` below — never sits idle waiting for the next
  // request to land, turning the transfer from latency-bound into
  // bandwidth-bound. This requires no wire-protocol change: it works because
  // both serve loops respond to buffered requests strictly in arrival order,
  // so firing several requests before awaiting any of them still yields
  // responses in the same order they were sent.
  final effectiveDepth = pipelineDepth < 1 ? 1 : pipelineDepth;
  final startBlock = resumeBytes ~/ blockSize;

  Map<String, dynamic> blockRequest(int i) {
    final offset = i * blockSize;
    final want =
        (offset + blockSize > expectedSize) ? expectedSize - offset : blockSize;
    return {
      't': Msg.request,
      'name': relPath,
      'offset': offset,
      'size': want,
      if (i < blockHashes.length) 'hash': blockHashes[i],
    };
  }

  // In-flight request futures, oldest (next to be applied) at index 0. Each
  // is fired by calling `sendRequest` synchronously without awaiting the
  // previous one first, so up to `effectiveDepth` are ever outstanding.
  final inFlight = <Future<Map<String, dynamic>?>>[];
  var nextToSend = startBlock;
  void topUpPipeline() {
    while (nextToSend < totalBlocks && inFlight.length < effectiveDepth) {
      inFlight.add(sendRequest(blockRequest(nextToSend)));
      nextToSend++;
    }
  }

  topUpPipeline();
  for (var i = startBlock; i < totalBlocks; i++) {
    final offset = i * blockSize;
    final resp = await inFlight.removeAt(0);
    // A slot just freed — top up immediately so the window stays full while
    // this response is verified and written below.
    topUpPipeline();
    if (resp == null) {
      throw StateError(
          'session closed mid-fetch of $relPath at offset $offset');
    }
    if (resp['error'] != null) {
      throw TerminalFetchError(relPath, resp['error'].toString());
    }
    final data = _wireBytes(resp['data']);
    final respSha = resp['sha256'] as String?;
    final actualSha = sha256.convert(data).toString();
    if (respSha != null && respSha != actualSha) {
      throw StateError(
          'block $i ($relPath @ $offset) response hash mismatch: got $respSha, actual $actualSha');
    }
    if (i < blockHashes.length && actualSha != blockHashes[i]) {
      throw StateError(
          'block $i ($relPath @ $offset) hash mismatch: got $actualSha');
    }
    await fs.append(rootPath, partRel, data);
    digestSink.add(data);
    onProgress?.call(offset + data.length, expectedSize);
  }

  digestSink.close();
  final result = digestAcc.events.single.toString();
  if (expectedSha.isNotEmpty && result != expectedSha) {
    throw StateError(
        'whole-file hash mismatch for $relPath: got $result, want $expectedSha');
  }

  if (expectedSize == 0) {
    await fs.write(rootPath, relPath, const <int>[]);
    await fs.delete(rootPath, partRel);
    return result;
  }

  await _replacePartWithFinal(fs, rootPath, partRel, relPath,
      onVaulted: onVaulted);
  return result;
}

/// Roadmap Phase 6.4 (version-restore, edit-only scope — see PROGRESS.md
/// 2026-07-11 for why delete-restore is out of scope: it would require
/// touching `_applyRemoteTombstone`, which is on the project's own
/// do-not-touch list).
///
/// Before a fetched file replaces an existing one, the existing file is
/// moved into the `.syncversions` vault (already-existing but previously
/// dead infrastructure — see `manifest.dart`/`saf_access.dart`
/// `moveToVault`) so a prior version is recoverable. This is purely
/// additive to the disk layout: no DB write, no wire message, no version-
/// vector interaction, and no engine code touched — this function is not on
/// the do-not-touch list. Best-effort: if the vault write fails for any
/// reason (permissions, disk full, etc.), the transfer proceeds exactly as
/// it did before this change rather than being blocked by a vault failure.
Future<void> _replacePartWithFinal(
  FileSystemAccess fs,
  String rootPath,
  String partRel,
  String relPath, {
  void Function(String vaultPath, int oldSizeBytes)? onVaulted,
}) async {
  if (fs is LocalFileSystemAccess) {
    final part = File(p.join(rootPath, partRel));
    final dest = File(p.join(rootPath, relPath));
    await Directory(p.dirname(dest.path)).create(recursive: true);
    if (await dest.exists()) {
      var vaulted = false;
      try {
        // Stat BEFORE vaulting: moveToVault renames the file away, so
        // dest.length() would throw afterward.
        final oldSize = await dest.length();
        final vaultPath = await fs.moveToVault(rootPath, relPath);
        vaulted = true;
        onVaulted?.call(vaultPath, oldSize);
      } catch (_) {
        // Best-effort — fall through to the pre-existing delete-and-replace
        // behavior below so a vault failure never blocks the transfer.
      }
      // moveToVault already removed the file at `dest` by renaming it away;
      // only delete here if that didn't happen (vault failed, or `dest`
      // reappeared/still exists for some other reason).
      if (!vaulted && await dest.exists()) await dest.delete();
    }
    await part.rename(dest.path);
    return;
  }
  final existing = await fs.stat(rootPath, relPath);
  if (existing != null) {
    try {
      final vaultPath = await fs.moveToVault(rootPath, relPath);
      onVaulted?.call(vaultPath, existing.size);
    } catch (_) {
      // Best-effort — the write below overwrites in place either way,
      // matching pre-existing behavior when vaulting isn't possible.
    }
  }
  if (fs is TemporaryFileFinalizer) {
    await (fs as TemporaryFileFinalizer)
        .replaceFromTemporary(rootPath, partRel, relPath);
    return;
  }
  final bytes = await _readAll(fs, rootPath, partRel);
  await fs.write(rootPath, relPath, bytes);
  await fs.delete(rootPath, partRel);
}

/// Serve a file block-by-block in response to `request` frames. Streams each
/// requested block as a `response` with its SHA-256. If the source file is
/// gone at request time, sends ONE `response{error}` — the receiver treats
/// this as terminal and drops the file from its needs-queue (REDESIGN.md §(5),
/// kills flaw #2).
///
/// [requests] is a stream of request frames; [respond] sends one response
/// frame. The engine wires these to its session; tests wire them to fakes.
Future<void> serveFileBlockLevel({
  required FileSystemAccess fs,
  required String rootPath,
  required String relPath,
  required Stream<Map<String, dynamic>> requests,
  required FutureOr<void> Function(Map<String, dynamic> response) respond,
}) async {
  // Pre-check existence once. A per-request check would be more robust against
  // a vanish mid-serve, but reading the file per block (below) already throws
  // on a missing source, which we convert to a terminal error. This pre-check
  // just gives a clean early-out for the common "already gone" case.
  final stat = await fs.stat(rootPath, relPath);
  if (stat == null) {
    await for (final _ in requests) {
      await respond(
          {'t': Msg.response, 'name': relPath, 'error': 'no such file'});
    }
    return;
  }

  await for (final req in requests) {
    final offset = (req['offset'] as num?)?.toInt() ?? 0;
    final want = (req['size'] as num?)?.toInt() ?? blockSize;
    if (offset < 0 || offset > stat.size || want < 0) {
      await respond({
        't': Msg.response,
        'name': relPath,
        'offset': offset,
        'error': 'offset out of range',
      });
      continue;
    }
    final bounded = (offset + want > stat.size) ? stat.size - offset : want;
    try {
      final block = await readFileBlock(fs, rootPath, relPath, offset, bounded);
      await respond({
        't': Msg.response,
        'name': relPath,
        'offset': offset,
        'length': block.length,
        'sha256': sha256.convert(block).toString(),
        'data': block,
      });
    } catch (e) {
      await respond({
        't': Msg.response,
        'name': relPath,
        'offset': offset,
        'error': e.toString(),
      });
    }
  }
}

List<int> _wireBytes(Object? value) {
  if (value is Uint8List) return value;
  if (value is List<int>) return value;
  if (value is String) return base64.decode(value);
  throw const FormatException('response has no binary data');
}

/// Read every byte of a file via [FileSystemAccess]. Used by the resume path
/// and the serve path. SAF returns the whole buffer in one emit; desktop
/// streams chunks which we concatenate.
Future<List<int>> _readAll(
    FileSystemAccess fs, String rootPath, String relPath) async {
  final buf = <int>[];
  await for (final chunk in fs.openRead(rootPath, relPath)) {
    buf.addAll(chunk);
  }
  return buf;
}
