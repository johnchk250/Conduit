# Changelog

This file records user-visible and architectural changes to Conduit. The
format follows Keep a Changelog principles and the project uses semantic
versioning for published application releases.

## [Unreleased]

- Add a Home-screen **Sync all now** action that reconciles every folder pair
  sequentially without enabling connection boost, keeping manual catch-up fast
  while avoiding concurrent Android SAF tree scans.

### Pairing

- Added manual LAN pairing for when UDP discovery is unavailable: enter a
  peer's address directly and complete the same authenticated secure-welcome
  handshake discovery would normally provide.
- Replaced numeric PIN-style manual pairing codes with a two-word,
  pronounceable phrase (five syllables per word) carrying about 66 bits of
  entropy, so it's easy to read aloud/type without weakening the secret.

### Performance and battery

- Reduced Android SAF battery use by making provider notifications the primary
  sync trigger, removing the duplicate periodic reconciliation timer, changing
  the normal recursive fallback scan from 15 minutes to 4 hours, disabling
  fallback scans while a peer is offline, and coalescing chatty provider event
  bursts to at most one follow-up reconcile per 5 minutes. The fallback now
  enters the authoritative reconcile directly instead of first enumerating the
  same SAF tree for a watcher signature. Battery saver uses an 8-hour connected
  fallback; reconnect and manual Sync now still perform immediate catch-up.
- Moved SAF (Storage Access Framework) content-resolver and stream operations
  off the Android UI thread, marshaling only the final reply back to it, to
  reduce jank on large folder trees.
- Replaced the always-on wake-lock/discovery pattern with short, purpose-scoped
  renewable locks (transfers renew every 45s; clipboard/recovery connections
  renew every 10 minutes), each with a timeout safety net in case a crashed
  isolate misses its release call.
- Scoped the Android `MulticastLock` to bounded startup, reconnect, and
  network-transition windows instead of holding it continuously.
- Added an explicit user-triggered "connection boost" mode that clears
  reconnect backoff and re-dials only offline/incomplete sessions, leaving
  healthy sessions untouched.
- Added a slower Bluetooth beacon backoff (3s → 15s → 1m) once a peer has
  been unavailable for a while, instead of polling at a constant fast interval.
- Reworked the Android foreground service and notification channel handling to
  avoid unnecessary restarts and to use a quieter, minimal-interruption channel
  when appropriate.
- Made LAN reconnect logic distinguish DNS-only network changes (ignored) from
  actual interface/address/route changes (which do warrant a reconnect check),
  cutting down on unnecessary reconnect churn.

### Synchronization

- Replaced full periodic SAF folder rescans with event-led watching via
  Android content observers (registered on both the tree and child-documents
  URIs, since providers differ in which one they notify), keeping the old
  full-tree scan only as a long-interval fallback for non-conforming providers.
- Fixed file-transfer progress notifications flooding the Android notification
  channel/UI on fast LAN transfers: updates are now rate-limited (at most
  ~4/second) and serialized per transfer, while still guaranteeing the 0% and
  100% notifications are shown.
- Made `.syncpart` resume verification read the previously-downloaded prefix
  block-by-block from disk instead of loading the whole partial file into
  memory, avoiding a memory/latency spike when resuming a large, mostly-complete
  transfer.
- Isolated per-device sync engine state so that device-level sync/discovery
  handling doesn't cross-affect other paired devices.

### Cross-device tools

- Added a pull-based clipboard refresh: a clipboard-enabled peer can now ask a
  connected peer to (re-)send its current clipboard, closing a gap where
  enabling clipboard sync after the other side had already copied something
  meant waiting for a fresh copy event.
- Centralized the list of capabilities peers advertise during the secure
  hello/welcome handshake so the initiator and responder can't silently drift
  apart on what's supported.

### Android sharing

- Redesigned incoming share-intent delivery to attempt delivery immediately
  and only queue on failure/no-listener, instead of gating all delivery behind
  a one-time "handler ready" signal — the old gate could permanently strand
  queued shares if a cached/headless Flutter engine had already completed that
  handshake before the current Activity existed.
- Added a native→Dart `shareHostAttached` notification sent whenever a new
  Activity attaches to a retained Flutter engine, so Dart re-announces
  readiness to the new channel host and any shares queued by the previous
  Activity instance are still flushed.

### Known follow-ups

- These changes are not yet reflected in a tagged release or version bump.

## [2.0.0] - 2026-07-17

Conduit 2.0 is the first consolidated release documented from the complete
Windows/Android application state.

### Security and pairing

- Replaced plaintext application sessions with Secure Transport v1.
- Added ephemeral X25519 key agreement, Ed25519 transcript authentication,
  HKDF-SHA256 directional keys, and ChaCha20-Poly1305 records.
- Added strict record sequencing and encrypted key confirmation.
- Replaced short pairing codes in QR flows with random 256-bit, single-use,
  time-limited secrets.
- Enforced saved peer identity pins and rejected older plaintext builds.
- Applied the same authenticated session security over LAN and Bluetooth.

### Synchronization

- Made per-folder SQLite indexes the durable source of truth.
- Added version-vector ordering and deterministic conflict resolution.
- Added `localSha` tracking so remote metadata cannot be mistaken for local
  disk possession.
- Added incremental index watermarks and periodic reconciliation.
- Added verified 1 MiB block transfers with interruption recovery.
- Added authoritative tombstone propagation and concurrent-edit protection.
- Fixed received-file deletion propagation, repeated re-fetch, stale edit
  reversion, duplicate-session, and reconnect race conditions.
- Added local ignore globs, extensions, and maximum file size.
- Added two-way, send-only, and receive-only pair directions.

### Preview and setup

- Added freshness-aware sync preview using the same `indexDiff()` decisions as
  actual synchronization.
- Added Camera uploads, Screenshots, Downloads, Documents two-way, Receive
  inbox, and Custom folder presets.
- Unified preset creation through `FolderPairDraft` with explicit peer
  selection.
- Added best-effort Android folder-picker start hints.
- Added versioned onboarding and a Connection Doctor.

### Recovery

- Added local version vaulting before incoming overwrites.
- Added 14-day cleanup of actual vault files and catalog entries.
- Added recovery copies before authoritative peer deletions and tombstone-sweep
  cleanup.
- Added non-destructive Version History restore.
- Restored files re-enter synchronization through the scanner and ordinary
  version-vector resurrection path.
- Added clear-one and clear-all local version history actions.

### Transfers

- Added ad-hoc file send and automatic receive.
- Added streaming Android SAF and Windows file paths without loading large
  files completely into memory.
- Added transfer progress, pause, resume, cancellation, and notifications.
- Added negotiated `transfer_receipt_v1` confirmation after receiver commit.
- Added local SQLite receipt history with 30-day and 1,000-row retention.
- Added truthful confirmed, locally verified, sender-served, unconfirmed,
  deferred, interrupted, cancelled, and failed outcomes.
- Preserved compatibility with peers that do not support receipt confirmation.

### Connectivity and background operation

- Added UDP discovery across changing LAN addresses.
- Added Bluetooth Classic fallback between Windows and Android.
- Added authenticated seamless takeover from Bluetooth to LAN.
- Added heartbeat liveness, reconnect backoff, session generations, and
  duplicate-session arbitration.
- Added bandwidth-aware Bluetooth deferral for files larger than 10 MiB.
- Added Windows tray lifecycle and bounded graceful shutdown.
- Added Android foreground-service lifecycle and scoped wake-lock ownership.

### Cross-device tools

- Added opt-in clipboard synchronization with Android background-safe behavior.
- Added allowlisted remote PC controls.
- Added phone battery, charging, storage, and app-health status.
- Added a fixed phone alert action with a phone-side setting.

### Interface and architecture

- Added a responsive glass-style Windows/Android interface.
- Added Home, Folders, Devices, Remote, and Settings destinations.
- Added device details, folder details, transfer history, version history, and
  preview screens.
- Added bundled fonts and localization scaffolding.
- Added `AppRuntime` dependency composition and feature-scoped controller
  snapshots while retaining `AppState` as a compatibility coordinator.
- Added immutable folder-pair drafts and restart/rollback-safe pair updates.

### Testing and documentation

- Added secure transport, storage, scanner, version, delete, transfer, preview,
  preset, receipt, widget, and two-node integration coverage.
- Added isolated runtime dependencies for tests.
- Added security and privacy policies.
- Consolidated architecture, roadmap, and release documentation.

## Earlier development

Before 2.0, the repository evolved through direct feature commits rather than
formal semantic releases. Those commits established the original Flutter
Windows/Android application, folder synchronization, the glass interface,
Android performance work, drag-and-drop send, device telemetry, Bluetooth
fallback, and LAN upgrade behavior. Git history remains the source for
commit-level detail.
