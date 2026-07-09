// Deterministic regression for the delete-propagation half of Bug #8: deleting a
// file that THIS device received (not authored) does not propagate to the peer.
// Root cause is PURE LOGIC, reproduced here with a real IndexDb and the real
// scanner tombstone-detection path — no SAF, no hardware.
//
// THE BUG
//
// The scanner detects local deletes by diffing "live rows this device owns"
// against "files seen on disk this pass". "Owns" came from `localLivePaths`,
// which filtered on "version-vector counter for THIS device > 0" — i.e.
// "originated here".
//
// A file we RECEIVED from a peer and fetched to disk is confirmed via
// `confirmLocalObservation`, which does NOT add our device's counter to the
// version vector (only a local EDIT bumps our counter). So a
// fetched-but-never-edited file carried solely the origin device's counter and
// was EXCLUDED from localLivePaths. Delete it on disk and the scanner never
// compared it against `seenPaths` → no `markDeletedLocal` → no tombstone → the
// peer never learns of the delete → permanent data divergence (phone deletes a
// received file, PC keeps it forever). This is exactly what the hardware test
// showed after Bug #8's re-fetch fix landed.
//
// THE FIX
//
// `localLivePaths` now admits a row whose [IndexEntry.localSha] is non-empty
// (we have its bytes on disk) in addition to rows we originated. A fetched file
// is confirmed (localSha set by confirmLocalObservation), so deleting it makes
// it absent from `seenPaths` while still present in localLivePaths → the
// scanner produces a tombstone → the delete propagates.
//
// SAFETY (why this cannot cause a delete-storm): `localSha` never crosses the
// wire ([IndexEntry.toJson] excludes it), so a freshly `applyRemote`'d peer row
// we have NOT yet fetched has `localSha == ''` and stays correctly excluded — a
// file we never pulled can never be falsely tombstoned. Only a confirmed row
// (bytes actually written to THIS disk) becomes eligible. This test pins both
// sides: the positive case (delete propagates) and the negative control (a
// never-fetched peer row is never tombstoned).

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:conduit/src/storage/db_factory.dart';
import 'package:conduit/src/storage/index_db.dart';

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
    tmp = await Directory.systemTemp.createTemp('bug9_recv_delete_');
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
      'Bug #9 (positive): a received-and-fetched file deleted on disk must '
      'appear in localLivePaths so the scanner tombstones it', () async {
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

    // Precondition of the bug: a fetched file has NO phone counter — only a
    // local edit would add it.
    final phoneRow = (await phoneDb.get('F.txt'))!;
    expect(phoneRow.version.knows(_phone), isFalse,
        reason: 'a pure fetch never bumps the receiver counter');

    // ── THE DECISIVE CHECK: F must be in localLivePaths. ──
    //
    // The scanner's tombstone loop is:
    //   for prior in localLivePaths(deviceId):
    //     if prior not in seenPaths: markDeletedLocal(prior)
    //
    // If F is absent from localLivePaths (the bug), then no matter that it's
    // gone from disk, the loop never considers it and produces no tombstone.
    final livePaths = await phoneDb.localLivePaths(_phone);
    expect(livePaths, contains('F.txt'),
        reason: 'a fetched-and-confirmed file must be tracked for tombstone '
            'detection. Its absence here means deleting it on disk never '
            'produces a tombstone and the delete never reaches the peer — '
            'silent, permanent data divergence.');

    // ── Confirm the consequence: with F absent from a fresh seenPaths (it was
    // deleted), the scanner's markDeletedLocal fires and produces a tombstone.
    // seenPaths is what the scanner built from the directory listing this pass;
    // an empty set models "F is gone from disk".
    final seenPaths = <String>{}; // F was deleted, nothing seen this pass
    final priorLive = await phoneDb.localLivePaths(_phone);
    final tombstoned = <String>[];
    for (final prior in priorLive) {
      if (!seenPaths.contains(prior)) {
        final wrote =
            await phoneDb.markDeletedLocal(relPath: prior, deviceId: _phone);
        if (wrote) tombstoned.add(prior);
      }
    }
    expect(tombstoned, contains('F.txt'),
        reason: 'the scanner must tombstone a deleted received file so the '
            'delete propagates to the peer on the next advertise.');
    final after = (await phoneDb.get('F.txt'))!;
    expect(after.deleted, isTrue, reason: 'row must be marked deleted = 1');
  });

  test(
      'Bug #9 (negative control / safety): a peer row we have NOT fetched '
      '(localSha empty) must NEVER be in localLivePaths — no delete-storm',
      () async {
    // PC authors F.
    await pcDb.upsertLocal(
        relPath: 'G.txt',
        size: 3,
        mtime: 1000,
        sha256: _sha([7, 7, 7]),
        deviceId: _pc);
    final pcEntry = (await pcDb.liveSnapshot()).single;

    // Phone learns of G via the wire but has NOT fetched it yet. This is the
    // exact state between _handleIndexFrame and the fetch completing — the
    // danger window for a delete-storm if the fix were naive.
    //
    // We feed the WIRE form (toJson -> fromJson) exactly as the production
    // engine does (_handleIndexFrame line ~1531/1554). toJson strips localSha
    // and fromJson defaults it to '' — so a never-fetched received row has
    // localSha == '' regardless of any applyRemote hardening. This pins the
    // real-world invariant the fix relies on.
    await phoneDb.applyRemote(IndexEntry.fromJson(pcEntry.toJson()));

    final gRow = (await phoneDb.get('G.txt'))!;
    expect(gRow.localSha, isEmpty,
        reason: 'an unfetched peer row has localSha == "" (applyRemote sets '
            'priorLocalSha ?? "" and there is no prior). This is the property '
            'that makes localSha a SAFE tombstone signal.');
    expect(gRow.version.knows(_phone), isFalse,
        reason: 'an unfetched peer row carries no local counter either');

    // G must NOT be in localLivePaths: we never pulled it, so its absence from
    // disk is NOT a local delete — tombstoning it would advertise a spurious
    // delete of a file we simply haven't fetched yet (a delete-storm).
    final livePaths = await phoneDb.localLivePaths(_phone);
    expect(livePaths, isNot(contains('G.txt')),
        reason: 'a never-fetched peer row must stay excluded from tombstone '
            'detection. If this fails, the fix is unsafe — every unfetched '
            'peer entry would be tombstoned on the next scan.');

    // And the scanner consequence: with G never on disk (empty seenPaths), G
    // is NOT tombstoned, because it was never in localLivePaths to begin with.
    final seenPaths = <String>{};
    final priorLive = await phoneDb.localLivePaths(_phone);
    final tombstoned = <String>[];
    for (final prior in priorLive) {
      if (!seenPaths.contains(prior)) {
        final wrote =
            await phoneDb.markDeletedLocal(relPath: prior, deviceId: _phone);
        if (wrote) tombstoned.add(prior);
      }
    }
    expect(tombstoned, isNot(contains('G.txt')),
        reason: 'a never-fetched peer row must not be tombstoned even though '
            'it is absent from disk — we never had it, so there is nothing to '
            'delete, and advertising a delete would corrupt the peer.');
  });
}
