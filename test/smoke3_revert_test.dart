// Deterministic regression for the V2 smoke #3 failure: "modify → resync"
// reverts the edit and re-advertises the same files in a tight loop.
//
// This runs NO hardware. It drives the REAL [indexDiff] and the REAL [IndexDb]
// (FFI SQLite) through the exact state transitions the two devices perform in
// smoke #3. Because both bugs are pure logic (ordering authority + the
// scanner/fetch sharing one row), they reproduce identically here as on a
// real pair — the only thing a real pair adds is two filesystems, and the
// version-vector revert is independent of that.
//
// What this proves:
//   (A) indexDiff uses sha only and ignores the version vector, so a peer's
//       LOWER-version old content is fetched over our HIGHER-version local
//       edit → edit is reverted. This is the user-facing symptom.
//   (B) After a fetch records the local observation, a re-scan re-bumps the
//       same row (single shared row per path) → sequence climbs on idle
//       files → the re-advertise loop.

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:conduit/src/storage/db_factory.dart';
import 'package:conduit/src/storage/index_db.dart';
import 'package:conduit/src/sync/index_diff.dart';

const _pc = 'PC-0000';
const _phone = 'PH-1111';

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

Future<IndexDb> _open(String label, Directory root) async {
  DbFactory.init();
  final dir = Directory(p.join(root.path, label));
  await dir.create(recursive: true);
  return IndexDb.open(label, dir);
}

void main() {
  late Directory tmp;
  late IndexDb pcDb;
  late IndexDb phoneDb;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('smoke3_revert_');
    pcDb = await _open('pc', tmp);
    phoneDb = await _open('phone', tmp);
  });

  tearDown(() async {
    await pcDb.close();
    await phoneDb.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test(
      'BUG A: indexDiff fetches LOWER-version peer content over a HIGHER-version '
      'local edit — edit gets reverted', () async {
    // ── Setup: F was previously synced. Both devices have it at SHA_OLD. ──
    final oldContent = [1, 2, 3, 4, 5];
    final shaOld = _sha(oldContent);
    // PC wrote it first (scanner path) then phone received + recorded it.
    await pcDb.upsertLocal(
        relPath: 'F.txt',
        size: oldContent.length,
        mtime: 1000,
        sha256: shaOld,
        deviceId: _pc);
    // Phone received it from PC: applyRemote stores the peer row.
    final pcEntry = (await pcDb.liveSnapshot()).single;
    await phoneDb.applyRemote(pcEntry);

    // ── The edit: user modifies F on PC. New sha, bumped version+seq. ──
    final newContent = [9, 9, 9, 9, 9, 9, 9];
    final shaNew = _sha(newContent);
    await pcDb.upsertLocal(
        relPath: 'F.txt',
        size: newContent.length,
        mtime: 2000,
        sha256: shaNew,
        deviceId: _pc);

    final pcRowAfterEdit = (await pcDb.get('F.txt'))!;
    // Sanity: PC's edit is strictly newer than the phone's copy.
    expect(pcRowAfterEdit.version.countFor(_pc), greaterThan(1),
        reason: 'the edit must bump PC version');
    expect(pcRowAfterEdit.sha256, shaNew);

    final phoneRow = (await phoneDb.get('F.txt'))!;
    // PC's edited version DOMINATES the phone's copy — a correct sync engine
    // must NOT pull the phone's old content back over the edit.
    expect(
      pcRowAfterEdit.version.dominates(phoneRow.version),
      isTrue,
      reason: 'PC edit {PC:2} dominates phone {PC:1}',
    );

    // ── The decisive check: what does indexDiff say PC must fetch? ──
    // indexDiff is given PC's "what I have" (localSnapshot) and the peer's
    // "what it has" (the phone's live snapshot, i.e. SHA_OLD).
    final pcLocalLive = await pcDb.localSnapshot(_pc);
    final peerLive = await phoneDb.liveSnapshot(); // what the phone advertises

    final needs = indexDiff(localLive: pcLocalLive, peerLive: peerLive);

    // CORRECT behaviour: needs must be EMPTY — PC's copy is newer and the
    // phone is merely stale. There is nothing for PC to fetch.
    //
    // ACTUAL (buggy) behaviour: indexDiff sees shaNew != shaOld and decides
    // PC "needs" to fetch the phone's old content. That fetch overwrites the
    // edit on disk → the edit is reverted. This is exactly smoke #3.
    if (needs.isNotEmpty) {
      final peerEntry = needs.first.peer;
      printOnFailure('REGRESSION: indexDiff told PC to fetch '
          '${peerEntry.relPath} sha=${peerEntry.sha256.substring(0, 8)} '
          '(seq=${peerEntry.sequence}, v=${peerEntry.version}) even though '
          'PC already has a strictly newer version ${pcRowAfterEdit.version}. '
          'The fetch would overwrite the local edit.');
    }
    expect(needs, isEmpty,
        reason: 'indexDiff must NOT require a fetch when the local version '
            'dominates the peer version. A non-empty needs list is the '
            'edit-reversion bug.');
  });

  test(
      'BUG B: a fetched file with peer-supplied blockHashes re-bumps on every '
      'idle scan because the scanner records EMPTY blockHashes, defeating the '
      'sha-primary no-op guard → sequence climbs → re-advertise loop',
      () async {
    // ── Setup: phone has F and has computed its blockHashes (a real peer
    //    always advertises them — indexDiff/fetch use them for resume). PC has
    //    nothing for it yet. ──
    final content = [7, 7, 7, 7];
    final sha = _sha(content);
    final blocks = [
      _sha([7, 7]),
      _sha([7, 7])
    ]; // 2 blocks, like blockSize split
    await phoneDb.upsertLocal(
        relPath: 'F.txt',
        size: content.length,
        mtime: 5000,
        sha256: sha,
        deviceId: _phone,
        blockHashes: blocks);

    // PC learns the peer has F. applyRemote stores the peer row VERBATIM,
    // INCLUDING the non-empty blockHashes. This is the crucial difference
    // from a locally-scanned row: a peer row carries block hashes.
    final phoneEntry = (await phoneDb.liveSnapshot()).single;
    expect(phoneEntry.blockHashes, isNotEmpty,
        reason: 'a real peer advertises blockHashes');
    await pcDb.applyRemote(phoneEntry);

    // ── PC fetches F. The REAL production fetch path is
    //    `confirmLocalObservation` (engine.dart ~850): it stamps localSha so the
    //    next scanner pass sees disk == baseline, WITHOUT bumping version or
    //    sequence. A fetched file therefore arrives at a CONFIRMED state
    //    (localSha == sha) before any idle scan runs — that confirmation is what
    //    makes the sha-primary no-op guard below fire. Simulating fetch with a
    //    bare `upsertLocal` (as an earlier version of this test did) models a
    //    path the engine never takes and would burn a sequence here. ──
    await pcDb.confirmLocalObservation(relPath: 'F.txt', sha: sha);

    // ── Idle re-scans: same content, same (PC) mtime, EMPTY blocks — exactly
    //    what the scanner emits on a quiet folder. blockHashes on a LOCAL
    //    observation are always empty (the scanner/engine never pass them), so
    //    the test still exercises the _sameBlocks(nonEmpty, empty) shape on the
    //    FIRST scan — but the sha-primary guard fires first because disk sha ==
    //    localSha, so no bump occurs. ──
    var seqBefore = await pcDb.maxSequence();
    for (var i = 0; i < 3; i++) {
      await pcDb.upsertLocal(
          relPath: 'F.txt',
          size: content.length,
          mtime: 9000,
          sha256: sha,
          deviceId: _pc); // blockHashes defaults to []
    }
    final seqAfter = await pcDb.maxSequence();

    // CORRECT behaviour: an idle folder must burn ZERO sequences across
    // re-scans (this is the engine's key invariant — see IndexScanner docs).
    //
    // WHY this holds post-fix: production fetch is `confirmLocalObservation`,
    // which sets localSha = sha WITHOUT touching version/sequence. The scanner's
    // subsequent upsertLocal hits the sha-primary guard (disk sha == localSha)
    // and no-ops. The blockHashes mismatch (peer nonEmpty vs local empty) is
    // only consulted AFTER the sha guard, so a confirmed row never reaches it.
    //
    // ACTUAL (pre-fix) behaviour that this test was written to catch: if a
    // fetched file were recorded via a bare upsertLocal against an unconfirmed
    // row (localSha=''), the first scan would bump version+sequence, re-
    // advertise, the peer mirrors, and the symmetric one-shot re-triggers this
    // side on its next applyRemote (peer row again carries blocks) → the loop
    // sustains. The confirmLocalObservation step is what makes that impossible.
    printOnFailure('seqBefore=$seqBefore seqAfter=$seqAfter; '
        'an idle re-scan of unchanged content must not burn sequence');
    expect(seqAfter, seqBefore,
        reason: 'an idle re-scan of unchanged files must not burn sequence. '
            'A climb here is the re-advertise loop.');
  });
}
