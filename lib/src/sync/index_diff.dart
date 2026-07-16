import '../storage/index_db.dart';
import 'version_vector.dart';

/// One item the V2 engine needs to fetch from the peer: which file, and the
/// [IndexEntry] describing the version we want (carries expected size + sha +
/// blockHashes for verification and resume).
class Need {
  final IndexEntry peer;
  final NeedReason reason;

  Need(this.peer, {required this.reason});

  String get relPath => peer.relPath;
  @override
  String toString() => 'Need(${peer.relPath}, ${peer.size}B)';
}

enum NeedReason {
  missingLocally,
  peerVersionNewer,
  concurrentPeerWins,
  equalVersionDifferentDiskBytes,
  resurrection,
}

/// Compute the needs-queue for THIS device given the local and peer live
/// snapshots (REDESIGN.md §"Target architecture").
///
/// ## Ordering authority (the edit-reversion fix)
///
/// The [VersionVector] is the SOLE ordering authority, exactly as its design
/// intends. sha is reduced to a CONTENT comparison only — it answers "are the
/// bytes the same", never "which is newer". When both sides have a live file
/// with a sha mismatch, the decision is:
///
///   - my version dominates-or-equals the peer's → SKIP. Mine is at least as
///     new; fetching the peer's bytes would REVERT a local edit.
///   - peer version strictly dominates mine     → fetch (genuine update).
///   - neither dominates (concurrent / conflict) → deterministic LWW: the side
///     whose mtime is LOWER (the "loser") fetches the other's content; the
///     higher-mtime side already has the content that will survive. When mtime
///     is equal, the sha lexical order breaks the tie so both sides agree.
///     Phase 4 backs up the loser's pre-conflict copy to `.syncversions`.
///
/// ## Cases (full list)
///
///   - peer has a live file I lack              → need it
///   - both live, my DISK bytes == peer's sha   → in sync, skip
///   - both live, my version ≥ peer's           → skip (never revert)
///   - both live, peer version strictly newer   → need it
///   - both live, concurrent, peer mtime > mine → need it (LWW: I lose)
///   - both live, concurrent, peer mtime < mine → skip  (LWW: I win)
///   - both live, concurrent, same mtime, peer
///     sha lexically greater                    → need it (tie-break: I lose)
///   - both live, concurrent, same mtime, peer
///     sha lexically ≤ mine                     → skip  (tie-break: I win)
///   - both live, at least one unhashed + size
///     mismatch                                 → need it (sha fallback)
///   - peer entry is a tombstone                → skip (Phase 4 deletes)
///   - my copy is a tombstone, peer has it live → need it (resurrection)
///
/// ## Convergence: localSha is the disk truth (hardware smoke #3)
///
/// The "do I already have the peer's bytes" comparison uses [IndexEntry.localSha]
/// (the sha of the bytes THIS device last confirmed on its OWN disk) when it is
/// non-empty, NOT the authoritative [IndexEntry.sha256]. Why: after `applyRemote`
/// merges a peer's edit into a file this device authored, the local row's sha256
/// is ALREADY the peer's new sha (applyRemote replaces it), while the device's
/// actual disk still holds the OLD bytes (localSha, which applyRemote preserves).
/// Comparing sha256 == peer.sha256 would therefore report "in sync" and the
/// receiver would never fetch — bytes never converge. localSha is the only field
/// that reflects real on-disk content; an empty localSha (unseeded row) falls
/// back to the authoritative sha256 so a never-observed row does not force a
/// spurious fetch.
List<Need> indexDiff({
  required List<IndexEntry> localLive,
  required List<IndexEntry> peerLive,
}) {
  final byPath = {for (final e in localLive) e.relPath: e};
  final needs = <Need>[];
  for (final peer in peerLive) {
    if (peer.deleted) continue; // Phase 4 propagates deletes; ignore here.
    final mine = byPath[peer.relPath];
    if (mine == null) {
      // I don't have it at all (or only as a tombstone, which applyRemote
      // stores with deleted=1 and is excluded from liveSnapshot).
      needs.add(Need(peer, reason: NeedReason.missingLocally));
      continue;
    }
    if (mine.deleted) {
      // Resurrection: peer has it live, my row is a tombstone.
      needs.add(Need(peer, reason: NeedReason.resurrection));
      continue;
    }
    // Both live. "In sync" means my DISK bytes equal the peer's sha. We must
    // compare against [IndexEntry.localSha] (the sha of THIS device's actual
    // on-disk bytes), NOT the authoritative [IndexEntry.sha256]: after
    // `applyRemote` merges a peer's edit, the local row's sha256 is already the
    // peer's sha, but my disk still holds the OLD bytes (localSha, which
    // applyRemote preserves). Comparing sha256 here would falsely report "in
    // sync" and the receiver would never fetch — so the bytes never converge
    // (hardware smoke #3). An empty localSha (unseeded row) falls back to the
    // authoritative sha256, so a never-observed row does not force a fetch.
    final mineDiskSha = mine.localSha.isNotEmpty ? mine.localSha : mine.sha256;
    if (peer.sha256.isNotEmpty &&
        mineDiskSha.isNotEmpty &&
        peer.sha256 == mineDiskSha) {
      continue;
    }
    // Bytes differ (or one side unhashed). Decide by VERSION VECTOR, not sha.
    // We use STRICT dominance here, not dominatesEq: if MY version strictly
    // dominates the peer's, the peer's bytes are STALE and fetching them would
    // REVERT a local edit — so skip. But when the versions are EQUAL (the common
    // case after `applyRemote` merges a peer's edit into a row this device
    // authored: both sides hold the merged {me, peer} vector), dominance does
    // not decide anything — my authoritative sha may already match the peer's
    // while my DISK bytes (localSha) are still the pre-edit content. Falling
    // through here lets the fetch logic below pull the bytes I'm missing.
    // (dominatesEq would skip the equal case and the receiver would never fetch
    // — the hardware smoke #3 convergence bug.)
    if (mine.version.dominates(peer.version)) {
      // Mine is STRICTLY newer than the peer's. Skip — fetching would REVERT my
      // local edit. (The equal-version case is intentionally NOT skipped.)
      continue;
    }
    // Peer is strictly newer OR the versions are concurrent (conflict). For
    // the unhashed fallback, we can't be sure the bytes actually differ, so
    // gate on size to avoid a fetch storm; the next scan resolves it.
    if (mine.sha256.isEmpty || peer.sha256.isEmpty) {
      if (peer.size != mine.size) {
        needs.add(Need(peer, reason: NeedReason.peerVersionNewer));
      }
      continue;
    }
    // Both hashed, shas differ, peer version does not genuinely lose to mine.
    // If the peer strictly dominates or they are equal, we must fetch (no conflict).
    if (peer.version.dominates(mine.version) || peer.version == mine.version) {
      needs.add(Need(
        peer,
        reason: peer.version == mine.version
            ? NeedReason.equalVersionDifferentDiskBytes
            : NeedReason.peerVersionNewer,
      ));
      continue;
    }
    // CONCURRENT versions (neither dominates). Use a deterministic Last-Write-
    // Wins tie-break so both devices agree on the SAME winner. The LOSING side
    // (lower mtime, or lower sha if mtime equal) fetches the winner's content.
    // The WINNING side skips — it already has what will survive. This prevents
    // the mutual-fetch swap where both sides fetched each other's content and
    // bounced the file back and forth forever.
    //
    // Note: [IndexDb.applyRemote] no longer merges version vectors when content
    // (sha) differs — so first-pair concurrent files correctly appear as
    // concurrent vectors here rather than falsely dominated.
    final peerWins = peer.mtime > mine.mtime ||
        (peer.mtime == mine.mtime && peer.sha256.compareTo(mineDiskSha) > 0);
    if (peerWins) {
      needs.add(Need(peer, reason: NeedReason.concurrentPeerWins));
    }
    // else: we are the LWW winner — skip, the peer will fetch from us.
  }
  return needs;
}
