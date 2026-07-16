# Conduit roadmap

This file lists current product priorities. Completed work is recorded in
[CHANGELOG.md](CHANGELOG.md); implementation details are in
[ARCHITECTURE.md](ARCHITECTURE.md).

## Current release

Conduit 2.0 delivers the intended local-first Windows/Android application:

- authenticated encrypted LAN and Bluetooth sessions;
- resilient folder synchronization with version vectors and resumable blocks;
- two-way, send-only, and receive-only folder pairs;
- ignore rules, presets, and informational sync preview;
- 14-day version history and peer-deleted-file recovery;
- ad-hoc send and durable transfer receipts;
- clipboard, device status, phone alert, and allowlisted remote actions;
- onboarding, Connection Doctor, responsive UI, and localization scaffolding;
- unit, widget, storage, protocol, and secure two-node tests.

## Next priorities

### 1. Finish state ownership migration

The focused controllers already provide scoped snapshots, but `AppState` still
coordinates and owns several feature services. Move authoritative feature
state behind the controllers incrementally and remove remaining broad UI
subscriptions.

Success means:

- UI screens depend on focused controllers;
- `AppState` becomes a small composition/compatibility layer or is removed;
- transfer, connection, folder, and device-service changes rebuild only their
  consumers;
- lifecycle and disposal remain covered by tests.

### 2. Strengthen release automation

- automate Windows and Android build verification;
- run the full test suite in CI;
- add repeatable signed-release packaging;
- publish checksums and concise release notes;
- automate more of the physical Windows/Android smoke checklist where ADB and
  runner access permit it.

### 3. Complete accessibility and localization

- move remaining user-facing strings into localization resources;
- verify keyboard and screen-reader navigation across every primary flow;
- test high contrast and 200% text scale;
- add one additional translation only after the English catalog stabilizes.

### 4. Improve long-running operations

- expose clearer queued/deferred transfer state;
- add optional bandwidth schedules and rate limits;
- improve very-large-folder preview pagination;
- add storage-pressure warnings for vault and receive destinations.

## Candidate features

These require separate product and protocol decisions:

- approval-before-sync or approval-before-delete mode;
- append-only archive pairs that intentionally do not propagate deletions;
- configurable version-retention policies;
- sync-specific peer confirmation for every folder-synced file;
- encrypted export/import of app configuration;
- desktop auto-update and Android release-channel management.

## Not currently planned

- cloud accounts, hosted relays, or remote file storage;
- arbitrary remote shell execution;
- silently bypassing Android background, clipboard, or storage restrictions;
- claiming recovery for files whose bytes were deleted before Conduit could
  preserve them;
- additional platforms without a tested filesystem, background, discovery,
  and transport design.

## Planning rule

Keep this roadmap short and outcome-oriented. Do not add session notes, code
snippets, completed implementation journals, or dated task plans. Move shipped
behavior to the changelog and architecture reference.
