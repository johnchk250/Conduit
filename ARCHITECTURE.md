# Conduit architecture

This document describes the current Conduit 2.0 runtime. It is the
authoritative technical reference; historical implementation plans and session
logs are intentionally not part of the repository.

## 1. System boundaries

Conduit is a direct peer-to-peer application for Windows and Android.

It owns:

- persistent device identity and peer pins;
- local discovery and authenticated sessions;
- folder indexing, reconciliation, and block transfer;
- Android Storage Access Framework integration;
- local version history and transfer receipts;
- clipboard, device status, phone alerts, and allowlisted remote actions;
- a responsive Flutter interface.

It does not provide:

- accounts, cloud storage, or relay servers;
- internet-based discovery;
- arbitrary remote command execution;
- an append-only backup/archive policy;
- guaranteed recovery of files manually deleted before Conduit can vault them.

## 2. Runtime composition and state

`lib/main.dart` creates one `AppRuntime` and publishes its state through
Provider.

```text
AppRuntime
├── AppState (runtime compatibility facade and service coordinator)
├── AppLifecycleController
├── ConnectionController
├── FolderSyncController
├── TransferController
└── DeviceServicesController
```

`AppRuntime` owns construction and disposal. `AppDependencies` supplies
identity, configuration, support-directory, filesystem, and clock dependencies
so tests can create isolated runtimes.

The controllers expose feature-scoped immutable snapshots and commands:

- lifecycle/startup/onboarding;
- peers and connection status;
- folder pairs, sync state, preview, invitations, and restore;
- pending share input and transfer receipt queries;
- clipboard and remote-service availability.

`AppState` remains the authoritative integration facade for networking,
platform channels, and several mature feature services. New UI should depend
on the narrowest controller available. Direct `AppState` access is transitional
and must not create additional root-level broad rebuilds.

Durable events and transient UI state are separate:

- folder/index truth lives in SQLite and the filesystem;
- transfer history lives in its own SQLite repository;
- configuration and identity live in app-private files;
- controller snapshots are reconstructable views, not persistence.

## 3. Major components

### Networking

`lib/src/net/` contains:

- UDP LAN discovery;
- connection management and duplicate-session arbitration;
- the peer registry and current-session ownership;
- Bluetooth bridge integration;
- transport metadata and LAN preference;
- secure handshake and record framing;
- heartbeat, reconnect, and session generation handling.

There is one published live session per peer. A replacement session must win
the registry arbitration before feature or sync code can use it. Session
generation checks prevent callbacks from a superseded socket changing current
state.

### Protocol

`lib/src/protocol/wire.dart` defines the JSON message vocabulary and shared
folder models. Messages are length-framed, then protected by Secure Transport
v1. Folder synchronization, ad-hoc send, clipboard, status, and remote actions
use distinct message families.

Capabilities are negotiated during the secure hello/welcome exchange. Additive
features such as transfer receipts do not require a protocol-version break;
unsupported peers continue with explicitly reduced semantics.

### Synchronization

`lib/src/sync/` contains:

- filesystem scanner and ignore-rule evaluation;
- version vectors and deterministic conflict ordering;
- pure index-difference calculation;
- per-pair reconciliation;
- resumable block transfer;
- sync preview assembly;
- folder presets;
- version vault catalog and retention.

`SyncEngine` coordinates this layer but does not own platform UI.

### Storage

`lib/src/storage/index_db.dart` provides one SQLite index per folder pair. The
index is the durable synchronization source of truth. It survives process and
connection restarts.

`lib/src/transfers/transfer_receipt.dart` owns a separate
`transfer_history.db`. Receipt writes must never block or invalidate a file
transfer.

### Platform adapters

Windows uses direct filesystem access and native runner integrations.

Android uses:

- persisted SAF tree grants for synchronized and received folders;
- a foreground service for background operation;
- native SAF listing, stat, block read/write, delete, and vault operations;
- Bluetooth and device-status method channels.

Both platforms implement the same `FileSystemAccess` contract.

## 4. Connection lifecycle

1. A device loads or creates its persistent Ed25519 identity.
2. Discovery advertises public local metadata and a listen port.
3. A connection is opened over LAN or the local Bluetooth bridge.
4. First-time peers authenticate with a random, time-limited pairing secret.
5. Existing peers require the stored device ID and public-key pin.
6. Secure Transport v1 derives fresh directional session keys.
7. Encrypted key confirmation completes.
8. The registry publishes one winning session.
9. Heartbeats maintain liveness; reconnect logic replaces dead sessions.
10. A Bluetooth session upgrades to LAN when authenticated LAN reachability
    returns.

LAN and Bluetooth share the same authenticated application session model.
Operating-system Bluetooth pairing only enables the link; it does not
authorize a Conduit peer.

## 5. Secure Transport v1

The transport uses:

- ephemeral X25519 key agreement;
- persistent Ed25519 signatures over a canonical, role-bound transcript;
- HKDF-SHA256 directional keys and nonce prefixes;
- ChaCha20-Poly1305 authenticated records;
- monotonically increasing 64-bit record sequence numbers;
- encrypted key confirmation before session publication.

Modified, replayed, skipped, or out-of-order records close the connection.
Older plaintext builds are rejected.

Discovery remains public to the reachable local network and contains only
connection metadata: device name and ID, platform, public identity key,
protocol version, and listen port.

See [SECURITY.md](SECURITY.md) for the threat model.

## 6. Folder-pair contract

A `FolderPair` contains:

- a shared pair ID;
- local display name and folder path/grant;
- the peer device ID;
- direction: two-way, send-only, or receive-only;
- local ignore globs, ignored extensions, and optional size cap.

The initiating device creates the pair ID and sends it in a folder invitation.
The peer accepts the same ID after choosing its local folder. Independently
creating IDs on both devices does not form a pair.

Pair updates stop the old watcher/engine instance, persist the replacement,
and start a fresh instance. If startup fails, configuration rollback restores
the previous pair.

Ignore rules are local. A newly ignored file is frozen rather than converted
into a deletion tombstone.

## 7. Synchronization model

### Index entries

Each indexed path contains:

- relative path, size, mtime, and authoritative SHA-256;
- version vector;
- monotonic pair sequence;
- tombstone flag;
- block hashes;
- `localSha`, `localSize`, and `localMtime` describing confirmed local disk
  state.

The pair sequence drives incremental index updates. Version vectors, not
timestamps or hashes, are the ordering authority.

### Critical invariants

1. **Version vectors order changes.** A hash compares content; it never decides
   which edit is newer.
2. **`localSha` is disk truth.** The authoritative row may already contain a
   peer's metadata before this device has fetched those bytes.
3. **Deletes are tombstones.** A deletion is a versioned row, not row removal.
4. **Remote metadata is not local possession.** A peer entry is not considered
   locally present until the bytes are verified on disk.
5. **The scanner is the resurrection authority.** Restore writes bytes; the
   next scan creates the new live version through the normal path.

Changes to these invariants require focused regression tests.

### Reconciliation

For each active pair:

1. Retry any authoritative tombstone whose disk cleanup did not complete.
2. Scan the local folder and update the per-pair index.
3. Advertise local rows beyond the peer-specific sent watermark.
4. Request a peer index when no usable peer snapshot exists.
5. Apply incoming entries idempotently.
6. Compute required files with `indexDiff()`.
7. Fetch allowed files in verified blocks.
8. Confirm the final local bytes in the index.
9. publish pair status and schedule future reconciliation.

Reconciliation is triggered by watcher changes, peer connection, incoming index
updates, explicit Sync Now, and a periodic safety net. A pair-level guard
prevents concurrent scans.

### Direction

- `twoWay` permits incoming and outgoing changes.
- `receiveOnly` permits incoming fetches but does not advertise local content
  as an outbound sync source.
- `sendOnly` advertises local content but does not pull peer content.

Direction does not mean permanent backup retention. Tombstones follow the
allowed synchronization direction.

### Conflict ordering

If versions are concurrent, both devices use the same deterministic winner:

1. greater modification time;
2. lexical SHA-256 tie-break when times are equal.

The losing live copy is vaulted before replacement when possible.

### Deletes

When a peer tombstone arrives, the engine compares it with the prior live row:

- a dominating/equal tombstone wins and removes the live path;
- a concurrent local edit wins and remains live;
- an unknown/already-deleted path stores the tombstone without live work.

Before a winning peer deletion removes bytes, Conduit attempts to move the file
to the version vault and record a `peerDelete` entry. A vault failure is
reported but does not rewrite the version-vector decision.

### Block transfer

Files move in 1 MiB blocks. Blocks and final files are verified with SHA-256.
Temporary partial files support reconnection and resumption. A terminal source
error drops that request rather than creating an immediate retry storm.

Transfers above 10 MiB are deferred on Bluetooth.

## 8. Preview, versions, and restore

### Sync preview

Preview captures immutable local and peer inputs and runs the same
`indexDiff()` logic in both directions. It reports receives, sends, conflicts,
local deletion advertisements, byte totals, and Bluetooth deferrals.

Preview is informational:

- automatic reconciliation is not paused;
- a newer scan/index generation marks the result stale;
- an offline cached snapshot is labelled as such;
- no peer snapshot is shown as unavailable, never as "up to date";
- confirmed peer tombstones may already have been applied.

### Version vault

`.syncversions` contains local recovery bytes. The app-support
`vault_log/<pair>.json` catalogs known entries and their reason:

- incoming overwrite;
- conflict replacement;
- peer deletion;
- restore replacement.

Entries and files are retained for 14 days. Cleanup is best-effort and path
validated.

Restore is non-destructive: the selected recovery copy stays until retention
expiry. If a live file exists, it is vaulted first. The restored bytes then
flow through the scanner and ordinary version-vector reconciliation.

## 9. Ad-hoc transfer and receipts

Ad-hoc send is separate from folder indexes. The sender offers a file and the
receiver pulls blocks into its configured receive folder.

Peers advertising `transfer_receipt_v1` send `file_offer_receipt` only after
the receiver has verified and committed the file. The receipt frame carries
the offer ID, bounded result, received byte count, and optional fixed failure
code. It does not carry a file name or path.

Receipt history stores local metadata:

- display name, size, direction, peer, and time;
- ad-hoc or folder-sync kind;
- completion, cancellation, failure, deferral, or interruption;
- receiver-confirmed, locally verified, sender-served, or unsupported-peer
  confirmation.

History is pruned after 30 days and capped at 1,000 rows. Older peers remain
compatible and complete as unconfirmed.

## 10. Auxiliary features

Clipboard synchronization is optional and content is not persisted as history.
Android background clipboard restrictions are surfaced rather than bypassed.

Remote PC actions use a fixed allowlist and are disabled unless enabled by the
user. The protocol does not accept arbitrary commands or shell strings.

Device status publishes bounded battery, charging, storage, and app-health
metadata to an authenticated peer. Phone alert is a fixed action and can be
disabled on the phone.

These features do not enter folder indexes, version vectors, or sync queues.

## 11. Lifecycle and background operation

Windows can remain available through its tray integration.

Android uses a foreground service for durable background operation. Wake locks
are scoped to connection setup or active transfer work and released when idle.
The app does not hold an unconditional process-lifetime wake lock.

Pause prevents new local reconciliation while preserving connection and
protocol correctness. Shutdown cancels timers, watchers, transfers, services,
and sessions before disposing storage.

## 12. Persistence layout

App support directory:

```text
identity.json
config.json
index/<pair-id>.db
vault_log/<pair-id>.json
transfer_history.db
```

Synced folder:

```text
<user files>
.syncversions/    local recovery bytes; excluded from sync
```

On Windows the app support directory is `%APPDATA%\Conduit`. Android uses the
private application support directory.

## 13. Testing

The test suite contains unit, widget, storage, protocol, and two-node tests.
Important groups cover:

- secure handshake, tamper, replay, and pinning;
- version vectors and index differences;
- local disk truth and re-fetch prevention;
- tombstone propagation and concurrent-edit behavior;
- block transfer, resume, and terminal failures;
- vault catalog, retention, peer-delete restore, and resurrection;
- preview reasons, directions, freshness, and totals;
- preset validation and explicit peer selection;
- receipt persistence, pruning, and compatibility;
- duplicate-session arbitration;
- clipboard and remote command behavior;
- app startup smoke behavior.

The two-node harness uses independent identities, state directories, indexes,
folder roots, and real secure loopback sessions.

Before release:

```powershell
flutter analyze
flutter test
flutter build windows --release
flutter build apk --release
```

The physical Windows/Android smoke procedure is stored in
`docs/windows-android-smoke-checklist.json`.

## 14. Change policy

When modifying synchronization:

1. Preserve the critical invariants in section 7.
2. Keep wire changes additive unless a deliberate protocol bump is required.
3. Keep platform errors recoverable and visible.
4. Add the narrow regression test that proves the changed behavior.
5. Run the two-node tests when session, index, transfer, delete, or restore
   behavior changes.
6. Update this document only when the runtime architecture changes.

Release history belongs in [CHANGELOG.md](CHANGELOG.md). Planned work belongs
in [Roadmap.md](Roadmap.md).
