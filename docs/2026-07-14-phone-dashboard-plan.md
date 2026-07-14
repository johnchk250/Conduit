# Phone Dashboard for Windows — proposal and delivery plan

**Status:** planning only — no implementation is approved by this document.

**Date:** 2026-07-14

**Scope:** a Windows-only dashboard for paired Android phones. It preserves Conduit's LAN-only, no-account, privacy-first model and stays isolated from the folder-sync engine's index, version-vector, and transfer logic.

---

## Product direction

Build a **sync-health dashboard first**, then add a small amount of explicitly shared phone status and one tightly scoped action. Do not begin with a general phone-control surface.

The first release should answer four questions quickly:

1. Is my phone connected, and is the link healthy?
2. Are its folder pairs up to date? If not, what needs attention?
3. Is it charging, and does it have sufficient device storage?
4. Can I send a file or clipboard item to this phone now?

Every remotely reported value must state when it was updated and become visibly stale when the phone is offline.

---

## Source-verified starting point

- The wire protocol has no device-status or reverse phone-action message. Existing device-wide messages, such as clipboard and remote-command handling, are deliberately kept outside folder/index logic.
- The heartbeat calculates RTT in PeerSession, but only logs it. It does not retain an RTT value or history for UI.
- AppState exposes peer connectivity and PairSyncState exposes per-pair status, progress, and lastSyncedAt.
- Peer connection history, transfer receipts, and clipboard history are not persisted today; the Activity data is not a durable dashboard-history store.
- Android sync roots are SAF tree URIs. A general filesystem free-space call cannot reliably report available space for every selected SAF provider or removable volume.
- The desktop navigation rail already has eight destinations. A summary card on Overview is a better first home than a ninth destination.

---

## Priorities

### P0 — dashboard foundation

1. **Phone summary card on Windows Overview**
   - One card per paired Android phone, keyed by deviceId.
   - Connected/offline state, peer name, last connection time, and a distinct stale state.
   - Design for multiple phones from day one, while optimizing the visual layout for the common one-phone case.

2. **Sync-health rollup**
   - List folder pairs assigned to that phone with direction, status, progress, and last successful sync.
   - Surface actionable states: offline peer, paused sync, transfer error, waiting for folder acceptance, and folder-access failure.
   - Do not promise a pending-file count until the engine exposes a durable, meaningful count. The needs queue is not currently dashboard state.

3. **Connection-quality indicator**
   - Retain latest heartbeat RTT, a small bounded recent-sample buffer, and missed-heartbeat count in session/dashboard state.
   - V1 presents Excellent, Good, Spotty, or Reconnecting, plus latest RTT. A sparkline is optional polish: heartbeats can be sparse during normal traffic, so it is not a high-frequency network monitor.

4. **Existing-flow quick actions**
   - Send files opens the current send flow with that phone preselected.
   - Send clipboard calls the existing clipboard path and reports whether it reached a live paired session.
   - Reconnect invokes the current local connection path; it is not a remote phone command.

**Why first:** P0 is useful immediately and requires no Android permission or new protocol message.

### P1 — safe status telemetry

5. **Device Status v1**
   - Battery percentage and charging, full, discharging, or unknown.
   - Device-level available/total storage, labelled *device storage* — never free space in a particular SAF folder.
   - Conduit health: foreground-service state, local battery-saver mode, battery-optimization warning, and safe per-pair error codes such as folder_access_lost. Never include local paths.
   - PC receipt time is the freshness authority; a phone timestamp is optional metadata only because device clocks can differ.

6. **Hybrid sampling and update policy**
   - Send a full snapshot when the paired link becomes ready.
   - Send battery changes after plug/unplug or a meaningful percentage change, with a minimum interval.
   - Refresh storage and Conduit-health fields every 10–15 minutes only while a paired session is live.
   - Stop sampling/sending without a paired connection. Keep the last PC-local snapshot, labelled with its age.

7. **Local retention policy**
   - Persist only low-sensitivity facts on Windows: latest connection events, latest status snapshot, and bounded transfer receipts.
   - Default: retain connection/transfer metadata for 30 days; retain the last status snapshot until replacement or peer removal.
   - Never persist SSID, raw clipboard data, notification content, phone files, or action payloads.

**Why next:** Battery and charging are the highest-value phone-specific data points. Android's battery APIs expose them without a location-style permission.

### P2 — one reverse action

8. **Play phone alert**
   - Use this name rather than Locate my phone: a LAN-only feature cannot locate an offline phone or guarantee it will bypass all silent/DND modes.
   - Phone-side setting Allow play phone alert defaults off.
   - Fixed action only: bundled alert and vibration for 20–30 seconds. Do not accept caller-provided duration, sound, shell command, or intent.
   - Windows sends a request id. Android reports started, disabled, unsupported, offline, or failed.
   - It is available only over the already paired, live TLS session.

**Why later:** it is valuable, but Android audio/vibration behavior varies with silent mode, DND, foreground-service requirements, and device policy.

### P3 — later polish

9. **Transfer receipts**
   - Bounded local history of filename, direction, size, result, peer, and time.
   - Reveal a local destination only when owned by the current device.
   - No thumbnails in V1.

10. **Clipboard activity metadata**
    - Show Clipboard sent to Pixel 2m ago, never the text by default.
    - Raw clipboard history needs a separate explicit privacy/retention decision.

11. **Dedicated Phone dashboard page**
    - Add another desktop navigation destination only if several phones, receipts, diagnostics, and actions make Overview cards too dense.
    - Keep Overview as the at-a-glance entry point.

---

## Out of scope for the first release

- SSID or BSSID display; Android treats these as location-sensitive values.
- RAM, thermal state, screen-on time, and usage statistics.
- DND/ringer manipulation, screen lock, screenshots, or generic phone commands.
- Notification mirroring. It needs Notification Listener access and must be a separate opt-in-per-app product decision.
- Broad phone-file browsing. A later design should start with existing synced folders or an explicit on-phone picker, not unrestricted remote browsing.

---

## Protocol and state design

### Capabilities

Add an optional features list to existing hello and welcome payloads. Older versions ignore unknown fields; new messages are sent only after the peer advertises the corresponding feature.

    device_status_v1
    phone_alert_v1

Absence means unsupported, not an error.

### Messages

    device_status
      { schema: 1, batteryPct?, power?, storageAvailableBytes?,
        storageTotalBytes?, conduitHealth?, pairHealth? }

    phone_action
      { requestId, action: "play_alert" }

    phone_action_result
      { requestId, action: "play_alert",
        result: "started" | "disabled" | "unsupported" | "failed" }

Rules:

- These messages are device-wide: no pairId, index/version-vector work, or sync-engine queue mutation.
- device_status is latest-wins and safely repeatable; it needs no message id.
- Actions use a request id; duplicate ids must be idempotent for a short bounded window.
- Android enforces a fixed allowlist. Never create a generic run-a-phone-command endpoint.
- Do not write full status payloads to diagnostic logs.

### Ownership

Create a small DeviceDashboardState model:

    deviceId
    connectedAt / lastSeenAt / lastDisconnectedAt
    latestRttMs / recentRttMs / missedHeartbeats
    DeviceStatusSnapshot
    bounded transfer receipts
    pendingPhoneActions

AppState owns a map from deviceId to DeviceDashboardState and exposes read-only UI helpers. PeerSession supplies heartbeat measurements. SyncEngine only routes the new messages to dedicated callbacks, mirroring existing clipboard and remote-command routing; it must not interpret them as sync state.

On Android, expose one narrow native status sampler through the existing Flutter/native boundary. Dart owns the sampling policy and sends snapshots through the live peer session. The alert executor must enforce duration and phone-side opt-in itself, not trust Dart alone.

---

## UI plan

### Overview card

    ┌──────────────── Pixel 8 ──────────────── Connected ─┐
    │ Last updated now · Connection: Good (23 ms)           │
    │                                                       │
    │ Sync health                                           │
    │ Photos       Two-way       Up to date · 4m ago        │
    │ Documents    Receive only  Needs attention            │
    │                                                       │
    │ [Send files] [Send clipboard] [Reconnect]            │
    └───────────────────────────────────────────────────────┘

P1 adds battery and device storage under the connection line. When offline, replace live values with an offline banner and Last updated 2h ago.

### States to design and test

- No paired Android phone.
- Paired but never connected.
- Connected with no folder pairs.
- Connected while syncing or while one pair has failed.
- Offline with a stale snapshot.
- Multiple Android phones.
- Older peer without device_status_v1.
- Phone alert disabled, unsupported, rejected, or timed out.

---

## Delivery sequence

### Phase 1 — P0 foundation

1. Add session observability: connection timestamps, latest RTT, bounded RTT samples, and missed-heartbeat state.
2. Add read-only dashboard state in AppState, derived from current pair and connection state.
3. Build reusable PhoneSummaryCard widgets in Windows Overview.
4. Wire quick actions to existing functionality.
5. Add unit/widget tests for state changes and multi-phone grouping.

**Acceptance:** A Windows user can identify each paired phone, its link quality, folder state, and send/reconnect actions without a new protocol message.

### Phase 2 — P1 telemetry

1. Add handshake capabilities and old/new peer compatibility tests.
2. Add device_status validation, routing, and latest-wins updates.
3. Add the Android sampler and hybrid update policy.
4. Add bounded local metadata persistence and peer-removal cleanup.
5. Render battery/storage/Conduit-health fields including stale and unsupported states.

**Acceptance:** A supported connected Android peer reports battery, charging, device storage, and safe health indicators. An older peer stays fully usable and shows Phone status unavailable.

### Phase 3 — P2 alert

1. Add phone-side opt-in and native enforcement.
2. Add allowlisted action/result routing and idempotency tests.
3. Add desktop confirmation and result UI.
4. Test foreground/background, silent, DND, and unsupported-device paths.

**Acceptance:** An enabled, connected phone can acknowledge a bounded alert; the PC never claims it played when the phone says otherwise.

### Phase 4 — P3 validation and polish

1. Add transfer receipt retention/display.
2. Add clipboard activity metadata.
3. Decide whether a dedicated dashboard page is warranted.

---

## Test matrix

- New Windows + new Android peer; new Windows + older Android peer; inverse.
- Two phones with different advertised features.
- Connection drop/reconnect while a status update or action result is in flight.
- Session replacement and stale-session frame rejection.
- Battery change, plug/unplug, and rate-limit behavior.
- Missing storage value or non-filesystem SAF provider.
- PC restart, local data retention/expiry, and peer removal.
- Malformed, oversized, unknown-field, and unknown-action frames.
- Alert disabled, silent/DND, unsupported capability, and timeout paths.
- Confirm telemetry never enters sync indexes, version vectors, transfer queues, or verbose diagnostics.

---

## Decision gates

Before Phase 1:

- Confirm Overview-card-first rather than a new navigation destination.
- Confirm support for multiple paired Android phones from day one.

Before Phase 2:

- Confirm status/receipt retention policy.
- Confirm exact Conduit-health fields and safe error codes.

Before Phase 3:

- Confirm phone-alert opt-in wording and Android version support.
- Keep scope at Play phone alert; do not expand into ringer/DND control without a separate permission and privacy review.

---

## Platform references

- Battery status: <https://developer.android.com/reference/android/os/BatteryManager>
- Filesystem storage: <https://developer.android.com/reference/android/os/StatFs>
- Wi-Fi data sensitivity: <https://developer.android.com/reference/android/net/wifi/WifiInfo>
- Vibration rules: <https://developer.android.com/reference/android/os/VibratorManager>
- Notification/DND access: <https://developer.android.com/reference/android/app/NotificationManager>

