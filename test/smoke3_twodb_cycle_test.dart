// Deterministic two-DB reproduction of the RESIDUAL hardware revert, found
// after Fix #1 (version-vector indexDiff) shipped.
//
// The hardware trace showed the loop GONE (seq frozen) but the edit STILL
// reverted, with the PC row ending up {PC:4, shaOLD} and the phone row
// {PC:3, C4AD:1, shaOLD} — concurrent vectors, both with OLD content.
//
// The real scenario is NOT "PC creates, PC edits" (what smoke3_revert_test
// modeled) — the buggy file `smoke_v2_phone2pc.txt` was CREATED ON THE PHONE
// and EDITED ON THE PC. This test reproduces that exact lineage with TWO real
// IndexDbs stepping through the same applyRemote / indexDiff / upsertLocal /
// fetch-record cycle the engine performs, so whatever path reverts the edit
// on hardware reproduces here.

import 'dart:convert';
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

/// Mirror of the engine's _processNeeds post-fetch step: after fetching, if the
/// DB does NOT already represent the just-fetched sha, record it as a local
/// observation (engine.dart ~808-825).
Future<void> _recordFetch(
  IndexDb db,
  String path,
  int size,
  int mtime,
  String sha,
  String deviceId,
  List<String> blockHashes,
) async {
  final existing = await db.get(path);
  final alreadyRepresented =
      existing != null && !existing.deleted && existing.sha256 == sha;
  if (!alreadyRepresented) {
    await db.upsertLocal(
      relPath: path,
      size: size,
      mtime: mtime,
      sha256: sha,
      deviceId: deviceId,
      blockHashes: blockHashes,
    );
  }
}

void main() {
  late Directory tmp;
  late IndexDb pcDb;
  late IndexDb phoneDb;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('smoke3_twodb_');
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

  // One full "reconcile round" in each direction. Mirrors the real engine:
  //   1. SCANNER: a re-observes its own disk (upsertLocal of bytesOf for every
  //      file). On a real pair this is the FIRST step of every reconcile, and
  //      it's the step my earlier model omitted — when the phone still has
  //      OLD bytes on disk but the DB row is the PC's NEW row (just applied),
  //      this scan re-records the OLD bytes with a bumped counter, creating a
  //      concurrent version. THAT is the revert mechanism.
  //   2. a advertises its local rows to b (applyRemote).
  //   3. b computes needs (indexDiff) and fetches from a.
  Future<void> round(String from, IndexDb a, String to, IndexDb b,
      {required Map<String, List<int>> aDisk,
      required Map<String, List<int>> bDisk}) async {
    // 1. a scans its own disk.
    for (final entry in aDisk.entries) {
      await a.upsertLocal(
        relPath: entry.key,
        size: entry.value.length,
        mtime: 9999,
        sha256: _sha(entry.value),
        deviceId: from,
      );
    }
    // 2. a advertises local rows to b.
    final delta = await a.changesSinceLocal(0, from);
    for (final e in delta) {
      await b.applyRemote(e);
    }
    // 3. b computes needs vs a's live snapshot and fetches.
    final peerLive = await a.localSnapshot(from);
    final localLive = await b.localSnapshot(to);
    final needs = indexDiff(localLive: localLive, peerLive: peerLive);
    for (final need in needs) {
      final content = aDisk[need.relPath]!;
      // Fetch lands the bytes on b's disk.
      bDisk[need.relPath] = content;
      await _recordFetch(b, need.relPath, content.length, 9999, _sha(content),
          to, need.peer.blockHashes);
    }
  }

  test(
      'phone-origin file edited on PC survives the reconcile cycle '
      '(the hardware smoke #3 residual revert)', () async {
    final oldContent = utf8.encode('phone-to-PC smoke probe, created on phone');
    final shaOld = _sha(oldContent);

    // Each device's disk (what the scanner sees).
    final phoneDisk = <String, List<int>>{'F.txt': oldContent};
    final pcDisk = <String, List<int>>{}; // PC starts empty

    // ── 1. Phone CREATES the file (scanner upsertLocal). ──
    await phoneDb.upsertLocal(
        relPath: 'F.txt',
        size: oldContent.length,
        mtime: 1000,
        sha256: shaOld,
        deviceId: _phone);

    // ── 2. Sync round: phone → PC. PC learns of F, fetches OLD content. ──
    await round(_phone, phoneDb, _pc, pcDb, aDisk: phoneDisk, bDisk: pcDisk);

    final pcRow1 = (await pcDb.get('F.txt'))!;
    printOnFailure(
        'after phone→PC sync, PC row: sha=${pcRow1.sha256.substring(0, 8)} '
        'v=${pcRow1.version} seq=${pcRow1.sequence}');

    // ── 3. User EDITS F on PC. New sha on PC's disk, PC bumps its counter. ──
    final newContent = utf8.encode('PC_EDITED_NEW_CONTENT_v1');
    final shaNew = _sha(newContent);
    pcDisk['F.txt'] = newContent; // the edit lands on PC disk
    await pcDb.upsertLocal(
        relPath: 'F.txt',
        size: newContent.length,
        mtime: 2000,
        sha256: shaNew,
        deviceId: _pc);

    final pcRow2 = (await pcDb.get('F.txt'))!;
    printOnFailure(
        'after PC edit, PC row: sha=${pcRow2.sha256.substring(0, 8)} '
        'v=${pcRow2.version} seq=${pcRow2.sequence}');
    expect(pcRow2.sha256, shaNew, reason: 'PC edit must record the new sha');

    // ── 4. Sync rounds until quiescent. Phone still has OLD bytes on disk
    //    (it never fetched the edit). Does the cycle converge to NEW, or
    //    revert PC to OLD? ──
    for (var i = 0; i < 5; i++) {
      await round(_pc, pcDb, _phone, phoneDb, aDisk: pcDisk, bDisk: phoneDisk);
      await round(_phone, phoneDb, _pc, pcDb, aDisk: phoneDisk, bDisk: pcDisk);
    }

    final pcFinal = (await pcDb.get('F.txt'))!;
    final phoneFinal = (await phoneDb.get('F.txt'))!;
    printOnFailure(
        'FINAL PC:     sha=${pcFinal.sha256.substring(0, 8)} v=${pcFinal.version}');
    printOnFailure(
        'FINAL phone:  sha=${phoneFinal.sha256.substring(0, 8)} v=${phoneFinal.version}');

    // CORRECT: the PC's edited content must survive. The PC's row is the
    // newest authored version; nothing the phone advertises (stale OLD bytes)
    // should overwrite it.
    expect(pcFinal.sha256, shaNew,
        reason: 'the PC edit must survive the reconcile cycle. If this is '
            'shaOLD, the edit was reverted — the residual hardware bug.');
    // And the content must converge on BOTH devices (the phone eventually
    // fetches the PC's edit).
    expect(phoneFinal.sha256, shaNew,
        reason: 'the phone must eventually converge to the PC-edited content');
  });

  test(
      'two-way editing: after PC edits a phone-origin file, the PHONE can then '
      'edit it too (no false "stale disk" block on a received file)', () async {
    // This is the case that a naive version-vector-only guard gets wrong: a
    // device that RECEIVED a file and then EDITS it must be allowed to bump,
    // because the post-fetch stamped localSha so the scanner sees a real change.
    final oldContent = utf8.encode('original phone content');
    final shaOld = _sha(oldContent);

    final phoneDisk = <String, List<int>>{'F.txt': oldContent};
    final pcDisk = <String, List<int>>{};

    // 1. Phone creates; 2. PC fetches OLD; 3. PC edits to NEW1.
    await phoneDb.upsertLocal(
        relPath: 'F.txt',
        size: oldContent.length,
        mtime: 1000,
        sha256: shaOld,
        deviceId: _phone);
    await round(_phone, phoneDb, _pc, pcDb, aDisk: phoneDisk, bDisk: pcDisk);
    final shaNew1 = _sha(utf8.encode('PC edit round 1'));
    pcDisk['F.txt'] = utf8.encode('PC edit round 1');
    await pcDb.upsertLocal(
        relPath: 'F.txt',
        size: pcDisk['F.txt']!.length,
        mtime: 2000,
        sha256: shaNew1,
        deviceId: _pc);

    // 4. Sync so the phone FETCHES PC's edit (this seeds phone's localSha).
    for (var i = 0; i < 3; i++) {
      await round(_pc, pcDb, _phone, phoneDb, aDisk: pcDisk, bDisk: phoneDisk);
      await round(_phone, phoneDb, _pc, pcDb, aDisk: phoneDisk, bDisk: pcDisk);
    }
    expect((await phoneDb.get('F.txt'))!.sha256, shaNew1,
        reason: 'phone must have fetched the PC edit before the phone edits');

    // 5. PHONE now edits the received file. This MUST bump the phone's counter
    //    and NOT be treated as stale disk (the regression guard).
    final shaNew2 = _sha(utf8.encode('phone edit round 2'));
    phoneDisk['F.txt'] = utf8.encode('phone edit round 2');
    await phoneDb.upsertLocal(
        relPath: 'F.txt',
        size: phoneDisk['F.txt']!.length,
        mtime: 3000,
        sha256: shaNew2,
        deviceId: _phone);
    final phoneRowAfterEdit = (await phoneDb.get('F.txt'))!;
    expect(phoneRowAfterEdit.sha256, shaNew2,
        reason:
            'a genuine edit to a RECEIVED file must bump and record new sha');

    // 6. Sync to convergence — both must end at the phone's round-2 edit.
    for (var i = 0; i < 5; i++) {
      await round(_phone, phoneDb, _pc, pcDb, aDisk: phoneDisk, bDisk: pcDisk);
      await round(_pc, pcDb, _phone, phoneDb, aDisk: pcDisk, bDisk: phoneDisk);
    }
    expect((await pcDb.get('F.txt'))!.sha256, shaNew2,
        reason: 'PC must converge to the phone round-2 edit');
    expect((await phoneDb.get('F.txt'))!.sha256, shaNew2,
        reason: 'phone must keep its round-2 edit');
  });

  test('concurrent pairing sync must converge pre-existing files', () async {
    final pcContent = utf8.encode('PC pre-existing content');
    final phoneContent = utf8.encode('Phone pre-existing content');
    final shaPC = _sha(pcContent);
    final shaPhone = _sha(phoneContent);

    final pcDisk = <String, List<int>>{'shared.txt': pcContent};
    final phoneDisk = <String, List<int>>{'shared.txt': phoneContent};

    // 1. Both devices create/scan the file independently.
    await pcDb.upsertLocal(
        relPath: 'shared.txt',
        size: pcContent.length,
        mtime: 1000,
        sha256: shaPC,
        deviceId: _pc);
    await phoneDb.upsertLocal(
        relPath: 'shared.txt',
        size: phoneContent.length,
        mtime: 1000,
        sha256: shaPhone,
        deviceId: _phone);

    // 2. Get advertisements from both sides BEFORE either applies the other's.
    final pcAd = await pcDb.changesSinceLocal(0, _pc);
    final phoneAd = await phoneDb.changesSinceLocal(0, _phone);

    final pcPeerLiveBefore = await phoneDb.localSnapshot(_phone); // what PC sees of Phone (prior to applying PC's update)
    final phonePeerLiveBefore = await pcDb.localSnapshot(_pc); // what Phone sees of PC (prior to applying Phone's update)

    // 3. Apply remote advertisements on both sides (simulate network arrival).
    for (final e in phoneAd) {
      await pcDb.applyRemote(e);
    }
    for (final e in pcAd) {
      await phoneDb.applyRemote(e);
    }

    // 4. Compute needs on both sides using the peerLive snapshots from step 2.
    final pcLocalLive = await pcDb.localSnapshot(_pc);
    final pcNeeds = indexDiff(localLive: pcLocalLive, peerLive: pcPeerLiveBefore);

    final phoneLocalLive = await phoneDb.localSnapshot(_phone);
    final phoneNeeds = indexDiff(localLive: phoneLocalLive, peerLive: phonePeerLiveBefore);

    // 5. Fetch if needed.
    for (final need in pcNeeds) {
      final content = phoneDisk[need.relPath]!;
      pcDisk[need.relPath] = content;
      await _recordFetch(pcDb, need.relPath, content.length, 9999, _sha(content),
          _pc, need.peer.blockHashes);
    }
    for (final need in phoneNeeds) {
      final content = pcDisk[need.relPath]!;
      phoneDisk[need.relPath] = content;
      await _recordFetch(phoneDb, need.relPath, content.length, 9999, _sha(content),
          _phone, need.peer.blockHashes);
    }

    // Assert that they converged.
    expect(pcDisk['shared.txt'], phoneDisk['shared.txt'],
        reason: 'Pre-existing files must sync and converge during concurrent initial sync.');
  });
}
