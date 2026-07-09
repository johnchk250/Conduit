# Conduit — Architecture & Sync-Hardening Reference

> **Purpose.** A single document that lets any new agent (or contributor) grasp
> *what Conduit is*, *how it is built*, and — most importantly — *what hardening
> is already in place to make the sync feature reliable*. Every claim below is
> traceable to a source file; read this first, then drill into the files it cites.
>
> **Status as written:** Sync engine stable through Bug #9 (received-file delete
> propagation) + clipboard hardening (2026-07-06). **154/154 tests passing.**
>
> **Maintained by:** append a dated section to *Appendix B — Change log* when you
> change anything the document describes.

---

## 1. What Conduit is

A **peer-to-peer folder sync** application for **two devices that you own** — a
Windows PC and an Android phone. It mirrors the contents of paired folders in
**both directions over your local Wi-Fi**.

```
┌─── PC (Windows) ───┐              ┌── Phone (Android) ──┐
│  D:\Sync            │   UDP beacon  │  /storage/.../Sync   │
│  + SQLite index DB  │◀─────────────▶│  + SQLite index DB   │
│  + block transfers  │   TCP+TLS     │  + foreground svc    │
└─────────────────────┘  (port 41828) └──────────────────────┘
```

**Key properties (these are the product's reason to exist):**

| Property | How |
|---|---|
| No cloud, no account, no relay | Everything happens LAN-side between your two devices. |
| Private | File bytes never leave your LAN. Discovery beacons carry only public identity (name, id, public key, listen port) — never file contents. |
| Cross-network auto-reconnect | Pairing is identity-based (pinned ed25519 keys), so home ↔ office Wi-Fi needs no re-pairing. |
| One codebase | A single Flutter/Dart project compiles to a Windows `.exe` and an Android `.apk`. |

**Built from:** `pubspec.yaml` → Flutter SDK 3.27+, Dart SDK ^3.6.0. Core deps:
`crypto`, `ed25519_edwards` (identity), `sqflite_common_ffi` + `sqlite3_flutter_libs`
(index DB on both platforms), `network_info_plus` (LAN IP discovery), `qr_flutter` +
`mobile_scanner` (pairing), `provider` (state), `file_picker`.

---

## 2. What it does (user-facing behavior)

- **Define folder pairs.** Each pair links a local folder on this device to a
  folder on the paired peer. Direction is per-pair: **two-way**, **receive-only**,
  or **send-only**.
- **Automatic two-way sync.** When both devices are on the same Wi-Fi, changes
  propagate in the background. Edits, additions, and **deletes** all converge.
- **Conflict safety.** When both sides edit the same file, the **newer version
  wins** (decided by version vector, not mtime) and the loser is backed up to
  `.syncversions/` for 14 days.
- **Resumable transfers.** Files move in 1 MiB SHA-256-verified blocks; a dropped
  connection mid-transfer resumes from the last verified block.
- **Pairing.** QR-code scan (code embedded in the QR) or 6-digit code entry. The
  code is **single-use** — consumed on successful pair.

**UI (Material 3):** four destinations — Overview, Folders, Devices, Activity.
Adaptive: `NavigationRail` on wide screens, `BottomNav` on phones.
(`lib/src/ui/*.dart`.)

---

## 3. Architecture overview

### 3.1 Two engines coexist — the V2 engine is the one in use

There is a single sync engine in the codebase. The V2 index-based design is
documented in `REDESIGN.md` ("Syncthing-inspired"). The old manifest-based v1
path has been removed.

| | **V2 engine** (`SyncEngine`) |
|---|---|
| Entry point | `engine.dart` → `reconcile` → `scanner` → `indexDiff` → `fetchFileBlockLevel` |
| Source of truth | **Per-folder SQLite Index DB**, durable across reconnects |
| Ordering | **Version vectors** (the sole ordering authority) |
| Delete detection | Tombstone rows in the Index DB, version-vector dominance |
| Transfer | **block-level**, `.syncpart` + atomic rename, **terminal errors drop the need** |
| Status | **Active** |

**When reading code, assume the index-based path.** Shared file I/O lives in
`manifest.dart` (`FileEntry`, `FileSystemAccess`, `hashFile`).

### 3.2 Module map

```
lib/src/
  core/
    identity.dart        ed25519 keypair; deviceId = first 8 hex of sha256(pubKey) → "XXXX-XXXX"
    config_store.dart    config.json: folder pairs + paired peers + feature flags
  protocol/
    wire.dart            length-prefixed JSON wire messages + FolderPair/SyncDirection models
  net/
    discovery.dart       UDP broadcast auto-discovery of paired peers on the LAN
    peer_registry.dart   PeerConnectionRegistry: THE source of truth for "live session for peer X"
    peer_session.dart    one persistent TLS session per peer; send()/onMessage
    secure_frame.dart    FrameCodec: [4-byte len][JSON] envelope, single-owner (no silent drops)
    tls_keys.dart        self-signed cert / key material
    connection_supervisor.dart  beacon-independent reconnect policy (5s sweep + exp backoff)
  storage/
    db_factory.dart      sqflite_common_ffi bootstrap (works on Windows AND Android)
    index_db.dart        ★ the per-folder SQLite Index DB — durable source of truth
  sync/
    version_vector.dart  ★ per-file {deviceId→counter}; the SOLE ordering authority
    scanner.dart         walks the folder, reconciles disk ↔ Index DB (decoupled from sync)
    index_diff.dart      ★ computes the needs-queue from local vs peer snapshots
    block_transfer.dart  ★ 1 MiB block fetch + .syncpart + atomic rename + terminal-error
    engine.dart          ★ the coordinator: per-pair reconcile loop
    watcher.dart         debounced filesystem change signal (triggers reconcile)
    manifest.dart        shared file I/O: FileEntry, FileSystemAccess, hashFile
  platform/
    saf_access.dart      FileSystemAccess backed by Android SAF document trees
  ui/                    Material 3 screens + theme
  app_state.dart         central ChangeNotifier wiring engine + net + UI
  diag.dart              structured diagnostic log (profile-gated)

android/app/src/main/kotlin/.../
  MainActivity.kt        SAF tree-picker channel
  SafOps.kt              SAF read/write/list/delete/moveToVault (native)
  SyncService.kt         foreground service (wake lock, dataSync)

test/                    154 tests — see Appendix A
```

★ = the heart of the V2 sync engine.

### 3.3 The three independent, idempotent mechanisms

The V2 architecture (REDESIGN.md) deliberately splits sync into **three mechanisms
that each stay correct on their own**, so a failure in one can't corrupt another:

1. **Persistent Index DB** (`index_db.dart`) — one row per file, survives
   reconnects. The durable source of truth. No "rebuild on every reconcile."
2. **Version vectors** (`version_vector.dart`) — per-file ordering. Bumps only
   THIS device's counter; merges take the per-device max. Dominance decides newer;
   neither-dominates = conflict.
3. **Monotonic sequence + Index/IndexUpdate frames** — per-folder counter. `Index`
   (full list) once per connection; afterwards only `IndexUpdate` entries with
   `sequence > peerMax`. Kills the manifest-rebuild race.

Plus: **scanner decoupled from sync** (`scanner.dart` writes rows independently),
**block-level transfer** (`block_transfer.dart`), and a **dumb persistent
connection** that just delivers frames.

---

## 4. The sync loop, step by step

This is `SyncEngine.reconcile` (`engine.dart`), the per-pair coordinator. Read this
alongside `engine.dart:700-874`.

```
                       ┌─────────────────────────────┐
   watcher / reconnect │  reconcile(pair, session?)  │  ← triggered by: watcher
   / index arrival ───▶│                             │     fire, peer (re)connect,
                       └──────────────┬──────────────┘     inbound IndexUpdate
                                      │
            1. _propagateRemoteDeletes(pair)   ← apply authoritative peer tombstones
                                      │
            2. scanner.scan(...)               ← disk → Index DB (no-op on idle folder)
                                      │
                   ┌──── session == null? ────┐
                   YES                        NO
                   │                          │
            (DB current,               3. _advertiseDelta()  ← send IndexUpdate past watermark
             "Idle (no peer)")               │
                                      4. have peer snapshot?
                                         NO → send indexRequest, RETURN (work resumes
                                              when the peer's index frame arrives)
                                         YES ↓
                                      5. _processNeeds()
                                         indexDiff(local, peer) → needs-queue
                                         for each need: fetchFileBlockLevel (1MiB blocks,
                                           .syncpart, atomic rename), confirmLocalObservation
                                      │
                                   "Idle" / "V2 synced: N/N fetched"
```

**Why a reconcile ends early at step 4 when the peer snapshot isn't known yet:**
needs can't be computed without the peer's live entries, and fetch can't run
without needs. The peer's reply to `indexRequest` re-enters `_handleIndexFrame`,
which kicks another reconcile that *does* have the snapshot. This two-phase shape
is intentional — it's what keeps the loop from spinning on incomplete state.

**The no-op-invariant (load-bearing):** on an idle folder, `scanner.scan` and
`upsertLocal` must burn **zero** sequences, or peers would re-fetch unchanged
files forever. This invariant is the subject of `smoke3_revert_test.dart` and is
protected by the sha-primary no-op guard in `upsertLocal`.

---

## 5. The Index DB — the durable source of truth

`lib/src/storage/index_db.dart`. One SQLite DB **per folder pair**, holding one row
per file (`IndexEntry`):

```
relPath, size, mtime, sha256, versionVector, sequence, deleted, blockHashes, localSha
```

### 5.1 The two fields that prevent every known sync bug — read this twice

| Field | Meaning | Why it matters |
|---|---|---|
| `sha256` | the **authoritative** whole-file hash | the "current version of this file" identity |
| `localSha` | the sha of the bytes **THIS device last confirmed on its OWN disk** | the **disk truth**. DB-LOCAL ONLY — `toJson()` strips it, so it never crosses the wire. |

`localSha` exists precisely because the authoritative `sha256` is *not* the disk
truth after a peer edit merges in. The distinction is the fix for hardware smoke
#3 (edit reversion), Bug #8 (re-fetch loop), and Bug #9 (delete propagation). It
is the most subtle field in the codebase; if you change sync behavior, re-read the
doc comments on `localSha` in `index_db.dart` and the two snapshot methods below.

### 5.2 The two snapshot methods and why both exist

- **`liveSnapshot()`** — every non-tombstone row (both ours and peers'). Used to
  compute needs.
- **`localSnapshot(deviceId)`** — rows THIS device has bytes for: `localSha` is
  non-empty **OR** we originated it (counter > 0). Used as "what WE have" in
  `indexDiff`. *A freshly-received-but-not-fetched peer row has `localSha == ''`
  and no local counter, so it's correctly excluded — indexDiff then needs it.*
- **`localLivePaths(deviceId)`** — the path set the scanner's **tombstone
  detector** diffs against. Same predicate as `localSnapshot` (originated **OR**
  localSha-confirmed). See §6.3 for why the `localSha` branch is there.

### 5.3 Key write operations

- **`upsertLocal`** — scanner's local observation. No-op guard: if size+mtime+sha
  (+blocks) all match the prior row, it writes nothing and burns no sequence. This
  is the no-op invariant's enforcement point.
- **`confirmLocalObservation(relPath, sha)`** — engine's post-fetch step. Stamps
  `localSha = sha` **without bumping version or sequence** (the authoritative sha
  already matches; we just verified it). This is what moves a fetched file from
  "unconfirmed" to "we have these bytes."
- **`applyRemote(entry)`** — merge an inbound peer row. **A fresh row (no prior on
  this device) is forced to `localSha = ''`** (an unfetched file must never look
  confirmed). For a row we already had, `priorLocalSha` is preserved across the
  peer's content update.
- **`markDeletedLocal`** — scanner's tombstone: bumps our counter + sets
  `deleted = 1`. Never a row removal — a delete is just a version-bumped entry
  with the deleted flag, so version-vector dominance can propagate it.

---

## 6. How ordering, fetch, and deletes actually work

### 6.1 Ordering — version vectors are the sole authority

`version_vector.dart`. A `VersionVector` is `{deviceId → counter}`.

- **Bump:** on a local change, only **OUR** counter increments (+1).
- **Merge:** per-device **max** (idempotent, commutative).
- **`a > b` (dominates):** `a ≥ b` everywhere and `≠`. This is "a is newer."
- **Concurrent:** neither dominates → **conflict** → loser to `.syncversions`.

**Critical rule (the edit-reversion fix):** sha is reduced to a **content**
comparison only — it answers "are the bytes the same," *never* "which is newer."
When both sides have a live file with a sha mismatch, the version vector decides
(see `index_diff.dart` doc + `indexDiff`):

```
my version ≥ peer's  → SKIP (never revert a local edit)
peer strictly newer  → fetch
concurrent / conflict→ fetch (Phase 4 will move loser to .syncversions)
```

**No mtime comparison anywhere.** The legacy mtime tiebreaker was the race the
redesign removed.

### 6.2 Fetch — block-level, resumable, terminal-error-safe

`block_transfer.dart`. `fetchFileBlockLevel`:

1. Plan blocks: `ceil(size / 1MiB)` at offsets 0, B, 2B, … each with an expected
   sha from `blockHashes` (when the peer supplied them).
2. **Resume:** if `.<name>.syncpart` exists with a verified prefix of blocks, skip
   the blocks already present → survives a mid-download reconnect.
3. Per outstanding block: send `request`, verify block sha, write at offset.
4. All blocks filled → whole-file SHA-256 == `expectedSha`? → **atomic rename**
   `.<name>.syncpart` → final name. Else throw (corrupt `.syncpart` left for retry).

**Terminal errors:** a `response` with an `error` field throws
`TerminalFetchError`. The engine's needs-queue catches it and **drops the file
without retry**. This is the fix for flaw #2 — the whole-file fetch loop that
retried a vanished source file every ~4s forever. The next `IndexUpdate` re-adds
the file if it reappears.

### 6.3 Deletes — tombstones, dominance, and the two bugs it took to get right

A local delete = the scanner notices a tracked file is gone from disk →
`markDeletedLocal` → a tombstone row (bumped counter, `deleted = 1`). The tombstone
propagates via normal `IndexUpdate`; the receiver's `_applyRemoteTombstone`
decides **delete-vs-edit at receive time**:

| Inbound tombstone vs our live version | Decision (`DeleteDecision`) |
|---|---|
| Tombstone version dominates-or-equals ours | `deleteWins` — bytes removed, store tombstone |
| Our live edit is concurrent / newer | `editWins` — bytes KEPT, do not store `deleted=1` (a later sweep would delete our edit) |
| We never had the file | `nothingToDecide` — store the tombstone as-is |

This dominance check must run **before** `applyRemote` merges the peer's delete
counter into our row (after the merge, dominance would no longer be clean). See
`_applyRemoteTombstone` + the `DeleteDecision` enum.

**Bug #6 (delete didn't sync to peer):** fixed by the Phase 4 delete-to-disk path
above. `delete_propagation_test.dart` pins it (authoritative tombstone removes
file; concurrent edit wins; resurrection re-fetches).

**Bug #9 (received-file delete didn't propagate):** the **tombstone detector's**
`localLivePaths` predicate originally admitted only files WE originated (counter
> 0). But a file we *received and fetched* is confirmed via
`confirmLocalObservation`, which stamps `localSha` **without** bumping our counter
— so every received file was excluded from tombstone detection. Delete a received
file on disk and the scanner never compared it → no tombstone → the peer never
learned → permanent divergence. **Fix:** `localLivePaths` now also admits any row
with `localSha.isNotEmpty` (originated **OR** confirmed). Pinned by
`bug9_recv_delete_propagation_test.dart` (positive: received-then-deleted →
tombstoned; negative: never-fetched peer row → never tombstoned, the delete-storm
guard). Safety: `localSha` never crosses the wire, so an unfetched peer row always
has `localSha == ''` and can never be falsely tombstoned.

---

## 7. Networking & security

### 7.1 Discovery + connection (the net layer)

- **UDP broadcast auto-discovery** (`discovery.dart`) — beacons carry public
  identity only. Reaches a paired peer anywhere on the LAN.
- **QR fallback** — for networks that block device-to-device traffic (guest Wi-Fi,
  client isolation).
- **`PeerConnectionRegistry`** — THE single source of truth for "which session is
  live for peer X." Replaced an older mutable field that disagreed with `AppState`
  and got clobbered by reconnect churn.
- **`ConnectionSupervisor`** — beacon-independent reconnect policy. Every 5s it
  sweeps paired peers with no live session and redials the last-known address,
  with **exponential backoff per peer** (so an offline peer isn't hammered; a
  returning peer reconnects within ≤5s). Closes the gap where reconnect depended
  on a lucky beacon or a 36s heartbeat timeout.
- **`FrameCodec`** (`secure_frame.dart`) — `[4-byte BE length][UTF-8 JSON]`
  envelopes. Deliberately **single-owner** (`onMessage` callback, not a broadcast
  stream) to structurally eliminate the silent-drop failure mode (a broadcast
  stream has no buffer → a message arriving with no listener is lost).

### 7.2 Security model

| Layer | Mechanism |
|---|---|
| Transport | Self-signed TLS (when an openssl cert is available); otherwise plaintext framing |
| Identity | Persistent **ed25519** keypair; `deviceId = first 8 hex of sha256(pubKey)` |
| Pinning | Peer pubkeys pinned in `config.json` on first successful pair |
| First-pair auth | Single-use 6-digit code (embedded in the QR for scan flow); **consumed on success** |
| Returning peer | PubKey checked against the pin — **no code needed**, hence cross-network works |
| Privacy | No file bytes leave the LAN; beacons carry public identity only |

No all-files-access permission on Android — all file I/O goes through the
**Storage Access Framework** (`platform/saf_access.dart` + Kotlin `SafOps.kt`).

---

## 8. Platform notes

- **Windows:** `%APPDATA%\Conduit\` for identity/config. Listens on **TCP 41828**
  — a one-time firewall rule is required (see README "First-run setup"). Native FS
  via `dart:io`.
- **Android:** app support dir for identity/config. SAF document trees for folder
  access. `SyncService` foreground service with a partial wake lock (10-min cap) so
  an in-flight transfer completes before doze. Permissions: INTERNET, WIFI state,
  multicast, FOREGROUND_SERVICE(dataSync), WAKE_LOCK. **No** all-files access.
- **Per synced folder:** `.syncstate/` (legacy manifests), `.syncversions/`
  (conflict backups, 14-day retention), `.<name>.syncpart` (V2 partial downloads).

---

## 9. The hardening that makes sync reliable

This is the heart of this document: **what has already been battle-tested and
hardened, so a new agent doesn't reinvent it or accidentally regress it.** Each
item maps to a regression test (Appendix A).

### 9.1 Architectural hardening (prevents whole classes of bugs)

1. **Durable Index DB, not a rebuilt manifest.** The vanish window (PC snapshots
   the file list at scan time T; phone fetches at T+1s; the file is gone) is
   eliminated — the DB is the durable source of truth across reconnects.
2. **Version vectors, not mtime.** Ordering is monotonic and provenance-bearing.
   No mtime race, no "last synced" snapshot to lose.
3. **Block-level transfer + terminal errors.** A vanished source file produces ONE
   terminal error and is dropped — never a retry loop. Transfers resume from the
   last verified block.
4. **Scanner decoupled from sync.** The watcher/scanner writes rows independently;
   a sync failure doesn't lose filesystem observations.
5. **Dumb, persistent connection.** The session just delivers frames; reconnect =
   "send me anything past my last sequence." No generation guards in the sync path.
6. **Single-owner frame codec.** No silent message drops (structural, not by timing).
7. **Beacon-independent reconnect supervisor.** Recovery doesn't depend on a lucky
   UDP packet; exponential backoff prevents peer-hammering.

### 9.2 Logic hardening (specific bugs fixed and pinned)

| Bug | Symptom | Root cause | Fix & guard |
|---|---|---|---|
| **#6 / delete-to-disk** | Deletes didn't sync to the peer | Phase 2 dropped tombstones; never removed bytes | Receive-time delete-vs-edit decision (`_applyRemoteTombstone`); `delete_propagation_test.dart` |
| **#7** | (paired with #6) | concurrent-edit edge | dominance check **before** merge; editWins keeps bytes |
| **#8 / re-fetch loop** | Fetched files re-fetched every reconcile → perpetual loop, WAL churn | `localSnapshot` used the origin counter only; a fetched file (no local counter) was excluded → always a need | `localSnapshot` admits `localSha`-confirmed rows; `bug8_refetch_loop_test.dart` |
| **#9 / recv-delete propagation** | Deleting a *received* file didn't propagate | `localLivePaths` (tombstone detector) used origin counter only; fetched files excluded from delete tracking | `localLivePaths` admits `localSha`-confirmed rows; `bug9_recv_delete_propagation_test.dart` (+ delete-storm negative control) |
| **smoke #3 / edit reversion** | A freshly-advertised stale peer copy reverted a higher-version local edit | sha was used as the ordering authority | sha is content-only; version vector is sole ordering authority; `mineDiskSha = localSha` for convergence; `smoke3_revert_test.dart`, `smoke3_twodb_cycle_test.dart` |
| **SAF duplicate write** | Double-write on Android | (Fix 4) | `HANDOFF_2026-06-24_FIX4_SAF_DUPLICATE_WRITE.md` |

**The `localSha` invariant — the single most important correctness property:**

> `localSha` is the sha of the bytes THIS device last confirmed on its OWN disk.
> It is DB-local only (never serialized on the wire). It is the **disk truth** that
> distinguishes a genuine local edit from stale disk after a peer merge, AND the
> **confirmation witness** that a fetched file is now ours. If you touch anything in
> `index_db.dart`, `index_diff.dart`, or the scanner, re-verify these three:
>
> 1. An unfetched peer row has `localSha == ''` (applyRemote forces it).
> 2. A fetched file gets `localSha` via `confirmLocalObservation` (no seq bump).
> 3. `localSnapshot` and `localLivePaths` both admit `localSha`-confirmed rows.

If any of those three breaks, you reintroduce #8 and/or #9.

### 9.3 Why there is no delete-storm risk

`localSha` never crosses the wire (`toJson` strips it). So a freshly-received,
unfetched peer row **always** has `localSha == ''` and stays excluded from
`localLivePaths` — it can never be falsely tombstoned. The only rows the
`localSha` branch newly admits to deletion-tracking are rows whose bytes this
device genuinely holds (via `confirmLocalObservation`). The negative-control test
in `bug9_recv_delete_propagation_test.dart` pins this.

---

## 10. Testing

- **`flutter analyze lib test`** — 0 errors; a few pre-existing infos/warnings
  (unchanged by recent work).
- **`flutter test`** — 154/154 passing.
- Tests are **deterministic and logic-only**: they use real `IndexDb`s (SQLite via
  `sqflite_common_ffi`) and the real scanner/diff/block-transfer code paths. No
  hardware, no SAF, no sockets. This is why the V2 bugs were caught and fixed
  without a device — the logic is pure and fully testable in isolation.
- Each fixed bug has a dedicated regression test (see Appendix A) with an
  extensive header explaining the bug, the fix, and the safety argument.

**The hardware test is the final gate, not the first.** The pattern this project
has settled into: reproduce in a logic test → fix → add regression test → rebuild
both binaries → hardware confirmation. (See Appendix B.)

---

## 11. Build & deploy

```bash
cd conduit
flutter doctor        # toolchain check
flutter analyze       # 0 errors expected
flutter test          # 154/154 expected

# Windows (profile mode keeps the Diag log; release strips it)
flutter build windows --profile
# → build\windows\x64\runner\Profile\conduit.exe

# Android
flutter build apk --profile
# → build\app\outputs\flutter-apk\app-profile.apk
```

Profile builds keep the `Diag` structured log (profile-gated) — essential for diagnosing hardware behavior. The Release exe strips it. **Always rebuild BOTH targets** after a sync-logic change.

No DB migration is ever needed for the index DB: every fix so far has been runtime-logic-only. Existing rows are correct as-is; the new predicate simply classifies them correctly on the next reconcile.

---

## Appendix A — Test catalog (what each test guards)

| File | Guards |
|---|---|
| `bug9_recv_delete_propagation_test.dart` | Bug #9: received-file delete propagates (+ delete-storm negative control) |
| `bug8_refetch_loop_test.dart` | Bug #8: a fetched file is not a perpetual need (+ negative control) |
| `delete_propagation_test.dart` | Bug #6/#7: authoritative tombstone removes file; concurrent edit wins; resurrection re-fetches; orphan-backlog sweep |
| `smoke3_revert_test.dart` | smoke #3: indexDiff never reverts a higher-version local edit; idle scans burn no sequence |
| `smoke3_twodb_cycle_test.dart` | two-way edit cycle survives reconcile (convergence via localSha) |
| `engine_v2_test.dart` | reconcile phases: no-peer seed, advertise, index exchange, empty-update no-kick, session-lost clear, unknown-pair error |
| `block_transfer_test.dart` | single/multi-block fetch, verify, resume from `.syncpart` |
| `index_db_test.dart` | open/schema, upsertLocal no-op guard, snapshot methods |
| `index_diff_test.dart` | needs-queue cases |
| `scanner_test.dart` | first-scan records changes |
| `version_vector_test.dart` | bump/merge/dominates/concurrent/serialization |
| `watcher_test.dart` | debounced change signal |
| `recent_msg_ids_test.dart` | dedup |
| `file_send_test.dart` | AdHocFileSend: sender offer & serving blocks, receiver auto-fetch & write to disk, session-lost cancellation |
| `widget_test.dart` | app smoke (builds + Overview) |

---

## Appendix B — Change log

| Date | Change |
|---|---|
| 2026-06-21 | v1 design spec (`docs/2026-06-21-conduit-design.md`) |
| 2026-06-23 | V2 redesign approved (`REDESIGN.md`); phased, feature-flagged rollout |
| 2026-06-24 | Bug #6/#7 delete propagation + delete-to-disk; Bug #8 re-fetch loop; smoke #3 edit reversion; SAF duplicate write; **Bug #9** received-file delete propagation (this document) |
| 2026-06-25 | **Roadmap Phase 0 + Phase 1 — additive wiring only, engine untouched.** 0.1 periodic reconcile safety-net (`Map<String,Timer>` in `engine.dart`, no-op-invariant pinned by `phase0_reliability_test.dart`); 0.2 watcher backoff when no peer (`FolderWatcher.setInterval` + engine connect/disconnect hooks, 4s↔30s); 0.3 discovery beacon backoff when stable (`Discovery.setBeaconMode`, 3s↔15s, driven by session liveness in `app_state.dart`); 0.4 transfer-tied wake lock (`SyncEngine.onTransferState` → method channel → `MainActivity` wake lock, ref-counted 0↔1 transitions); 0.5 DB hardening (`PRAGMA synchronous=NORMAL` in `onConfigure`, `integrity_check` on open, hourly `IndexDb.backup()` to `.bak`). Phase 1: Windows close-to-tray + system tray (`lib/src/desktop/tray.dart`, `window_manager`+`tray_manager`) with intentional **Quit**; Android foreground-service start/stop + battery-optimization prompt + transfer wake lock via new `conduit/sync_service` & `conduit/wakelock` channels; `BootReceiver` + `onTaskRemoved` restart; in-app Survival screen (`lib/src/desktop/background_survival_screen.dart`) with OEM battery/autostart guidance. Tests 117/117; the three `localSha` invariants in §9.2 are unchanged. See `HANDOFF_2026-06-25_PHASE0_PHASE1.md`. |
| 2026-06-26 | Windows tray hardening: tray icon left-click now restores/focuses the app, right-click explicitly opens the context menu, and all Windows Quit paths route through a shared tray teardown + bounded graceful shutdown before `exit(0)` so the tray icon/process do not linger. |
| 2026-06-27 | **Roadmap Phase 2 — clipboard sync. Additive, engine untouched.** New `Msg.clipboardPush` in `wire.dart` (no pairId, no msgId — clipboard is device-wide and re-applying is a harmless no-op). One new `onClipboardPush` constructor callback + one **appended** `case Msg.clipboardPush` in `_handlePeerMessage` (subject to the gen guard, NOT in the bypass list — a stale session's clipboard is dropped). New `lib/src/clipboard/clipboard_sync.dart`: pure `ClipboardController` (echo-loop guard — `lastHandledHash` + 800ms suppress window after a local write, so the PC never echoes a value it just received; unit-tested with an injectable clock) and `ClipboardSync` (PC auto-watcher 1.5s poll, Android foreground copy-detection 1s poll, manual `sendCurrentClipboard`, broadcast to paired open sessions only; read/write seams are injectable for tests). PC→phone automatic, phone→PC manual via a QuickShare-style floating chip (`lib/src/ui/clipboard_chip.dart`) that arms only while foregrounded (Android 10+ background-clipboard rule honored). Off by default (`clipboardSyncEnabled` flag in `config_store.dart`); never logs clipboard contents (content-free `SyncEvent`). New `lib/src/ui/clipboard_screen.dart` + Clipboard nav dest. Tests 129/129 (12 new in `clipboard_sync_test.dart`); the three `localSha` invariants in §9.2 are unchanged. See `HANDOFF_2026-06-27_PHASE2.md`. |
| 2026-06-27 | **Roadmap Phase 3 — ad-hoc file send + notifications + folder badges. Additive, engine untouched.** Upgraded `flutter_local_notifications` to `^19.5.0` (with `flutter_local_notifications_windows` 1.0.3) for SDK 3.6.0 compatibility. Added `fileOffer`, `fileOfferBlock`, `fileOfferData` message types to `wire.dart` (no-ack handshake). Added `lib/src/sync/file_send.dart` (`AdHocFileSend`) implementing sender block serving and receiver auto-fetch logic, fully decoupled from the Index DB or any sync loop/needs-queue. Added `lib/src/notifications/notifier.dart` (`AppNotifier`) system notifications wrapper. Added `lib/src/ui/send_panel.dart` (Send tab) for picking connected peer and selecting a file to transfer. Added `receivedFilesPath` settings to config/Overview. Added `_SyncBadge` custom widget to `folder_pairs_screen.dart` with status micro-animations. Tests 132/132 (3 new in `file_send_test.dart`); sync correctness unchanged. |
| 2026-07-06 | Hardened clipboard sync: immediate sync on connection ready event + transactional push marking (only mark as pushed when broadcast succeeds, preventing stale hash lockout during connection drops/inactivity). Added 3 new unit tests in `clipboard_sync_test.dart` (total 146/146 tests passing). |
| 2026-07-07 | Restored V2 as the production folder-sync path for existing installs by migrating useNewEngine to true on config load and defaulting missing test configs to V2. Fixed the Folders screen's manual Sync now action so it reconciles with the current ready peer session instead of forcing a local-only 
ull session. Added config_store_test.dart; full suite 154/154 passing. |

| 2026-07-08 | Documentation: verified the suite via `flutter test` (154/154 passing, 0 errors) and corrected stale test-count claims to match current code. `ARCHITECTURE.md` header / §11 / module-map and `Roadmap.md` "current state" counts updated from 112/112 and 146/146 to 154/154; the Roadmap current-state snapshot date advanced to 2026-07-07. No source changes. |
| 2026-07-09 | **Ad-hoc send throughput + compact send widget** (see `docs/2026-07-05-send-widget-and-throughput.md` for full design). `TCP_NODELAY` set best-effort on both connect and accept paths in `peer_session.dart`. `fetchFileBlockLevel` (`block_transfer.dart`) gained an optional `pipelineDepth` param (sliding-window request pipelining; default 1 = byte-for-byte original stop-and-wait); `file_send.dart` uses depth 8 for ad-hoc receives. New compact popup send flow on Windows (`send_widget_screen.dart`, `send_flow_view.dart`, `AppState.sendWidgetMode`, `tray.dart`'s `suppressWindowBoundsPersistence`) reshapes the single existing window instead of opening a second native one. **Also present in this snapshot, not covered by that doc:** `engine.dart` now sets `_syncPipelineDepth = 4` and passes it to the V2 needs-queue's own `fetchFileBlockLevel` call (previously depth 1 / omitted, per the doc's "left alone here deliberately" note) — i.e. the background sync engine's own block fetch is now pipelined too, not just ad-hoc sends. Reviewed by inspection: `_sendBlockRequest` + `_BlockSink` (`engine.dart`) run `session.send(frame)` and enqueue the matching `_waiters`/`_queue` slot synchronously (before any `await`) on every call, so firing several requests before awaiting any of them still preserves strict FIFO request/response order — the same guarantee `block_transfer_test.dart`'s depth-3/4 tests check against a fake `sendRequest`. No `localSha`/version-vector path touched; only wire scheduling. **Gap:** no test currently drives the *real* engine needs-queue end-to-end at depth 4 (existing pipelining tests exercise the primitive directly with a fake `sendRequest`) — recommend adding one before relying on this further. Tests: `block_transfer_test.dart` pipelining tests present; full-suite count not independently re-verified this session (no `flutter` toolchain available in the reviewing environment — see `PROGRESS.md`). |

---

*If anything in this document contradicts the source, **the source is right** —
fix the document and append a change-log entry.*
