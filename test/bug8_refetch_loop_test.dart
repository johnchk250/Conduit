// Deterministic regression for Bug #8: the pathologically-slow startup
// reconcile on Android (~25 min for an 11-file folder, WAL ballooning,
// pair stuck "Scanning" forever). Root cause is PURE LOGIC, reproduced here
// with two real IndexDbs and the real indexDiff — no SAF, no hardware.
//
// THE BUG
//
// `_processNeeds` computes needs via `indexDiff(localLive, peerLive)`, where
// `localLive = db.localSnapshot(deviceId)`. localSnapshot filtered on
// "version-vector counter for THIS device > 0" — i.e. "originated here".
//
// A file we RECEIVED from a peer and fetched to disk is confirmed via
// `confirmLocalObservation`, which does NOT add our device's counter to the
// version vector (only a local EDIT bumps our counter). So a
// fetched-but-never-edited file carries solely the origin device's counter and
// was EXCLUDED from localSnapshot. indexDiff then saw `mine == null` for it and
// computed a need on EVERY reconcile → re-fetched it → `fs.write` churned the
// WAL and bumped the file mtime → the FolderWatcher's (count+size+mtime)
// signature changed → a spurious "Local change detected" → another reconcile →
// infinite loop.
//
// THE FIX
//
// localSnapshot now admits a row whose [IndexEntry.localSha] is non-empty (we
// have its bytes on disk) in addition to rows we originated. A fetched file is
// confirmed (localSha set by confirmLocalObservation), so it enters the
// snapshot and indexDiff's "mineDiskSha == peer.sha256 → skip" path fires.

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:conduit/src/storage/db_factory.dart';
import 'package:conduit/src/storage/index_db.dart';
import 'package:conduit/src/sync/index_diff.dart';

const _pc = '0A5D-ABF5'; // matches the real hardware deviceIds
const _phone = 'C4AD-18B3';

String _sha(List<int> b) => sha256.convert(b).toString();

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
    tmp = await Directory.systemTemp.createTemp('bug8_refetch_');
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

  test('Bug #8: a fetched file must NOT be a need on the next reconcile',
      () async {
    // ── PC authors F. ──
    final content = [1, 2, 3, 4, 5];
    final sha = _sha(content);
    await pcDb.upsertLocal(
        relPath: 'F.txt',
        size: content.length,
        mtime: 1000,
        sha256: sha,
        deviceId: _pc);
    final pcEntry = (await pcDb.liveSnapshot()).single;

    // Phone learns of F via the wire (what _handleIndexFrame does).
    await phoneDb.applyRemote(pcEntry);

    // Phone fetches F. The REAL engine's post-fetch step is
    // confirmLocalObservation (NOT upsertLocal) — it stamps localSha WITHOUT
    // adding the phone's counter. This is the exact post-fetch state the
    // production engine produces.
    await phoneDb.confirmLocalObservation(relPath: 'F.txt', sha: sha);

    final phoneRow = (await phoneDb.get('F.txt'))!;
    // Precondition of the bug: a fetched file has NO phone counter — only a
    // local edit would add it.
    expect(phoneRow.version.knows(_phone), isFalse,
        reason: 'a pure fetch never bumps the receiver counter');

    // ── THE DECISIVE CHECK: next reconcile's needs must be empty. ──
    final phoneLocalLive = await phoneDb.localSnapshot(_phone);
    final peerLive = await pcDb.liveSnapshot();
    final needs = indexDiff(localLive: phoneLocalLive, peerLive: peerLive);

    // CORRECT (fixed): needs is empty — localSnapshot admits the fetched file
    // (its localSha is set), so indexDiff's "mineDiskSha == peer.sha256 → skip"
    // path fires.
    //
    // ACTUAL (buggy): the original origin-counter-only predicate excluded the
    // fetched row → indexDiff saw mine==null → need → perpetual re-fetch loop.
    expect(needs, isEmpty,
        reason: 'a fetched-and-confirmed file must not be a need. A non-empty '
            'needs list is the Bug #8 re-fetch loop: every reconcile re-fetches '
            'the same files, churning the WAL and tripping the mtime watcher, '
            'so the pair never idles (the ~25-min startup on Android).');
  });

  test(
      'Bug #8 (negative control): the original origin-counter-only predicate '
      'makes a fetched file a perpetual need — documents what the fix changes',
      () async {
    // This negative control pins the OLD behaviour so the regression is
    // unambiguous: if someone reverts localSnapshot to the origin-counter-only
    // filter, the test above fails (need present) while this one still passes —
    // together they lock in both sides of the fix.
    final content = [9, 9, 9];
    final sha = _sha(content);
    await pcDb.upsertLocal(
        relPath: 'F.txt',
        size: content.length,
        mtime: 1000,
        sha256: sha,
        deviceId: _pc);
    await phoneDb.applyRemote((await pcDb.liveSnapshot()).single);
    await phoneDb.confirmLocalObservation(relPath: 'F.txt', sha: sha);

    // Reproduce the ORIGINAL predicate inline (origin-counter only).
    final allLive = await phoneDb.liveSnapshot();
    final origPredicateLocal = allLive.where((e) {
      final c = e.version.counts[_phone];
      return c != null && c > 0;
    }).toList();
    final peerLive = await pcDb.liveSnapshot();

    expect(origPredicateLocal, isEmpty,
        reason: 'under the old filter, a fetched file (no local counter) is '
            'invisible to localSnapshot');

    final origNeeds =
        indexDiff(localLive: origPredicateLocal, peerLive: peerLive);
    expect(origNeeds, hasLength(1),
        reason: 'the old predicate made every fetched file a perpetual need — '
            'the Bug #8 loop. This negative control documents exactly that.');
  });
}
