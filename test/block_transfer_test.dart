import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/src/protocol/wire.dart';
import 'package:conduit/src/sync/block_transfer.dart';
import 'package:conduit/src/sync/manifest.dart';

/// Integration tests for the V2 block-level transfer pair:
/// [fetchFileBlockLevel] (receiver pull) ↔ [serveFileBlockLevel] (sender push).
///
/// Rather than mock each side in isolation, these tests wire the two together
/// through an in-process bridge (a [StreamController] for requests + a queue of
/// [Completer]s for responses). That exercises the REAL request/response frame
/// shapes both functions emit and consume — a shape mismatch between fetch and
/// serve is the class of bug that single-side mocks would miss.
///
/// The cases mirror REDESIGN.md §(5):
///   - happy path (single block + multi block) with whole-file sha verification
///   - terminal error drops the file (the flaw-#2 fix)
///   - .syncpart resume across a mid-fetch interruption
///   - whole-file hash mismatch is a hard error (corrupt transfer never renames)
///   - serve loop streams blocks in order and handles a vanished source
void main() {
  // Build a deterministic byte buffer of [n] bytes. Repetitive content is
  // fine — we verify via SHA, not by inspecting bytes — and it keeps the test
  // cheap for multi-MiB cases.
  List<int> bytes(int n) => List<int>.generate(n, (i) => i & 0xFF);

  // Whole-file sha of a buffer.
  String sha(List<int> b) => sha256.convert(b).toString();

  // Per-block sha list for a buffer of [totalBytes], split at [blockSize].
  List<String> blockHashesFor(List<int> b) {
    final out = <String>[];
    for (var i = 0; i < b.length; i += blockSize) {
      final end = (i + blockSize > b.length) ? b.length : i + blockSize;
      out.add(sha256.convert(b.sublist(i, end)).toString());
    }
    return out;
  }

  /// Wire a serve loop to a fetch-side [sendRequest]. Returns the sendRequest
  /// closure and a way to wait for the serve loop to finish. The serve loop
  /// owns [serverFs] and reads the source file from there.
  ({
    Future<Map<String, dynamic>?> Function(Map<String, dynamic>) sendRequest,
    Future<void> serveDone,
  }) bridge({
    required FakeFs serverFs,
    required String relPath,
  }) {
    final requestSink = StreamController<Map<String, dynamic>>(sync: true);
    final pending = <Completer<Map<String, dynamic>?>>[];
    final serveDone = serveFileBlockLevel(
      fs: serverFs,
      rootPath: 'r',
      relPath: relPath,
      requests: requestSink.stream,
      respond: (resp) {
        // Serve is single-threaded w.r.t. requests (it awaits each req before
        // reading the next), so responses complete in FIFO order.
        pending.removeAt(0).complete(resp);
      },
    );
    return (
      sendRequest: (req) async {
        final c = Completer<Map<String, dynamic>?>();
        pending.add(c);
        requestSink.add(req);
        return c.future;
      },
      serveDone: serveDone,
    );
  }

  test(
      'single-block fetch: file smaller than blockSize is fetched and verified',
      () async {
    final content = bytes(2048); // < 1 MiB → one block
    final serverFs = FakeFs({'a.txt': content});
    final clientFs = FakeFs({});

    final b = bridge(serverFs: serverFs, relPath: 'a.txt');
    final result = await fetchFileBlockLevel(
      fs: clientFs,
      rootPath: 'r',
      relPath: 'a.txt',
      expectedSize: content.length,
      expectedSha: sha(content),
      blockHashes: blockHashesFor(content),
      sendRequest: b.sendRequest,
    );
    expect(result, sha(content));
    // The verified bytes landed at the final path and the .syncpart is gone.
    expect(clientFs.files['a.txt'], content);
    expect(clientFs.files.containsKey('a.txt$syncPartSuffix'), isFalse);
  });

  test('multi-block fetch: a >2-block file is reassembled and verified',
      () async {
    final content = bytes(blockSize * 2 + 1234); // 3 blocks (last partial)
    final serverFs = FakeFs({'big.bin': content});
    final clientFs = FakeFs({});

    final b = bridge(serverFs: serverFs, relPath: 'big.bin');
    await fetchFileBlockLevel(
      fs: clientFs,
      rootPath: 'r',
      relPath: 'big.bin',
      expectedSize: content.length,
      expectedSha: sha(content),
      blockHashes: blockHashesFor(content),
      sendRequest: b.sendRequest,
    );
    expect(clientFs.files['big.bin'], content);
  });

  test(
      'pipelined fetch (depth > 1): a multi-block file is reassembled and '
      'verified identically to the depth-1 default', () async {
    final content = bytes(blockSize * 5 + 777); // 6 blocks, last partial
    final serverFs = FakeFs({'big.bin': content});
    final clientFs = FakeFs({});

    final b = bridge(serverFs: serverFs, relPath: 'big.bin');
    final result = await fetchFileBlockLevel(
      fs: clientFs,
      rootPath: 'r',
      relPath: 'big.bin',
      expectedSize: content.length,
      expectedSha: sha(content),
      blockHashes: blockHashesFor(content),
      sendRequest: b.sendRequest,
      pipelineDepth: 4,
    );
    expect(result, sha(content));
    expect(clientFs.files['big.bin'], content);
    expect(clientFs.files.containsKey('big.bin$syncPartSuffix'), isFalse);
  });

  test(
      'pipelining keeps up to pipelineDepth requests outstanding at once '
      'instead of waiting for each response before sending the next',
      () async {
    // A hand-rolled sendRequest (not the bridge helper) so the test controls
    // exactly when each response "arrives", to prove requests 2..depth are
    // sent before request 1's response is ever supplied — the actual
    // pipelining property, not just the end-to-end result the test above
    // already covers.
    final content = bytes(blockSize * 4); // exactly 4 full blocks
    final hashes = blockHashesFor(content);
    final clientFs = FakeFs({});

    final requestedOffsets = <int>[];
    final pending = <Completer<Map<String, dynamic>?>>[];
    Future<Map<String, dynamic>?> sendRequest(Map<String, dynamic> req) {
      requestedOffsets.add((req['offset'] as num).toInt());
      final c = Completer<Map<String, dynamic>?>();
      pending.add(c);
      return c.future;
    }

    Map<String, dynamic> responseFor(int blockIndex) {
      final offset = blockIndex * blockSize;
      final end = (offset + blockSize > content.length)
          ? content.length
          : offset + blockSize;
      final chunk = content.sublist(offset, end);
      return {
        't': Msg.response,
        'name': 'a.txt',
        'offset': offset,
        'length': chunk.length,
        'sha256': hashes[blockIndex],
        'data': base64.encode(chunk),
      };
    }

    final future = fetchFileBlockLevel(
      fs: clientFs,
      rootPath: 'r',
      relPath: 'a.txt',
      expectedSize: content.length,
      expectedSha: sha(content),
      blockHashes: hashes,
      sendRequest: sendRequest,
      pipelineDepth: 3,
    );

    // Let fetchFileBlockLevel run to its first real suspension point (it
    // primes the pipeline synchronously before ever awaiting a response).
    await Future<void>.delayed(Duration.zero);
    // Depth 3, 4 total blocks: exactly 3 requests should be outstanding —
    // none of them answered yet.
    expect(requestedOffsets, [0, blockSize, blockSize * 2]);

    // Answering the oldest request should top the pipeline back up with the
    // 4th (final) block — proving the window slides rather than just firing
    // depth-many requests once at the very start and waiting on all of them.
    pending[0].complete(responseFor(0));
    await Future<void>.delayed(Duration.zero);
    expect(requestedOffsets, [0, blockSize, blockSize * 2, blockSize * 3]);

    // Finish the rest; order of completion here doesn't matter — blocks are
    // still applied to the file in ascending order regardless.
    pending[1].complete(responseFor(1));
    pending[2].complete(responseFor(2));
    pending[3].complete(responseFor(3));

    final result = await future;
    expect(result, sha(content));
    expect(clientFs.files['a.txt'], content);
  });

  test('terminal error (source gone) drops the file without retry', () async {
    // The server has no such file → serveFileBlockLevel replies with ONE
    // response{error} per request. fetchFileBlockLevel must throw
    // TerminalFetchError on the first block; the engine catches that and drops
    // the file from the needs-queue (never retries).
    final serverFs = FakeFs({}); // source absent
    final clientFs = FakeFs({});

    final b = bridge(serverFs: serverFs, relPath: 'ghost.txt');
    expect(
      () => fetchFileBlockLevel(
        fs: clientFs,
        rootPath: 'r',
        relPath: 'ghost.txt',
        expectedSize: 100,
        expectedSha: sha(bytes(100)),
        blockHashes: blockHashesFor(bytes(100)),
        sendRequest: b.sendRequest,
      ),
      throwsA(isA<TerminalFetchError>()),
    );
    // Nothing was written to the client.
    expect(clientFs.files, isEmpty);
  });

  test('resume from .syncpart: already-verified prefix blocks are skipped',
      () async {
    final content = bytes(blockSize * 2 + 500); // 3 blocks
    // Simulate a previous run that fetched + verified the first block, then
    // died. The .syncpart on disk holds exactly that verified prefix.
    final partial = content.sublist(0, blockSize);
    final clientFs = FakeFs({'a.txt$syncPartSuffix': partial});

    // Track which blocks the client actually requests. Block 0 must be skipped
    // (it's already verified in the .syncpart); only blocks 1 and 2 requested.
    final requestedOffsets = <int>[];
    final serverFs = FakeFs({'a.txt': content});
    final b = bridge(serverFs: serverFs, relPath: 'a.txt');
    final instrumented = (Map<String, dynamic> req) async {
      requestedOffsets.add((req['offset'] as num).toInt());
      return b.sendRequest(req);
    };

    await fetchFileBlockLevel(
      fs: clientFs,
      rootPath: 'r',
      relPath: 'a.txt',
      expectedSize: content.length,
      expectedSha: sha(content),
      blockHashes: blockHashesFor(content),
      sendRequest: instrumented,
    );
    // Block 0 (offset 0) was NOT re-requested; blocks 1 and 2 were.
    expect(requestedOffsets, [blockSize, blockSize * 2]);
    expect(clientFs.files['a.txt'], content);
    expect(clientFs.files.containsKey('a.txt$syncPartSuffix'), isFalse);
  });

  test(
      'whole-file hash mismatch is a hard error and does NOT materialize the file',
      () async {
    // Server serves real bytes; we LIE about expectedSha. After all blocks are
    // received the whole-file digest won't match → StateError, and the final
    // write/rename must not happen.
    final content = bytes(4096);
    final serverFs = FakeFs({'a.txt': content});
    final clientFs = FakeFs({});

    final b = bridge(serverFs: serverFs, relPath: 'a.txt');
    expect(
      () => fetchFileBlockLevel(
        fs: clientFs,
        rootPath: 'r',
        relPath: 'a.txt',
        expectedSize: content.length,
        expectedSha: 'bogus-sha-that-does-not-match',
        blockHashes: blockHashesFor(content),
        sendRequest: b.sendRequest,
      ),
      throwsA(isA<StateError>()),
    );
    // The corrupt .syncpart may remain (resume fodder) but the final file must
    // never have been written.
    expect(clientFs.files.containsKey('a.txt'), isFalse);
  });

  test(
      'serve loop: a vanished source answers every request with a terminal error',
      () async {
    final serverFs = FakeFs({}); // no file
    final responses = <Map<String, dynamic>>[];

    final requestSink = StreamController<Map<String, dynamic>>(sync: true);
    final serveDone = serveFileBlockLevel(
      fs: serverFs,
      rootPath: 'r',
      relPath: 'gone.txt',
      requests: requestSink.stream,
      respond: responses.add,
    );
    // Two requests for the same vanished file → two error responses, in order.
    requestSink
        .add({'t': Msg.request, 'name': 'gone.txt', 'offset': 0, 'size': 10});
    requestSink
        .add({'t': Msg.request, 'name': 'gone.txt', 'offset': 10, 'size': 10});
    await requestSink.close();
    await serveDone;

    expect(responses.length, 2);
    for (final r in responses) {
      expect(r['error'], isNotNull);
      expect(r['name'], 'gone.txt');
    }
  });

  test('serve loop: blocks are returned in request order with correct shas',
      () async {
    final content = bytes(blockSize + 1000); // 2 blocks
    final serverFs = FakeFs({'a.txt': content});
    final responses = <Map<String, dynamic>>[];

    final requestSink = StreamController<Map<String, dynamic>>(sync: true);
    final serveDone = serveFileBlockLevel(
      fs: serverFs,
      rootPath: 'r',
      relPath: 'a.txt',
      requests: requestSink.stream,
      respond: responses.add,
    );
    final hashes = blockHashesFor(content);
    // Request block 1 then block 0 (out of order on purpose) — serve replies
    // in the order requests arrive, each carrying its own block sha.
    requestSink.add(
        {'t': Msg.request, 'name': 'a.txt', 'offset': blockSize, 'size': 1000});
    requestSink.add(
        {'t': Msg.request, 'name': 'a.txt', 'offset': 0, 'size': blockSize});
    await requestSink.close();
    await serveDone;

    expect(responses.length, 2);
    expect(responses[0]['offset'], blockSize);
    expect(responses[0]['sha256'], hashes[1]);
    expect(base64.decode(responses[0]['data'] as String),
        content.sublist(blockSize, blockSize + 1000));
    expect(responses[1]['offset'], 0);
    expect(responses[1]['sha256'], hashes[0]);
    expect(base64.decode(responses[1]['data'] as String),
        content.sublist(0, blockSize));
  });
}

/// In-memory [FileSystemAccess] for block-transfer tests. Backed by a map of
/// relPath → bytes. Implements the four methods [block_transfer] actually uses
/// (`stat`, `openRead`, `write`, `delete`); the rest throw since they're never
/// reached on this code path. This is a deliberate, self-contained copy of the
/// scanner-test FakeFs (kept local so each test file is independently readable).
class FakeFs implements FileSystemAccess {
  FakeFs([Map<String, List<int>>? initial]) {
    if (initial != null) files.addAll(initial);
  }
  final Map<String, List<int>> files = {};

  @override
  bool get isAndroidSAF => false;

  @override
  Future<List<String>> listFiles(String rootPath) async =>
      files.keys.toList(growable: false);

  @override
  Future<FileEntry?> stat(String rootPath, String relPath) async {
    final data = files[relPath];
    if (data == null) return null;
    return FileEntry(relPath: relPath, size: data.length, mtime: 0, sha256: '');
  }

  @override
  Stream<List<int>> openRead(String rootPath, String relPath,
      [int offset = 0]) async* {
    final data = files[relPath];
    if (data == null) return;
    yield data.sublist(offset);
  }

  @override
  Future<void> write(String rootPath, String relPath, List<int> data) async {
    files[relPath] = List<int>.of(data);
  }

  @override
  Future<void> append(String rootPath, String relPath, List<int> data) async {
    files[relPath] = [...?files[relPath], ...data];
  }

  @override
  Future<bool> delete(String rootPath, String relPath) async =>
      files.remove(relPath) != null;

  @override
  Future<String> moveToVault(String rootPath, String relPath) async =>
      throw UnsupportedError('not used by block_transfer');
}
