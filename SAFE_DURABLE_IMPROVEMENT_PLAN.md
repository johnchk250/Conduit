# Conduit Safe and Durable Improvement Plan

Status: Proposed replacement for `implementation_plan.md`

Date reviewed: 2026-08-22

Scope: Conduit codebase snapshot supplied with this review.

## 1. Goal

Improve Conduit's long-running synchronization reliability, Android durability, transfer efficiency, and protocol maintainability without weakening the synchronization invariants that already protect data integrity.

This plan is intentionally conservative. It separates low-risk reliability work from protocol migrations. It does not treat a performance idea as a correctness fix, and it does not remove causal state merely to reduce storage use.

The governing rule is:

> Preserve correctness first. Add performance and protocol features only behind explicit compatibility boundaries and with rollback-safe storage/wire formats.

## 2. Current codebase facts this plan preserves

The current repository already contains several mechanisms that the older plan proposed adding. They should be extended, not duplicated.

- `SafFileSystemAccess.listFilesWithStat()` already performs one MethodChannel call for a recursive SAF metadata scan.
- `SafOps.listRecursiveWithStat()` already uses `DocumentsContract` and one provider query per directory.
- SAF operations already run on a serialized Android I/O executor rather than the Android UI thread.
- Android SAF watching is provider-event-led, with a long fallback reconcile interval to avoid repeated expensive tree scans.
- Desktop/local filesystems already have a 30-minute periodic reconcile safety net.
- LAN discovery already includes saved-route probing, directed broadcast/multicast, and a bounded private-subnet sweep.
- LAN already has higher transport priority than Bluetooth.
- Duplicate-session arbitration already uses deterministic device-ID ownership.
- `PeerConnectionRegistry` already rejects stale teardown by identity/generation instead of requiring a second locking abstraction.
- Secure Transport v1 already derives fresh X25519/HKDF session material and uses a monotonically increasing 64-bit sequence in each direction for ChaCha20-Poly1305 nonces.
- File transfer already uses verified 1 MiB blocks, resumable partial files, and SHA-256 validation.
- Tombstones are deliberately retained as causal delete records. Their dead block-hash payload can already be compacted without deleting the tombstone row.

## 3. Non-negotiable correctness invariants

These are taken directly from the repository architecture and must remain true after every phase.

1. Version vectors, not hashes or timestamps, order synchronized changes.
2. `localSha` represents confirmed local disk truth; remote metadata is not proof that bytes exist locally.
3. Deletes remain versioned tombstones, not ordinary row deletion.
4. Remote metadata does not become local possession until bytes are verified on disk.
5. Restore writes bytes; the scanner creates the next live version through the normal path.
6. Wire changes remain additive unless there is an explicit protocol version bump.
7. An old or late session callback must never evict or mutate the state of a replacement session.
8. A transport optimization must not alter version-vector decisions, delete behavior, or final file verification.
9. Android background changes must not silently bypass platform restrictions or convert durable user-visible work into unreliable background execution.
10. Any new persistent format must be readable by the version that created it after process restart and must have a defined downgrade/fallback behavior.

A change that cannot preserve these invariants does not belong in a normal improvement release.

## 4. Delivery strategy

Implement this plan in four release tracks, in order:

- Track A: reliability fixes with no wire or database semantic change.
- Track B: Android/platform hardening and diagnostics.
- Track C: safe performance work proven by measurements.
- Track D: optional protocol projects, each independently negotiated and migration-tested.

Do not combine Track D protocol work with the first reliability release.

---

# Track A - Reliability fixes with no protocol change

## A1. Make reconcile requests durable while a reconcile is already running

### Problem

`SyncEngine.reconcile()` has a per-pair `st.scanning` guard. Today it preserves a reconnect trigger when a replacement session arrives while an old reconcile is unwinding, but same-session triggers are generally dropped while `st.scanning` is true.

That is safe for redundant hints, but it is not safe to assume every same-session hint is redundant. A local filesystem change can occur after the active scan has already passed the changed path. If its watcher hint arrives during the active reconcile and is discarded, correctness depends on a later watcher/poll/reconnect event.

### Change

Introduce one central reconcile request path rather than letting event sources call `reconcile()` directly.

Suggested shape:

```text
requestReconcile(pair, session, reason)
    if pair is idle:
        start reconcile
    else if reason can represent new state:
        mark one pending reconcile for the pair
    else:
        coalesce as redundant
```

Use a small reason enum or equivalent typed value, for example:

- `initialSeed`
- `localChange`
- `peerIndexChanged`
- `peerConnected`
- `replacementSession`
- `manual`
- `periodicSafetyNet`

Required behavior:

- `localChange`, `peerIndexChanged`, `replacementSession`, and `manual` must be able to queue one follow-up pass.
- `periodicSafetyNet` should not create an endless second pass if a reconcile is already running and no new state is known.
- Multiple pending hints coalesce to one pending pass per pair.
- The pending state must survive the `finally` section of the active reconcile and be drained only after `st.scanning` is cleared.
- Resolve the current live session from `PeerConnectionRegistry` when the queued pass actually starts. Do not retain an obsolete socket as authority.
- If the peer is no longer connected, retain correctness through the normal reconnect path rather than spinning locally.
- If hints continue arriving during the follow-up pass, allow one more pending pass. Do not use an unbounded synchronous loop; schedule the next pass through the event queue/debounce path.

### Files likely affected

- `lib/src/sync/engine.dart`
- `lib/src/sync/watcher.dart` only where it calls into the engine
- focused tests under `test/`

### Tests

Add or extend tests that prove:

1. Local edit A starts reconcile; local edit B occurs after the scanner has passed B; B's hint arrives while `st.scanning == true`; a second reconcile runs and observes B.
2. Ten duplicate watcher hints during one scan produce at most one queued follow-up scan.
3. A replacement session arriving during an old-session reconcile still uses the replacement session after the lock is released.
4. A periodic safety tick during an active reconcile does not cause a permanent reconcile loop.
5. Pause/resume preserves the existing pause contract.
6. Pair removal while a follow-up reconcile is pending does not resurrect work for the removed pair.

### Acceptance criteria

- No wire changes.
- No database schema changes.
- No change to conflict/delete decisions.
- A meaningful trigger cannot be lost solely because a scan is active.

## A2. Recover native filesystem watching after stream failure

### Problem

For local filesystems, `Directory.watch()` errors currently clear `_nativeEvents`, but the watcher does not automatically re-subscribe. The periodic scanner preserves eventual correctness, but event responsiveness remains degraded until the watcher object is recreated.

### Change

Add bounded native watcher recovery inside `FolderWatcher`.

Requirements:

- On native watch error or unexpected stream completion, cancel/clear the old subscription.
- Schedule re-subscription with bounded backoff, for example 2s -> 10s -> 30s maximum.
- Cancel the restart timer in `stop()`.
- Reset backoff after a successful re-subscription.
- Keep the existing poller active while native events are unavailable.
- Never start more than one native watch subscription or retry timer at once.
- Do not apply this retry loop to Android SAF provider observation; SAF already has its own start/stop state and long fallback behavior.

### Tests

Extend `test/watcher_test.dart` with a fake change source or injectable native-watch adapter that can:

- emit an error;
- close unexpectedly;
- recover;
- prove only one replacement subscription is created;
- prove a change after recovery is signaled once.

### Acceptance criteria

- Event latency recovers automatically after transient watcher failure.
- Existing periodic fallback behavior remains unchanged.
- No tight retry loop is possible.

## A3. Expand existing duplicate-session arbitration tests; do not rewrite arbitration

### Problem

The repository already implements deterministic ownership: the lexically smaller device ID owns the outbound connection and the larger ID owns the inbound side of that connection. A new arbitration rule would create contradictory ownership logic.

### Change

Keep the current `_isPreferredSession()` convention and `PeerConnectionRegistry` identity checks. Strengthen tests instead of adding a second algorithm in `peer_session.dart`.

Test matrix:

- A and B dial each other simultaneously over LAN.
- A and B dial each other simultaneously over Bluetooth.
- A LAN connection arrives while a healthy Bluetooth session exists.
- A stale Bluetooth socket closes after LAN replacement.
- Two handshakes complete nearly together in both completion orders.
- A rejected duplicate cannot trigger reconnect churn on the peer.
- A late `socket.done`, heartbeat timeout, or bye from the old generation cannot drop the new generation.

### Acceptance criteria

Exactly one live session per peer after convergence, with LAN preferred over Bluetooth and no oscillation.

## A4. Lock in tombstone safety with regression tests

### Problem

The old plan proposed deleting tombstones after 30 days. The current architecture explicitly relies on tombstones as durable causal state. Deleting them without a causal-GC protocol can resurrect files when a long-offline peer returns.

### Change

Do not delete tombstone rows and do not prune non-zero version-vector device entries in this track.

Keep using the existing safe maintenance operation that removes only dead tombstone block-hash payloads.

Add regression tests for:

- peer offline for longer than 30 days, then reconnects with a stale live version;
- tombstone still dominates the stale version;
- compacted tombstone with `block_hashes == NULL` behaves identically to an uncompacted tombstone;
- concurrent edit-vs-delete retains the existing deterministic behavior;
- database reopen/restart preserves the causal decision.

### Acceptance criteria

No code path performs age-only tombstone row deletion.

---

# Track B - Android and network hardening

## B1. Keep `connectedDevice` as the Android foreground-service type

### Decision

Do not change the persistent `SyncService` to `dataSync|connectedDevice` merely because file transfer occurs.

The current service is a persistent peer-connectivity service over LAN/Bluetooth and already declares:

- `FOREGROUND_SERVICE`
- `FOREGROUND_SERVICE_CONNECTED_DEVICE`
- `android:foregroundServiceType="connectedDevice"`

This matches the platform's connected-device category and avoids Android 15's `dataSync` six-hour-per-24-hour background timeout.

It also preserves the current boot-restoration design. Android 15 forbids `BOOT_COMPLETED` receivers from launching a `dataSync` foreground service; `connectedDevice` is not in that Android 15 forbidden list.

### Change

- Keep the manifest and `startForeground()` type aligned on `connectedDevice`.
- Add an instrumentation/manual test that verifies service startup on API 34, 35, 36, and 37 test devices/emulators as those SDKs are supported by the build environment.
- Log foreground-service startup failures with actionable reason codes; do not silently fall back to an invisible long-running background service.
- Keep wake locks scoped to connection setup and active transfer, matching the existing architecture.

### Android references

- Foreground service types: https://developer.android.com/develop/background-work/services/fgs/service-types
- Android 15 behavior changes: https://developer.android.com/about/versions/15/behavior-changes-15
- Foreground service timeout behavior: https://developer.android.com/develop/background-work/services/fgs/timeout

## B2. Add Android 17 local-network permission readiness before targetSdk 37

### Problem

Android 17 / API 37 introduces the dangerous runtime permission `ACCESS_LOCAL_NETWORK` for apps targeting API 37+ that directly discover/connect to devices on the LAN. Conduit uses raw TCP plus UDP multicast/broadcast/unicast discovery, so this affects core LAN behavior when the app moves to targetSdk 37.

### Change

Implement this only as part of the targetSdk 37 migration, not as an unconditional change to older targets.

Required behavior:

1. Declare `ACCESS_LOCAL_NETWORK` when compiling/targeting the SDK where it is defined.
2. Add a runtime permission flow before enabling LAN discovery/listening on target 37+.
3. If denied:
   - keep the app usable;
   - disable LAN discovery/listening with a clear status;
   - retain Bluetooth/manual capabilities that remain permitted;
   - provide a settings action to grant the permission later.
4. Do not repeatedly prompt after a denial.
5. Treat permission revocation while running as a recoverable network-state change.
6. Add the permission state to Connection Doctor diagnostics.

### Tests

- First launch on target 37: permission not granted -> LAN path remains disabled without crash.
- Grant -> discovery/listener starts.
- Deny -> no retry loop and no misleading "AP isolation" diagnosis.
- Revoke in settings -> existing LAN session failure is handled as an expected permission/network loss.
- Bluetooth fallback remains available when separately permitted.

### Android reference

- Android 17 behavior changes: https://developer.android.com/about/versions/17/behavior-changes-17
- `ACCESS_LOCAL_NETWORK`: https://developer.android.com/reference/android/Manifest.permission#ACCESS_LOCAL_NETWORK

## B3. Do not use WorkManager as a fake always-on sync service

### Decision

Do not add a periodic/expedited worker whose purpose is to simulate an always-running peer service.

WorkManager is useful for deferrable, persistent tasks, but periodic work has a minimum repeat interval of 15 minutes and is inexact. Expedited work is for important short one-time work and is quota-limited. Neither is a durable substitute for Conduit's connected-device service semantics.

### Safe uses of WorkManager, if later needed

A worker may be appropriate for bounded maintenance that does not require a peer socket, for example:

- index backup verification;
- transfer-history pruning;
- deferred integrity checks;
- notification cleanup;
- migration/maintenance that can safely run much later.

If used:

- use unique work names;
- make workers idempotent;
- never make correctness depend on exact execution time;
- do not start a second sync engine inside a worker while `SyncService` is active.

### Android reference

- WorkManager task scheduling: https://developer.android.com/develop/background-work/background-tasks/persistent
- Periodic work minimum interval: https://developer.android.com/develop/background-work/background-tasks/persistent/getting-started/define-work

## B4. Improve Connection Doctor without over-claiming AP isolation

### Problem

A same-subnet peer that is unreachable can be caused by client isolation, host firewall, permission denial, stale address, VPN/routing behavior, the app not listening, or other network policy. A failed TCP connect is not proof of AP isolation.

### Change

Report evidence and likely causes instead of declaring a single cause.

Suggested diagnostic states:

- Local network permission missing (Android 17+).
- No active LAN interface.
- Multicast/broadcast discovery unavailable.
- Saved address reachable/unreachable.
- Same-subnet peer advertised but TCP connect failed.
- LAN unavailable; Bluetooth available.
- LAN unavailable; no fallback transport available.

Use wording such as "Local peer traffic may be blocked by AP/client isolation, firewall, or routing policy."

### Constraints

- Keep the existing subnet sweep bounded and cooldown-gated.
- Do not increase probe frequency merely to improve diagnosis.
- Never scan public address space.
- Do not add automatic WAN probing.

---

# Track C - Performance improvements with measurements first

## C1. Benchmark existing SAF scanning before adding another API

### Current implementation

The code already has the intended batch traversal:

- Dart: `SafFileSystemAccess.listFilesWithStat()`
- Kotlin: `SafOps.listRecursiveWithStat()`
- one MethodChannel call for the full tree;
- one `ContentResolver` child query per directory;
- provider I/O executed on the Android I/O executor.

### Change

Add measurement and observability before redesign.

Benchmark at minimum:

- 1,000 files in one directory;
- 10,000 files in one directory if the provider supports it;
- 1,000 files spread across deep directories;
- internal storage provider;
- Files by Google / common OEM document provider where available;
- cold scan and warm scan;
- screen-on and background service conditions.

Record:

- total scan wall time;
- number of files/directories;
- number of provider queries;
- peak returned metadata count/estimated memory;
- time spent hashing separately from metadata enumeration;
- battery/CPU observations for repeated fallback scans.

### Decision gate

Do not add `scanTreeFast()` if it only duplicates `listFilesWithStat()`.

Only introduce a new SAF scan API if profiling demonstrates a concrete bottleneck that the existing API cannot fix locally.

## C2. Optimize repeated SAF block reads only if profiling proves descriptor churn matters

### Current behavior

`readBlock` resolves the document and attempts a seekable descriptor fast path, with a provider-compatible input-stream fallback. All SAF I/O is already off the UI thread.

### Potential optimization

If large-transfer profiling shows repeated resolve/open/close operations are material, add an explicit bounded read-handle API rather than silently caching descriptors forever.

Possible shape:

```text
openReadHandle(treeUri, relPath) -> opaque handle
readHandleBlock(handle, offset, length)
closeReadHandle(handle)
```

Safety requirements:

- opaque integer/string handles only; no raw descriptor crosses MethodChannel;
- maximum number of open handles;
- per-handle inactivity timeout;
- close on transfer completion, cancellation, service teardown, and channel detach;
- invalidate on provider error or permission revocation;
- preserve the stream fallback for providers without seekable descriptors;
- never keep write descriptors open across atomic replace/rename semantics;
- no behavior change to final SHA-256 verification.

### Acceptance criterion

Ship only if measured transfer throughput/CPU improves materially on real SAF providers without increasing leaked-descriptor or stale-provider failures.

## C3. Add performance budgets, not optimistic speed claims

Replace statements such as "20x-30x faster" with measured release gates.

Example gates:

- no regression greater than 10 percent in median scan time on the existing fast path;
- no additional full SAF traversal for one provider event;
- idle SAF pair with peer offline performs no periodic tree traversal;
- transfer memory remains bounded by a documented number of in-flight blocks/frames.

---

# Track D - Optional protocol projects

Each item in this track must be a separate design review and pull request series. None is required to ship Track A or B.

## D1. Safe session key refresh: prefer reconnect before in-band rekey

### Current security property

Secure Transport v1 derives fresh session keys using ephemeral X25519 plus HKDF and uses independent directional nonce prefixes with monotonic 64-bit sequence counters. Sequence exhaustion already fails closed.

### Safer first step

If periodic key refresh is desired, implement graceful session rollover using the existing authenticated handshake rather than mutating keys inside an active frame stream.

Rationale:

- queued sends currently capture the active key object before entering the send chain;
- an in-band key change therefore needs a strict epoch barrier and acknowledgement protocol;
- reconnect already has durable transfer resume behavior;
- a fresh handshake is easier to reason about, test, and roll back.

### Proposed rollout

1. Add observability counters per secure session:
   - frames sent/received;
   - ciphertext bytes sent/received;
   - session age.
2. Do not claim a cryptographic vulnerability at an arbitrary low threshold.
3. Define a product/security policy for optional rollover based on a documented analysis and transfer-resume behavior.
4. Request rollover at a quiescent boundary when possible.
5. If a hard policy limit is reached during continuous traffic, close the session cleanly and rely on normal reconnect/resume.
6. Keep the existing absolute sequence-exhaustion fail-closed check.

### Tests

- rollover during idle;
- rollover between file blocks;
- forced close during a large transfer resumes without corruption;
- stale frames from the old socket cannot reach the new session generation;
- no nonce reuse within any session.

### In-band rekey, if ever added

Treat it as a new protocol capability, not a method on `FrameCodec` alone. It requires:

- explicit key epochs;
- transcript-bound derivation;
- request/ack state machine;
- ordering barrier for queued sends;
- receive-side transition rules;
- replay/duplicate control-frame handling;
- simultaneous-rekey arbitration;
- hard parser/state limits;
- downgrade behavior for peers without the capability.

Do not implement this in the reliability release.

## D2. Content-defined chunking requires a new chunk descriptor format

### Decision

Do not reinterpret the existing `List<String> blockHashes` as variable chunks. The current transfer protocol assumes fixed 1 MiB blocks and request sizes are bounded to that protocol maximum.

### Required design before implementation

Introduce an explicit versioned descriptor, conceptually:

```text
ChunkDescriptor {
    offset
    length
    sha256
}
```

Requirements:

- add `cdc_chunking_v1` only after the new schema is complete;
- capability remains inside the authenticated handshake feature list;
- old peers continue using fixed 1 MiB blocks;
- variable chunk descriptors carry offset and length, not only hashes;
- validate monotonic non-overlapping offsets;
- validate min/max chunk sizes;
- cap chunk count and total descriptor bytes before allocation;
- require descriptor coverage to match the advertised file size;
- final whole-file SHA-256 remains authoritative;
- resume metadata records which protocol/chunk map created the partial file;
- a partial created under one chunking mode must not be misread under another;
- database migration is additive and rollback-safe.

### CDC test properties

Do not require "only 1-2 chunks change" or "100 percent of all later chunks remain identical" for every insertion. That is not a valid universal CDC guarantee.

Test instead:

- deterministic boundaries for a fixed algorithm/version/seed;
- min/max chunk size invariants;
- whole-file coverage with no gaps/overlaps;
- one-byte insertion causes resynchronization and substantial downstream chunk reuse on representative data;
- adversarial/repetitive data remains bounded in CPU, memory, and chunk count;
- old peer fallback remains byte-for-byte correct;
- corrupted descriptor/hash is rejected;
- resumed transfer cannot mix chunking modes.

### Rollout

1. Land descriptor/parser code with feature disabled.
2. Land storage support and migration tests.
3. Land sender/receiver support behind negotiated capability.
4. Run mixed-version two-node tests.
5. Enable only for files above a measured size threshold.
6. Keep a runtime fallback to fixed blocks if negotiation is absent or the CDC path fails before data mutation.

## D3. Causal tombstone garbage collection is a protocol project, not a timer

### Decision

Do not implement `pruneTombstones(Duration age)` and do not prune non-zero version-vector dimensions based only on "active" device IDs.

### Why

Age is not causal knowledge. A peer can remain offline beyond any fixed retention period and later return with stale live state. If the delete record has been removed, the system may no longer be able to prove that the stale version was deleted.

Likewise, dropping a non-zero device dimension from a version vector can change dominance/concurrency relationships.

### What is safe today

- keep tombstone rows indefinitely;
- compact dead tombstone block-hash payloads;
- back up the index;
- report tombstone count/database size as diagnostics;
- optimize indexes/queries without changing causal data.

### Requirements for a future `causal_gc_v1`

A real GC protocol would need, at minimum:

1. Durable peer membership identity, not only currently configured/online peers.
2. A durable per-peer acknowledgement or causal frontier proving each relevant peer has incorporated the delete.
3. A defined device-retirement operation that changes membership intentionally.
4. A rejoin rule for a device/database that was retired before GC.
5. A durable GC watermark/epoch that survives restart and backup restore.
6. Mixed-version behavior for peers that do not understand the GC capability.
7. Tests proving stale backups and long-offline peers cannot resurrect deleted files.
8. A migration/rollback design if GC metadata is corrupted or partially written.

Until all of those exist, keep the tombstone.

## D4. Relay transport is a separate product/security project

### Current product constraint

The repository roadmap explicitly lists hosted relays/remote file storage as not currently planned. The existing system is local-first and already uses LAN plus Bluetooth fallback.

### Decision

Do not add seamless automatic LAN -> Bluetooth -> Internet relay failover as a reliability fix.

If relay becomes a product requirement, write a separate proposal covering:

- rendezvous/discovery model;
- peer authentication and end-to-end encryption;
- whether relay operators can observe device metadata, timing, IPs, sizes, or traffic volume;
- abuse/rate limiting;
- authentication of relay endpoints;
- denial-of-service limits;
- offline queueing policy, if any;
- cost/quotas;
- privacy policy changes;
- manual opt-in vs automatic failover;
- transport abstraction refactor, since current peer sessions own concrete sockets;
- threat-model and security-document updates.

Default must remain local-only unless the user explicitly enables a future relay feature.

---

# 5. Detailed validation plan

## 5.1 Narrow tests during implementation

Run the smallest relevant tests after each focused change.

### Reconcile/watcher work

- `test/watcher_test.dart`
- engine-specific sync tests that cover local change triggers
- `test/two_node_harness_test.dart` where session/index interaction changes

### Connection arbitration

- `test/connection_arbitration_test.dart`
- `test/transport_metadata_test.dart`
- two-node harness tests

### Tombstone/delete safety

- `test/delete_safety_test.dart`
- `test/index_db_test.dart`
- `test/index_diff_test.dart`
- `test/version_vector_test.dart`
- two-node delete/reconnect tests

### Secure transport/session rollover

- `test/secure_transport_test.dart`
- large-transfer resume tests
- stale-generation/session tests

### Chunking, only when D2 is approved

- new CDC unit/property tests
- `test/block_transfer_test.dart`
- mixed-version two-node tests
- malformed descriptor fuzz/property cases

## 5.2 Full pre-release validation

Follow the repository's release requirements:

```text
flutter analyze
flutter test
flutter build windows --release
flutter build apk --release
```

Also run the physical Windows/Android smoke checklist in `docs/windows-android-smoke-checklist.json`.

For changes to session, index, transfer, delete, or restore behavior, the two-node harness is mandatory.

## 5.3 Android device matrix

At minimum test:

- Android 13 baseline where supported;
- Android 14 / API 34 foreground-service type enforcement;
- Android 15 / API 35 background and boot behavior;
- Android 16 / API 36 current behavior;
- Android 17 / API 37 local-network permission behavior before raising targetSdk to 37.

Scenarios:

- app visible -> background -> screen off;
- deep idle/Doze;
- boot completed;
- Wi-Fi lost/restored;
- permission revoke/grant;
- Bluetooth-only fallback;
- OEM battery restriction where a physical device is available;
- active large transfer during network transition;
- process/service kill followed by normal recovery path.

Do not define success as "the process can never be killed." Define success as no corruption, clear status, policy-compliant background operation, and deterministic recovery when the platform allows work again.

---

# 6. Observability requirements

Reliability fixes are hard to validate without knowing why work was scheduled or skipped.

Add structured diagnostics where missing for:

- reconcile requested: pair ID + reason;
- reconcile coalesced because active;
- queued follow-up reconcile started/cancelled;
- native watcher failed/re-subscribed;
- SAF provider watcher active/inactive;
- periodic fallback fired;
- session accepted/rejected/replaced with generation and transport;
- Android foreground-service start result;
- Android local-network permission state on API 37+;
- secure session frame/byte counters at close, without logging keys/nonces/content;
- tombstone compaction count and database size, without logging user filenames unless current diagnostics policy already permits them.

Never log:

- private keys;
- session keys;
- pairing secrets;
- clipboard contents;
- file contents.

Keep diagnostic volume bounded; do not log every transferred block at normal production level.

---

# 7. Rollout and rollback rules

## Reliability changes

- Prefer behavior changes that do not require a database migration.
- Keep the old fallback timers in place while new scheduling logic is proven.
- Feature flags are optional for internal scheduling fixes if the change is fully covered and rollback is simply reverting code.

## Android target changes

- Treat targetSdk raises as explicit compatibility projects.
- Do not raise targetSdk and introduce unrelated sync protocol changes in the same release.
- Test permissions/service startup before release signing.

## Wire changes

For any new negotiated capability:

1. Parser accepts old and new messages safely.
2. Sender uses new behavior only when both peers negotiated it.
3. Unknown capability is ignored rather than treated as proof of support.
4. New messages have strict length/count/value limits.
5. Mixed-version two-node tests pass in both connection directions.
6. Disabling the new feature returns peers to the old safe path.

## Database changes

For any future schema migration:

- migration is transactional;
- keep a tested backup/recovery path;
- do not delete old causal data in the same migration that introduces replacement metadata;
- restart at every migration boundary in tests;
- test a partially completed/failed migration where practical.

---

# 8. Recommended implementation order

## Release 1 - Correctness and resilience

1. Centralize reconcile requests and queue one meaningful follow-up pass.
2. Add native watcher automatic re-subscription with bounded backoff.
3. Expand simultaneous-dial/stale-session arbitration tests without changing the ownership rule.
4. Add long-offline tombstone regression tests and explicitly prevent age-only GC.
5. Improve Connection Doctor evidence wording where needed.
6. Add diagnostics for reconcile reasons and watcher recovery.

Expected risk: low to medium.

No wire change. No database semantic change. No Android service-type change.

## Release 2 - Android compatibility and measured performance

1. Build an Android API-level test matrix.
2. Keep `connectedDevice`; validate boot/background behavior on API 34-37.
3. Add `ACCESS_LOCAL_NETWORK` flow as part of the targetSdk 37 migration.
4. Benchmark existing SAF scan/read behavior.
5. Optimize SAF descriptor reuse only if measurements justify the complexity.
6. Add CI/release automation for the above where practical.

Expected risk: medium, primarily platform/permission UX.

## Release 3 - Optional secure-session rollover

1. Add session counters/telemetry.
2. Define documented rollover policy.
3. Implement reconnect-based key refresh at safe boundaries.
4. Stress-test transfer resume and stale-session isolation.

Expected risk: medium.

No new wire protocol is required if rollover uses the existing handshake.

## Release 4+ - Independent protocol projects

Only after separate design approval:

- `cdc_chunking_v1` with explicit variable-chunk descriptors;
- `causal_gc_v1` with durable acknowledgement/membership semantics;
- an in-band rekey capability with explicit key epochs/barriers;
- relay transport only if the product roadmap and security/privacy model change.

Expected risk: high. Each should ship independently.

---

# 9. Explicitly rejected changes from the old plan

The following should not be implemented as originally proposed:

1. A second SAF "fast tree scan" that duplicates the existing batched traversal.
2. Full desktop reconciliation every 45-60 seconds when event watching plus the existing long safety net is sufficient.
3. A fixed 30-day tombstone row deletion policy.
4. Version-vector pruning based only on currently active device IDs.
5. Reversing the existing deterministic duplicate-session ownership rule.
6. Adding a synchronous lock around `PeerConnectionRegistry` as if normal same-isolate Dart map updates were concurrent shared-memory writes.
7. Declaring `dataSync|connectedDevice` for the always-on Android service without accounting for Android 15 time limits and boot restrictions.
8. Treating periodic/expedited WorkManager jobs as an always-on sync watchdog.
9. Treating failed same-subnet TCP reachability as definitive proof of AP isolation.
10. Adding automatic Internet relay failover as a small networking fix.
11. Reinterpreting fixed `blockHashes` as CDC hashes without offset/length metadata and a protocol/storage migration.
12. Adding in-band key mutation without a queue/epoch barrier and acknowledgement state machine.

---

# 10. Definition of done

This improvement program is successful when:

- meaningful local/peer triggers are not lost during an active reconcile;
- native event watching recovers automatically after transient failure;
- duplicate sessions deterministically converge without churn;
- long-offline peers cannot resurrect files because causal tombstones were aged out;
- Android foreground operation remains compliant without `dataSync` timeout regression;
- targetSdk 37 has a deliberate local-network permission UX before release;
- SAF improvements are backed by measurements rather than duplicate APIs;
- optional protocol features are negotiated, bounded, mixed-version tested, and independently rollbackable;
- full analysis/tests/builds and the physical smoke checklist pass before release.

The guiding principle remains: preserve Conduit's existing synchronization invariants and make each improvement smaller than the failure mode it is intended to fix.
