# Changelog

This file records user-visible and architectural changes to Conduit. The
format follows Keep a Changelog principles and the project uses semantic
versioning for published application releases.

## [Unreleased]

No unreleased changes are currently documented.

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
