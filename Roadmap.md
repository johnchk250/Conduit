# Conduit — Reliability, Battery & Feature Roadmap

> **Purpose.** A single forward-looking plan that captures *what we're adding*
> to Conduit, *why*, in *what order*, and — above all — *how to do it without
> disturbing the V2 sync engine*. Written 2026-06-25 after a review of the
> current codebase against two external references: the project's own
> `ARCHITECTURE.md` and an independent `lan_sync_architecture.md` design spec.
>
> **Companion to:** `ARCHITECTURE.md` (read that first for the engine internals).
> **Status:** plan only — no code written yet. Phases are independent and can be
> executed in later sessions. Update the per-phase status line as you go.
>
> **If anything here contradicts `ARCHITECTURE.md` or the source, the source wins.**
> Fix this doc and the architecture doc to agree.

---

## 0. Hard constraint (read first)

> **The existing V2 sync engine must not be corrupted or disturbed.**

The engine is the product's reason to exist and was hard-won (154/154 tests,
Bug #6→#9 + smoke #3 all fixed). Every item below is therefore **additive**: new
wire message types, new branches *appended* to `_handlePeerMessage`, new UI
screens, new platform channels, new `SyncService.kt` flags. **None** of the
planned work flows through `indexDiff`, `_applyRemoteTombstone`, `upsertLocal`,
`confirmLocalObservation`, or the version-vector ordering path.

### The three load-bearing invariants that MUST stay intact
(re-stated from `ARCHITECTURE.md` §9.2 — if any planned work risks touching
these, STOP and re-read)

1. An unfetched peer row has `localSha == ''` (`applyRemote` forces it).
2. A fetched file gets `localSha` via `confirmLocalObservation` (no seq bump).
3. `localSnapshot` and `localLivePaths` both admit `localSha`-confirmed rows.

Breaking any reintroduces Bug #8 (re-fetch loop) and/or Bug #9 (recv-delete
propagation). **No planned feature needs to touch these.** Feature #2 (ad-hoc
file send) is the only one that reuses engine code (the transfer primitives) and
it does so under a *separate, non-sync* handler so ad-hoc files can never enter
the sync needs-queue.

### "Engine-safe" checklist for any change
- [ ] Does it add a new code path rather than modifying sync logic? ✓
- [ ] Does it avoid `indexDiff` / `_applyRemoteTombstone` / `upsertLocal` /
      `confirmLocalObservation` / `VersionVector`? ✓
- [ ] Does it preserve the no-op-invariant (idle scan burns zero sequences)? ✓
- [ ] Can it be reverted by deleting the new code without touching the engine? ✓

---

## 1. Current state (as of 2026-07-07)

### What Conduit is
Peer-to-peer LAN folder sync between **two devices you own** (Windows PC ↔
Android phone). No cloud, no account, no relay. Identity-based pairing (pinned
ed25519 keys) so home↔office Wi-Fi needs no re-pairing. One Flutter/Dart
codebase → Windows `.exe` + Android `.apk`.

### Engine state — stable, do not break
- **V2 index engine is live.** Legacy v1 manifest/diff/resolver/transfer code has been removed.
- **Source of truth:** per-folder SQLite Index DB (`index_db.dart`), durable
  across reconnects. WAL mode set on open (`index_db.dart:202`).
- **Ordering:** version vectors (`version_vector.dart`) — the SOLE authority.
  No mtime comparison anywhere (that was the smoke #3 race).
- **Transfer:** block-level 1 MiB, `.syncpart` + atomic rename, terminal-error
  semantics (`block_transfer.dart`).
- **Deletes:** tombstones + version-vector dominance, receive-time
  delete-vs-edit decision (`_applyRemoteTombstone`, `DeleteDecision`).
- **Tests:** 192 as of 2026-07-11 (Phase 6.2/6.4 added 39; last independently
  *run and confirmed* passing was 154/154 on 2026-07-08 — no Flutter/Dart SDK
  has been available in the implementing sandbox for any session since, so
  every addition after that date, including this one, was verified by manual
  read-through/hand-traced test cases rather than execution; see
  `ARCHITECTURE.md` §10 and Appendix B), logic-only (real
  `IndexDb`/scanner/diff/transfer, no sockets/SAF/hardware). Each fixed bug
  has a dedicated regression test.

### The three independent V2 mechanisms (don't fight these)
1. Persistent Index DB (durable source of truth).
2. Version vectors (sole ordering authority).
3. Monotonic sequence + Index/IndexUpdate frames (kills the manifest-rebuild
   race).

### Networking state
- UDP beacon discovery (`discovery.dart`, **3s broadcast interval**).
- `PeerConnectionRegistry` — single source of truth for live sessions.
- `ConnectionSupervisor` — beacon-independent 5s reconnect sweep + exp
  backoff.
- `FrameCodec` — single-owner `[4-byte len][JSON]` (structurally no silent
  drops).
- Heartbeat (~36s death detection via 3×12s intervals).
- Self-signed TLS (when a cert is available); pinned pubkeys.

### Platform state
- **Windows:** `%APPDATA%\Conduit\` for identity/config. TCP 41828.
  `dart:io` native FS.
- **Android:** SAF document trees (no all-files-access permission).
  `SyncService.kt` foreground service, type `dataSync`, **10-min partial wake
  lock** on `onCreate`, `setReferenceCounted(false)`.

---

## 2. Findings from the review (why we're doing this)

### 2.1 Reliability gap — sync is 100% event-driven
Conduit fires a reconcile **only** on: a watcher change signal (4s poll,
`watcher.dart:108`), a peer connect, or an inbound `IndexUpdate`. There is
**no periodic reconcile while connected**. If a watcher tick misses an edit
(possible — rapid edit landing with identical size/colliding mtime, or a lost
tick), the drift sits **until the next reconnect**, which can be hours.

`lan_sync_architecture.md` invariant #7 names this directly:
> *"The periodic scanner and FS watcher are both always running in parallel."*

→ **Action:** add a periodic reconcile safety-net (Phase 0.1).

### 2.2 Battery — the drain is the triggers & OS wiring, NOT the engine
On an idle, in-sync folder the engine does near-zero work (the no-op
invariant). The drains are the always-on triggers:

| Activity | Rate | Per-hour cost | Type |
|---|---|---|---|
| Watcher poll (`watcher.dart:47`, 4s) | 900/h | SAF `listFiles` + per-file `stat` | **Expensive** (SAF IPC) |
| Discovery broadcast (`discovery.dart:64`, 3s) | 1200/h | UDP send → Wi-Fi radio wakeup | **Expensive** (radio) |
| Connection supervisor (5s) | 720/h | in-memory | cheap |
| Heartbeat (12s) | 300/h | small TCP frame | cheap |

**The 3s beacon is the #1 phone drain** — every UDP send forces the Wi-Fi
radio active, and the radio stays up ~1–2s *after* each send, so at 3s it
essentially never sleeps. **The 4s watcher poll is #2 and is pure waste when
no peer is connected** (detecting changes that can't be synced anyway).

**Will the periodic reconcile hurt battery?** No — it's ~2 SAF scans/hour vs
900 existing → ~0.2% on the cheapest axis, and each is a no-op on idle
folders. Rounding error.

→ **Actions:** watcher backoff when offline (0.2), beacon backoff when stable
(0.3), wake-lock tied to transfers (0.4, optional).

### 2.3 DB hardening (addresses `lan_sync` FM-16)
Index DB is WAL but does NOT set `synchronous = NORMAL` and does NOT run
`integrity_check` or keep a `.bak`. A corrupt DB today means a full re-scan.

→ **Action:** Phase 0.5.

### 2.4 Feature backlog (from the owner, 2026-06-25)
Six feature asks — feasibility assessed, all engine-safe, sequenced in
§3. Two have hard platform ceilings (called out in §4).

---

## 3. The plan — phased, each phase independent

Sequenced by **value × low-risk-first**. Each phase is self-contained: a
later session can pick one phase and execute it without context from the
others. Mark status as you start/finish each.

> **Build rule (from ARCHITECTURE.md §11):** after ANY sync-touching change,
> rebuild **BOTH** `flutter build windows --profile` and `flutter build apk
> --profile`. (For these phases only Phase 0 touches sync-adjacent paths; the
> rest are additive and platform-only, but rebuild both anyway for parity.)

### Phase 0 — Reliability + Battery (foundation, no engine change)
**Status:** ✅ complete (2026-06-25)
**Engine-safe?** ✅ all wiring-only.

| # | Item | File(s) | Why |
|---|---|---|---|
| 0.1 | **Periodic reconcile safety-net.** Long-interval (30 min) per-pair `reconcile(pair, session)` while a session is live. New `Map<String,Timer>` in `engine.dart`, started/stopped alongside watchers (`startPair`/`stopPair`/`dispose`). Relies on the existing re-entrancy guard (`engine.dart:573` `if (st.scanning) return;`) and the no-op-invariant. | `lib/src/sync/engine.dart` | Closes the only reliability hole (watcher-miss drift). |
| 0.2 | **Watcher backoff when no peer.** Stretch poll 4s→30s when `registry.sessionFor(peerId)==null`; restore 4s on connect. | `lib/src/sync/watcher.dart` + engine wiring | ~8× fewer SAF scans in the common offline state. |
| 0.3 | **Discovery beacon backoff when stable.** Broadcast fast (3s) for ~30s after startup/reconnect to establish the link, then back off to 10–15s while a session is live. Persistent session + `ConnectionSupervisor` cover re-acquisition. | `lib/src/net/discovery.dart` | Sleeping radio once connected. |
| 0.4 | **Wake lock tied to transfers.** Engine signals `transferring` start/stop over a method channel; `SyncService.kt` acquires a short, renewable (120s timeout, 45s Dart renewal) lock only during `transferring==true`, releases on idle. **Post-audit fix (2026-07-10):** originally acquired directly on `MainActivity`, which released it in `onDestroy()` — meaning a plain swipe-from-recents mid-transfer killed the lock, and the lack of renewal meant any burst >60s lost it regardless. Ownership moved to `SyncService` (which outlives the Activity) and renewal added; see `HANDOFF_2026-07-10_WAKELOCK_FIX.md`. | `SyncService.kt`, `MainActivity.kt` (forwards over `conduit/wakelock`), `app_state.dart` `_onTransferState`/`_renewTransferWakeLock` | Doze works during idle; transfer protection actually survives backgrounding. |
| 0.5 | **DB hardening.** `PRAGMA synchronous = NORMAL` alongside WAL; `PRAGMA integrity_check` on open; hourly `.bak` copy of the DB file. | `lib/src/storage/index_db.dart` `open()` | Recoverable DB without a full re-scan. |
| 0.6 | **Battery-saver mode + connection wake lock + discovery multicast toggle** (undocumented until 2026-07-10; code and tests existed, this table didn't mention it). Battery-saver mode stretches the watcher to a flat 1-hour cadence regardless of connection state. A second renewable wake lock (`Conduit::Connection`, 120s timeout / 45s renewal) is held whenever any peer session is live — independent of whether bytes are moving. The Android `MulticastLock` is held unconditionally at service start, then released once any peer session goes live and re-acquired once none are (an established TCP session doesn't need broadcast discovery). Same post-audit ownership fix as 0.4 applies to the connection lock. **2026-07-11 fix:** the connection wake lock was originally *also* gated on battery-saver being off (`anyLive && !batterySaverMode`), which let Doze stall an already-live session's heartbeat whenever battery-saver mode was on, producing a disconnect/reconnect cycle roughly every 72–90s. Decoupled — the lock now depends only on `anyLive`; battery-saver's idle savings come entirely from the watcher-cadence change above and are unaffected. See `ARCHITECTURE.md` Appendix B (2026-07-11) and `PROGRESS.md`/`THINKING.md` for the investigation. | `lib/src/sync/engine.dart` (`setBatterySaverMode`), `lib/src/app_state.dart` (`_setConnectionWakeLockEnabled`, `_setDiscoveryLockEnabled`, `_applyBeaconMode`), `SyncService.kt`, `SafOps.kt`/`scanner.dart`/`watcher.dart` (batched SAF fast-path listing) | Cuts watcher/discovery cost further for users who opt in; avoids holding the multicast lock 24/7 when it can't do anything useful; live sessions now survive Doze regardless of battery-saver mode. |

**Tests for Phase 0:**
- 0.1: regression test asserting the no-op-invariant still holds under a
  periodic tick (idle folder burns zero sequences across N ticks).
- 0.5: test that a DB opened after `synchronous=NORMAL` round-trips rows
  unchanged; that `integrity_check` result is surfaced/logged.
- 0.4/0.6 wake locks: **no test coverage as of 2026-07-10.** The Kotlin
  wake-lock/service code can't be exercised by the existing `flutter test`
  suite (no Flutter/Dart SDK dependency reaches into `SyncService.kt`
  directly); this was true before the ownership fix and remains a real gap
  afterward. Manual review only — see `HANDOFF_2026-07-10_WAKELOCK_FIX.md`.

**Acceptance:** `flutter analyze` clean; `flutter test` 154/154 (or updated
count) passing; both binaries rebuilt.

---

### Phase 1 — Background survival (owner feature #4)
**Status:** ✅ complete (2026-06-25)
**Engine-safe?** ✅ platform wiring only.

**Why first among features:** every other feature only matters if the app
stays alive.

**PC side (Windows tray + close-to-tray):**
- Add `window_manager` + `tray_manager` (or `system_tray`).
- `windowManager.setPreventClose(true)`; in `onWindowClose` → `windowManager.hide()`
  (keeps the process alive).
- Tray icon with menu: **Show / Pause sync / Quit**. "Quit" does the real
  `exit(0)` (the *intentional* exit the owner asked for).
- Files: `lib/main.dart`, new `lib/src/desktop/tray.dart`, `windows/runner`.

**Android side (survive background kill):**
- Request **"Unrestricted" battery** + runtime `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`.
- `onTaskRemoved` → schedule service restart (swipe-from-recents doesn't kill).
- In-app guidance screen for OEM autostart/battery whitelists (Xiaomi/Huawei/
  OPPO) — because **no code defeats MIUI/EMUI's killer**; the user must
  whitelist. KDE Connect docs tell users the same thing.
- Note Android 14+ `dataSync` FGS 6h daily cap on some OEMs; track for later.
- Files: `SyncService.kt`, `AndroidManifest.xml`, new guidance UI screen.

**Reality check (do NOT over-promise):** even with all of this, no app
*guarantees* never being killed — not even KDE Connect. The persistent
notification + unrestricted battery + OEM whitelist gets ~95% of the way.

**Acceptance:** Windows app survives close (process in Task Manager, tray
icon present); Android app survives screen-off + swipe-from-recents for
≥10 min on a stock Pixel-class device; user can quit explicitly on both.

---

### Phase 2 — Clipboard sync (owner feature #1)
**Status:** ✅ complete (2026-06-27); hardened 2026-07-06; **2026-07-11:
fixed a false "clipboard couldn't be written" notification** — the phone
was misreporting successful backgrounded writes as blocked because its own
verify step used a same-process readback, which Android's focus-gated
*read* restriction denies independent of whether the write (done via a
separate, unrestricted native-write path) actually succeeded. See
`ARCHITECTURE.md` Appendix B (2026-07-11) for the full root cause and fix.
**Engine-safe?** ✅ new `Msg.clipboardPush`, appended handler.

**Platform reality (already researched):**
- **PC→phone, automatic: ✅** PC listens on Windows clipboard, sends
  `clipboardPush{text}`; phone writes clipboard via method channel (FGS app
  *can write*; only *background reading* is blocked).
- **Phone→PC, manual (in-app button): ✅** When the user copies + opens
  Conduit and taps "Send clipboard now", read the *current* clipboard
  (legal — app is foreground at that moment) and send to PC. This is the only
  legal shape. A "floating popup anywhere you copy" is impossible on stock
  Android 10+ (the app must be foreground to read the clipboard); a
  foreground-only chip was prototyped and **intentionally dropped** as not
  meeting the "anywhere I copy" bar — see HANDOFF_2026-06-27_PHASE2_FIXES.
- **Phone→PC, automatic: ❌ impossible on stock Android 10+.** Since Android
  10, a backgrounded app cannot read the clipboard (only the focused app or
  the IME). `READ_CLIPBOARD_IN_BACKGROUND` is system/OEM-only. This is
  *exactly* why KDE Connect's Android build is manual phone→desktop too. Do
  not attempt to "engineer around" this — it is a deliberate Google privacy
  rule. (See ROADMAP sources, §6.)

**Discovery gotcha (do not regress):** Android filters broadcast/multicast UDP
to apps unless the process holds a `WifiManager.MulticastLock`. The manifest
permission (`CHANGE_WIFI_MULTICAST_STATE`) alone does nothing — the lock must
be acquired at runtime (held in `SyncService` + `MainActivity`). Without it
LAN auto-discovery is deaf: both devices on the same Wi-Fi and neither
auto-connects. (Fixed 2026-06-27, see HANDOFF_2026-06-27_PHASE2_FIXES.)

**Implementation:**
- New `Msg.clipboardPush` in `wire.dart`.
- PC clipboard listener: a Windows-level hook (native plugin) or a careful
  polling loop (respecting battery — only when a peer is connected).
- Handler appended to `_handlePeerMessage` (do NOT insert into sync cases).
- Method channel `writeClipboard` on Android; `setClipboard` on Windows.

**Privacy consideration:** clipboard can contain passwords/2FA codes. Options
to surface to the user: a setting "sync clipboard" (off by default), optional
"ignore clipboard while password manager is active" (best-effort), and never
log clipboard contents in the Activity feed.

**Acceptance:** copy text on PC → appears on phone within ~1–2s (when sync
enabled); manual "send clipboard" from phone → PC; no clipboard contents in
logs.

---

### Phase 3 — Ad-hoc file send + notifications + folder badges (owner #2 & #5)
**Status:** ✅ complete (2026-06-27)
**Engine-safe?** ✅ reuses transfer primitives under a *separate* handler.

**3a. Send arbitrary file(s) to peer:**
- Android: inbound share-sheet entry (via `receive_sharing_intent` /
  `share_plus`). User selects files → "send to <peer>" → files offered via a
  new `Msg.fileOffer`.
- Windows: drag-into-app target, and (later, optional) a shell-extension
  "Send to Conduit".
- **Safety design:** route ad-hoc transfers through a **separate top-level
  handler** (NOT `_processNeeds`), using the existing
  `serveFileBlockLevel`/`fetchFileBlockLevel` primitives under a user-chosen
  destination path. The sync Index DB is **never consulted** for these →
  zero chance of an ad-hoc file becoming a phantom sync need.

**3b. Notification badges:**
- `flutter_local_notifications` (Android) + tray tooltip/count (Windows) on
  send/receive.

**3c. Folder sync-state badges (owner #5):**
- The engine already emits `PairSyncState` with `status`
  ('Idle'/'Syncing'/'Scanning'/'Error') and `lastSyncedAt` via the
  `_stateController` stream (`engine.dart:268`). Badge is pure UI:
  ✓ blue (in sync) / ⟳ spinning blue (syncing) / ⚠ red (error) / grey
  (offline). Read-only consumption of an existing stream.
- Windows *Explorer* overlay icons (green check in File Explorer itself)
  need a shell icon-overlay COM extension — separate optional later phase;
  in-app badge is the 80%/5% version.

**3d. OS-level share/send context menu integration (owner priority):**
- Android: registered `ACTION_SEND` and `ACTION_SEND_MULTIPLE` intent-filters in
  AndroidManifest.xml. Custom `onNewIntent`/`onCreate` handlers in MainActivity.kt
  extract shared URIs and push them over `conduit/share_receive` method channel.
- Windows: custom `CreateSendToShortcut` Win32 helper writes `Conduit.lnk` in
  `%APPDATA%\Microsoft\Windows\SendTo\`. If launched via context menu or second
  instance with `--send` args, handles single-instance check and forwards paths to
  main instance via `WM_COPYDATA`.
- Dart side: automatic navigation to Send panel when shared files are detected.
  Auto-sends shared files when exactly one peer is connected, or prompts user to
  select target peer when multiple/none are connected.

**Files:** new `lib/src/ui/send_panel.dart`, `lib/src/sync/file_transfer.dart`
(ad-hoc handler), `wire.dart` (`Msg.fileOffer`, `Msg.fileOfferAck`),
`lib/src/ui/folders_screen.dart` (badges), `windows/runner/send_to_shortcut.cpp`
/ `h` (Win32 SendTo writer).

**Acceptance:** send a file from either side → arrives at chosen destination,
no effect on ongoing sync; notification fires; folder row shows correct badge
state across Idle/Syncing/Error. Explorer right-click "Send to" works on Windows,
and Android share-sheet targets Conduit directly.

**2026-07-09 follow-on (throughput + compact send widget):** see
`docs/2026-07-05-send-widget-and-throughput.md` and the 2026-07-09
`ARCHITECTURE.md` Appendix B entry. TCP_NODELAY + pipelined ad-hoc block fetch
(depth 8) + a compact Windows popup send flow. **Note:** the sync engine's own
needs-queue fetch is now also pipelined at depth 4 (`_syncPipelineDepth` in
`engine.dart`) — this goes further than the doc's "left alone here
deliberately" follow-up list said, and has no dedicated end-to-end regression
test yet (only the primitive is tested at depth >1, via a fake `sendRequest`).
Reviewed by inspection and looks engine-safe (no `localSha`/version-vector
path touched, FIFO request/response order preserved), but **flag for a real
`flutter analyze` + `flutter test` + a needs-queue-level pipelining regression
test** before treating it as fully verified — see `PROGRESS.md`.

---

### Phase 4 — Remote command from phone→PC (owner feature #3)
**Status:** ✅ complete (2026-06-27)
**Engine-safe?** ✅ new `Msg.runCommand`, isolated.

**⚠️ Security shape (decide before coding):** a phone that can run arbitrary
shell on the PC is a remote shell, and pairing is cross-network (home↔office).
Recommended policy — **owner to confirm**:

- **Option A (recommended, safe):** a **fixed allowlist** of commands defined
  on the PC (e.g. `shutdown`, `sleep`, `lock`, `hibernate`, `mute`). The phone
  UI shows only those buttons — never free text. Default: **disabled** until
  turned on in PC settings.
- **Option B (powerful, riskier):** free-text commands with a PC-side confirm
  toast ("Phone requested: <cmd> — allow?"). More flexible, more dangerous.

**Implementation (once policy chosen):**
- New `Msg.runCommand{name}` in `wire.dart`; handled only on PC; executes
  only allowlisted names via `Process.run`. Optional PC confirm dialog.
- Disabled by default; opt-in in PC settings.
- Files: `wire.dart`, new `lib/src/desktop/commands.dart`, phone UI buttons.

**Acceptance:** with the feature off, no new wire messages are ever sent/acted
on; with it on, only allowlisted commands run; a confirm (if enabled) works.

---

### Phase 5 — UI polish (owner feature #6)
**Status:** ✅ complete (2026-06-27)
**Engine-safe?** ✅ pure UI, reads streams only.

Fold all the above into a cohesive redesign rather than bolting on piecemeal:
- Cleaner **Activity feed** with severity color-coding + icons (today it's
  raw `[ts] LEVEL pairId: msg` strings — too technical/verbose).
- Consistent **Material 3** token usage; polished nav rail (wide) / bottom
  bar (phone).
- New screens from Phases 2–4 (clipboard panel, file-send flow, command
  buttons) designed in the same style.
- The UI only reads `engine.events` / `engine.stateChanges` streams and calls
  public methods (`sendClipboard`, `sendFile`, `runCommand`, `reconcile`).
- Files: `lib/src/ui/*.dart` (rewrite of Activity, nav, theme, + new screens).

**Acceptance:** Activity is human-readable and color-coded; nav is
uncluttered; new feature screens match the rest of the app.

---

### Phase 6 — Quick-setup wizard, sync preview, ignore rules, version-restore UI
**Source:** `docs/2026-07-11-phase6-planning.md`. Numbering below matches that
doc's own §7 summary table.

#### 6.1 — Sync preview
**Status:** ☐ not started (out of scope for the 2026-07-11 implementation
session — not requested).

#### 6.2 — Ignore rules (glob / extension / size)
**Status:** ✅ complete (2026-07-11)
**Engine-safe?** ✅ new module (`ignore_rules.dart`) + one new `continue`
branch in `scanner.dart`'s existing per-file loop, gated behind optional
params that default to empty/null/no-op. Does not touch `indexDiff`,
`_applyRemoteTombstone`, `upsertLocal`, or the version-vector path.

`FolderPair` (`wire.dart`) gained `ignoreGlobs` / `ignoreExtensions` /
`maxFileSizeBytes` — local-only, not peer-negotiated, backward-compatible
JSON. New `lib/src/sync/ignore_rules.dart`: a small hand-rolled glob
matcher (`*`, `**`, `?`) rather than the planning doc's suggested `glob`
pub package — no Flutter/Dart SDK or pub.dev access in the implementing
session's sandbox to fetch/verify a new dependency against. Wired into
`scanner.dart` right after the existing `_isInternalArtefact` check: a
matching path is skipped before hashing/upserting.

**Retroactive-ignore semantics (§4.4 open question) — resolved:** confirmed
with Aminul before implementation. A rule added for an already-synced file
**freezes** it (keeps last-synced state on both devices, stops tracking
further local edits) rather than tombstoning/deleting it. The matched path
is still added to the scanner's `seenPaths` set specifically so the
tombstone sweep doesn't mistake "now ignored" for "locally deleted."

New "Ignore rules" editor dialog in `folder_pairs_screen.dart`, calling new
`AppState.updateIgnoreRules`. That method explicitly cycles
`engine.stopPair`/`startPair` rather than just re-persisting to config —
`startPair(pair)` closes over the `FolderPair` object in its watcher/timer
closures, so a plain persist would leave an already-running pair using
stale rules until app restart. (The pre-existing name/path/direction
edit dialog has this same latent gap via `addFolderPair` — noted, not
fixed, out of scope for this phase.)

Files: `lib/src/sync/ignore_rules.dart` (new), `lib/src/protocol/wire.dart`,
`lib/src/sync/scanner.dart`, `lib/src/sync/engine.dart` (both `scan()` call
sites), `lib/src/app_state.dart`, `lib/src/ui/folder_pairs_screen.dart`.
Tests: `test/ignore_rules_test.dart` (new, 16 cases) + 6 new cases in
`test/scanner_test.dart` (including the retroactive-freeze-not-tombstone
invariant).

**Acceptance:** a glob/extension/size rule keeps a matching file out of the
Index DB entirely; adding a rule for an already-synced file freezes it in
place on both devices rather than deleting it anywhere; removing the rule
resumes normal tracking.

#### 6.3 — Quick-setup wizard (camera/screenshot backup presets)
**Status:** ☐ not started (out of scope for the 2026-07-11 implementation
session — not requested).

#### 6.4 — Version-restore UI (edit-only scope)
**Status:** ✅ complete for edit-only scope (2026-07-11). Restoring a
*deleted* file (the doc's option (a)) remains ☐ not started.
**Engine-safe?** ✅ `block_transfer.dart`'s `_replacePartWithFinal` is not on
the do-not-touch list; the restore write path is an ordinary
`FileSystemAccess.write` call, deliberately not special-cased anywhere in
`scanner.dart`/`engine.dart`'s reconcile logic/`indexDiff`/`upsertLocal`/
`VersionVector` — the next scan picks up a restored file exactly like any
other local edit.

**Scope decision (§5.3 open question) — resolved without needing to ask:**
the doc's option (a), restoring a *deleted* file, requires a line inside
`_applyRemoteTombstone` — which this project's own §0 hard-constraint list
above already names as must-not-touch, no exceptions. That's not a
judgment call the way retroactive-ignore semantics was; it's already
answered by an existing constraint. Implemented the doc's recommended
option (b) only: restoring a previous version of an *edited* file.

`_replacePartWithFinal` now vaults the existing file (via
`FileSystemAccess.moveToVault` — previously-dead infrastructure, zero
callers before this phase) before an incoming fetch overwrites it.
Best-effort: a vault failure never blocks the transfer. **Bug caught and
fixed before shipping:** `LocalFileSystemAccess.moveToVault` returned an
*absolute* path while the Android SAF implementation returned a *relative*
one — harmless while nothing consumed the return value, but would have
broken cross-platform restore inconsistently. Fixed to return a path
relative to `rootPath` on both platforms, at the one moment doing so was
guaranteed to affect no existing behavior.

New `lib/src/sync/vault_log.dart`: a small per-pair JSON catalog of vault
events (in the app's own state directory, not inside the synced folder),
used instead of directory-listing `.syncversions/` — both
`FileSystemAccess.listFiles` implementations already filter that directory
out (existing scanner behavior), and extending the Android native side to
list it would mean shipping new, unverifiable Kotlin with no SDK/emulator
available to build or test it against. Reading a *specific known* vaulted
path back needs no new native code (confirmed: the native `stat`/`read`
handlers resolve an exact path with no directory-level filtering) — that's
what restore uses.

New `AppState.restoreVersion`: reads the vaulted bytes, vaults the
*current* live file first (so a restore is itself undoable), writes the
restored bytes via the ordinary filesystem-write path. New
`lib/src/ui/version_history_screen.dart` (list + confirm + restore), wired
from a new button in `folder_pairs_screen.dart`'s pair-detail screen.

**Retention policy (§5.2.3) — out of scope for this pass**, matching the
planning doc's own "first cut" framing: old vault entries are never pruned.

Files: `lib/src/sync/vault_log.dart` (new), `lib/src/ui/version_history_screen.dart`
(new), `lib/src/sync/block_transfer.dart`, `lib/src/sync/manifest.dart`
(the absolute/relative-path fix), `lib/src/sync/engine.dart`,
`lib/src/app_state.dart`, `lib/src/ui/folder_pairs_screen.dart`. Tests:
`test/vault_log_test.dart` (new, 8 cases), `test/local_fs_access_test.dart`
(new, 7 cases — including a dedicated regression test for the
absolute/relative-path bug), + 2 new cases in `test/block_transfer_test.dart`.

**Acceptance:** a file overwritten by an incoming sync is recoverable from
the "Restore versions" screen; restoring it propagates to the peer as a
normal edit with no engine-level special-casing; a vault failure never
blocks a transfer.

**Not independently verified this session** (no Flutter/Dart SDK
available): every new test was hand-traced against the exact algorithm
rather than executed (glob-matching logic additionally cross-checked
against a Python mirror). Test count 153→192 (39 new). Recommend running
`flutter analyze` + `flutter test` and a real cross-device
edit-conflict-then-restore on both Windows and Android before merging. See
`ARCHITECTURE.md` Appendix B (2026-07-11 entry) and `PROGRESS.md`/
`THINKING.md` for the full investigation and design-decision trail.

---

### Phase 7 — Liquid-glass UI redesign (visual restyle, on top of Phase 5)
**Status:** 🟡 in progress — shared library + app shell done, per-screen
conversion ongoing.
**Engine-safe?** ✅ pure UI, same constraint as Phase 5.

Distinct from Phase 5 (which was the original Material 3 polish pass, marked
complete 2026-06-27): this phase re-skins the same screens in a translucent
"liquid glass" style (ambient drifting gradient background, blurred
translucent panels, gradient-border cards) via a new shared component
library, rather than changing any behavior. Design intent, restraint notes,
and the modal-surfaces-stay-Material rule all live as doc comments directly
in `lib/src/ui/glass.dart` — read that file's header before touching it or
any screen that uses it.

**Shared library:** `lib/src/ui/glass.dart` — ✅ complete, now on its
**clear-glass v5** revision (`GlassColors`, `GlassBackground`, `GlassPanel`,
`GlassSectionLabel`, `GlassListTile`, `GlassStatusBanner`, `GlassChip`,
`GlassButton`, `GlassNavBar`/`GlassNavRail`). v5 pulls per-panel accent-color
fill/border tinting back out (the "vibrancy" pass didn't land well — see
`docs/2026-07-12-clear-glass-v5-plan.md` §0) in favor of a neutral glass
surface with color only on content (icon-chip borders, the hero ring, filled
pills), a lighter backdrop gradient, and a drifting light-sweep ambient
animation in place of the old three colored blobs. The Android
flicker/perf fix from the vibrancy pass (`Timer` + implicit-animation drift,
not a free-running `AnimationController`) carries over unchanged and now
also covers the sweep — see the plan doc §3.1/§6 for why that matters.

**Per-screen conversion checklist:**
| File | Status |
|---|---|
| `glass.dart` — clear-glass v5 token/component revision (see `docs/2026-07-12-clear-glass-v5-plan.md`) | ✅ done (2026-07-12) — un-tints panel fill/border, adds specular line + light sweep, hero moves to ring-not-fill, nav active state goes neutral. Do this before any further per-screen rows below. |
| `dashboard_screen.dart` (shell: NavRail/NavBar, Overview, Settings hub) | ✅ done (2026-07-12) — re-touched for v5 (was converted against the now-reverted "vibrancy" pass): migrated `_sectionHeader` → shared `GlassSectionLabel` (plan §3.6); no other call-site changes needed (`GlassListTile`/`GlassChip`/`GlassStatusBanner` pick up the new neutral tokens automatically). Quick Actions row deliberately left as a single `Send files` row, not converted to the mockup's 3-across circular layout — see plan §5. |
| `folder_pairs_screen.dart` | ⬜ not started — recommended next (see `THINKING.md` 2026-07-12), now against v5 tokens |
| `pairing_screen.dart` | ⬜ not started |
| `remote_control_screen.dart` | ⬜ not started |
| `send_flow_view.dart` | ⬜ not started |
| `send_panel.dart` | ⬜ not started |
| `send_widget_screen.dart` | ⬜ not started |
| `clipboard_screen.dart` | ⬜ not started |
| `activity_screen.dart` | ⬜ not started |
| `version_history_screen.dart` | ⬜ not started |

**Known open item carried over from before this session:** the icon
background color (`#5B4BDB` purple, from the 2026-07-11 adaptive-icon fix)
doesn't match the in-app theme seed color (`AppTheme.seed`,
`0xFF4F6BED` blue) or the glass violet accent (`GlassColors.violet`). Not
touched here — still a design decision for the owner, not a bug.

**Acceptance (per screen):** same interactive behavior as before conversion
(no `onTap`/`onChanged` logic changes except where explicitly noted, e.g. the
Settings "Required" chip in the 2026-07-12 entry); `flutter analyze` clean;
manual visual pass on both a wide/desktop window and a phone-width window.

---

## 4. Things that are deliberately NOT in scope

To show we're not importing a foreign design wholesale:

- **mtime-based conflict detection / LWW** (`lan_sync` FM-11/13) — Conduit's
  version vectors are strictly superior; mtime logic would *regress* smoke #3.
- **Chunk queue table / IN_FLIGHT recovery** (`lan_sync` FM-07) — the durable
  Index DB + terminal-error model already covers this.
- **mDNS / static-IP discovery chain** (`lan_sync` L6) — out of scope; UDP
  beacon + supervisor + QR fallback already cover the two-device LAN use case.
- **Automatic phone→PC clipboard** — impossible on stock Android 10+ (Google
  platform rule, see §2 of Phase 2). Not a code limitation.
- **Windows Explorer overlay icons** — possible but native COM work; defer.

---

## 5. How to execute a phase (instructions for a later session)

1. **Re-read** `ARCHITECTURE.md` §9.2 (the `localSha` invariants) and §0 of
   this file (the hard constraint) before touching anything.
2. Pick **one** phase. Read its rows. Implement only those files.
3. Run the **engine-safe checklist** (§0) on every change.
4. `flutter analyze lib test` → 0 errors.
5. `flutter test` → all green (update count if you added tests).
6. Rebuild **both** targets: `flutter build windows --profile` and
   `flutter build apk --profile`.
7. Append a dated entry to `ARCHITECTURE.md` Appendix B (Change log) and a
   `HANDOFF_*.md` for the phase.
8. Flip the phase status (☐→✅) at the top of its section here.

### Tooling to add per phase (pub deps)
- Phase 1: `window_manager`, `tray_manager` (or `system_tray`).
- Phase 2: Windows clipboard native plugin (or careful polling).
- Phase 3: `receive_sharing_intent` / `share_plus`, `flutter_local_notifications`.
- Phase 4: none (core Dart `dart:io` `Process.run`).
- Phase 5: none.

---

## 6. Sources (researched 2026-06-25)

- Android 10 privacy changes — clipboard access restricted to focused/IME apps:
  https://developer.android.com/about/versions/10/privacy/changes
- Clipboard not accessible from background app (Android 10) — Stack Overflow:
  https://stackoverflow.com/questions/58727690/clipboard-not-accessible-from-background-app-with-android-10-sdk-upgrade
- KDE Connect — Running in the background (persistent notification required):
  https://www.reddit.com/r/kde/comments/1eyjgpq/kde_connect_running_in_the_background/
- Foreground service killed on high-end phone (battery optimization fix) — SO:
  https://stackoverflow.com/questions/49637967/minimal-android-foreground-service-killed-on-high-end-phone
- Building an Android service that never stops running (OEM killers) — Medium:
  https://medium.com/koahealth/building-an-android-service-that-never-stops-running-5868f304724b
- Flutter: keep process alive / hide window — Stack Overflow:
  https://stackoverflow.com/questions/63302226/flutter-desktop-how-to-hide-a-window-and-keep-the-process-alive
- tray_manager package — pub.dev:
  https://pub.dev/packages/tray_manager
- Keep a Flutter Windows app running in the background (close-to-tray) — Medium:
  https://jenishms.medium.com/how-to-keep-a-flutter-windows-app-running-in-the-background-2f0869eba78c

---

*This is a living plan. When a phase ships, update its status line and add the
details that turned out to matter. Keep it short enough that someone can read
it in 5 minutes before starting a phase.*
