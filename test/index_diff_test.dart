import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/src/storage/index_db.dart';
import 'package:conduit/src/sync/index_diff.dart';
import 'package:conduit/src/sync/version_vector.dart';

/// Unit tests for [indexDiff] — the needs-queue computation.
///
/// [indexDiff] is the single function that decides "what does THIS device need
/// to fetch from its peer". Its rules are deliberately conservative and the
/// tests pin every one of them, because a bug here means either (a) the two
/// peers never converge, or (b) they re-fetch the same file on every reconcile
/// forever (the exact storm the V2 redesign was built to kill), or (c) a stale
/// peer copy reverts a local edit (the smoke #3 bug — fixed by making the
/// [VersionVector] the sole ordering authority).
///
/// Contract under test: the version vector decides ordering; sha decides content
/// equality. A file is fetched ONLY when the peer's version does not lose to the
/// local one (strictly newer, or concurrent conflict). Equal content (same sha)
/// is always skipped. A peer's stale copy never overwrites a higher-version
/// local edit.
void main() {
  // Helper: build a live (non-deleted) entry with sensible defaults so each
  // test only spells out the fields it cares about.
  IndexEntry live(
    String path, {
    int size = 100,
    String sha256 = 'aaa',
    VersionVector version = const VersionVector.empty(),
    int sequence = 1,
    List<String> blocks = const [],
    String localSha = '',
  }) =>
      IndexEntry(
        relPath: path,
        size: size,
        mtime: 0,
        sha256: sha256,
        version: version,
        sequence: sequence,
        deleted: false,
        blockHashes: blocks,
        localSha: localSha,
      );

  // Helper: a tombstone (deleted) entry.
  IndexEntry tombstone(String path,
          {VersionVector version = const VersionVector.empty()}) =>
      IndexEntry(
        relPath: path,
        size: 0,
        mtime: 0,
        sha256: '',
        version: version,
        sequence: 1,
        deleted: true,
      );

  // Convenience version vectors. The device that wrote a row bumps its own
  // counter, so a "peer is newer" entry carries a higher peer counter.
  final peerNewer = VersionVector({'peer': 2});
  final mineNewer = VersionVector({'me': 2});

  test('both have the same sha → skip (in sync, no fetch)', () {
    final local = [live('a.txt', sha256: 'sha-X', version: peerNewer)];
    final peer = [live('a.txt', sha256: 'sha-X', version: peerNewer)];
    expect(indexDiff(localLive: local, peerLive: peer), isEmpty);
  });

  test('peer has a live file I lack → need it', () {
    final local = <IndexEntry>[];
    final peer = [live('a.txt')];
    final needs = indexDiff(localLive: local, peerLive: peer);
    expect(needs.single.relPath, 'a.txt');
  });

  test(
      'peer has a live file I only have as a tombstone → need it (resurrection)',
      () {
    // My DB row is a tombstone (applyRemote stored it deleted). liveSnapshot
    // would exclude it, but indexDiff's contract must also hold when a caller
    // passes a tombstone-bearing local list: a peer bringing the file back
    // must re-fetch it.
    final local = [tombstone('a.txt')];
    final peer = [live('a.txt', sha256: 'sha-X')];
    final needs = indexDiff(localLive: local, peerLive: peer);
    expect(needs.single.relPath, 'a.txt');
  });

  test('both live, shas differ, peer version strictly newer → need it', () {
    // The genuine-update case: peer has a higher version with different bytes.
    final local = [
      live('a.txt', sha256: 'old', version: VersionVector({'peer': 1}))
    ];
    final peer = [live('a.txt', sha256: 'new', version: peerNewer)];
    final needs = indexDiff(localLive: local, peerLive: peer);
    expect(needs.single.peer.sha256, 'new');
  });

  test('both live, shas differ, MY version dominates → SKIP (no revert)', () {
    // The smoke #3 regression guard: my copy is newer (higher version) with a
    // different sha. Fetching the peer's stale bytes would revert my edit — so
    // needs MUST be empty.
    final local = [live('a.txt', sha256: 'new', version: mineNewer)];
    final peer = [
      live('a.txt', sha256: 'old', version: VersionVector({'me': 1}))
    ];
    expect(indexDiff(localLive: local, peerLive: peer), isEmpty);
  });

  test('peer entry is a tombstone → skip (Phase 2 does not propagate deletes)',
      () {
    final local = [live('a.txt', sha256: 'sha-X', version: mineNewer)];
    final peer = [tombstone('a.txt')];
    expect(indexDiff(localLive: local, peerLive: peer), isEmpty);
  });

  test('size fallback: both unhashed + size mismatch + peer newer → need it',
      () {
    // Neither side has a sha (sha == ''). With a size mismatch and a strictly
    // newer peer version, we fetch — the size difference is strong enough.
    final local = [
      live('a.txt', size: 100, sha256: '', version: VersionVector({'peer': 1}))
    ];
    final peer = [live('a.txt', size: 200, sha256: '', version: peerNewer)];
    final needs = indexDiff(localLive: local, peerLive: peer);
    expect(needs.single.peer.size, 200);
  });

  test('size fallback: both unhashed + size match → skip (avoid fetch storm)',
      () {
    // We can't tell cheaply whether the bytes differ; skip and let the next
    // scan that hashes the local file resolve it. Fetching here would loop.
    final local = [live('a.txt', size: 100, sha256: '')];
    final peer = [live('a.txt', size: 100, sha256: '')];
    expect(indexDiff(localLive: local, peerLive: peer), isEmpty);
  });

  test('mixed folder: only the genuinely-newer or missing files are needed',
      () {
    final local = [
      live('same.txt', sha256: 'sha-1', version: peerNewer), // identical → skip
      live('changed.txt',
          sha256: 'old',
          version: VersionVector({'peer': 1})), // peer newer → need
      live('mineOnly.txt',
          sha256: 'sha-9',
          version: mineNewer), // peer lacks → not a need (we push)
      live('myEdit.txt',
          sha256: 'mynew',
          version: mineNewer), // MY edit, peer stale → SKIP (no revert)
    ];
    final peer = [
      live('same.txt', sha256: 'sha-1', version: peerNewer),
      live('changed.txt', sha256: 'new', version: peerNewer),
      live('peerOnly.txt', sha256: 'sha-7'), // we lack → need
      live('myEdit.txt',
          sha256: 'stale', version: VersionVector({'me': 1})), // stale → skip
    ];
    final needs = indexDiff(localLive: local, peerLive: peer);
    expect(
      needs.map((n) => n.relPath).toSet(),
      {'changed.txt', 'peerOnly.txt'},
    );
  });

  test(
      'the returned Need carries the peer entry (expected size + sha + blocks)',
      () {
    // The engine reads need.peer.sha256 / .size / .blockHashes to drive the
    // block-level fetch and final verification, so the Need must wrap the PEER
    // entry (the target version), not the local one.
    final peerEntry =
        live('a.txt', size: 4096, sha256: 'deadbeef', blocks: ['b0', 'b1']);
    final needs = indexDiff(localLive: [], peerLive: [peerEntry]);
    expect(needs.single.peer, same(peerEntry));
    expect(needs.single.peer.blockHashes, ['b0', 'b1']);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // The convergence regression (hardware smoke #3). The original sha-equality
  // skip compared the local row's AUTHORITATIVE sha256 against the peer's sha.
  // But after applyRemote merges a peer's edit into a file THIS device
  // authored, the local row's sha256 is already the PEER's new sha while the
  // device's actual disk still holds the OLD bytes (recorded in localSha).
  // indexDiff then saw sha256 == peer.sha256, concluded "in sync", and never
  // fetched — so the receiver of an edit on a file it authored never converged.
  //
  // localSha is the only field that reflects the real on-disk bytes. The
  // sha-equality skip must therefore require the DISK bytes (localSha) to match
  // the peer's sha, not the authoritative sha256. A non-empty localSha that
  // differs from the peer's sha means the bytes are stale → fetch.
  // ─────────────────────────────────────────────────────────────────────────
  test(
      'convergence: peer edited a file I authored — my DB has the peer sha but my '
      'disk (localSha) is still old → I MUST fetch (hardware smoke #3)', () {
    // Exact field values observed on the phone DB after the PC edit:
    //   sha256   = peer's new sha (applyRemote merged it)
    //   localSha = my old on-disk sha (preserved by applyRemote)
    //   version  = merged, peer's counter is higher (peer authored the edit)
    final local = [
      live('F.txt',
          sha256: 'new',
          version: VersionVector({'me': 1, 'peer': 2}),
          sequence: 19,
          localSha: 'old'),
    ];
    final peer = [
      live('F.txt',
          sha256: 'new', version: VersionVector({'me': 1, 'peer': 2})),
    ];
    final needs = indexDiff(localLive: local, peerLive: peer);
    expect(needs.single.relPath, 'F.txt',
        reason: 'my disk bytes (localSha=old) do not match the peer sha (new); '
            'I have only received the metadata, not the bytes → must fetch');
  });

  test(
      'convergence: empty localSha (unseeded) must NOT spuriously force a fetch',
      () {
    // A row that was never locally observed (localSha='') with sha256 == peer
    // sha is the normal pre-edit / synced state, e.g. the default test entries.
    // Forcing a fetch here would re-introduce the fetch storm. Only a NON-EMPTY
    // localSha that differs should trigger a fetch.
    final local = [
      live('a.txt',
          sha256: 'sha-X', version: peerNewer), // localSha defaults ''
    ];
    final peer = [live('a.txt', sha256: 'sha-X', version: peerNewer)];
    expect(indexDiff(localLive: local, peerLive: peer), isEmpty);
  });

  test('convergence: disk bytes DO match peer (localSha == peer sha) → skip',
      () {
    // The genuinely-in-sync case after a successful fetch: localSha was stamped
    // to the fetched sha (confirmLocalObservation) and the peer still advertises
    // it. This MUST skip — no fetch storm.
    final local = [
      live('a.txt', sha256: 'sha-X', version: peerNewer, localSha: 'sha-X'),
    ];
    final peer = [live('a.txt', sha256: 'sha-X', version: peerNewer)];
    expect(indexDiff(localLive: local, peerLive: peer), isEmpty);
  });
}
