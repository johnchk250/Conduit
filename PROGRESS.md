# Work Progress Log (Claude session)

> Running log of what's been done, in-progress, and next. Updated at every
> checkpoint — never left in a half-written state. Newest entries at the top.

---

## 2026-07-10 — Session 2: wake-lock ownership fix + battery-doc audit

**Continuation of the same-day session below.** That session's manual review
(no `flutter`/`dart` SDK, no push credentials — same constraints apply here)
confirmed the transfer/connection wake locks were genuinely owned by
`MainActivity` rather than `SyncService`, despite a code comment claiming
otherwise, and that `MainActivity.onDestroy()` explicitly released both locks
— meaning a plain swipe-from-recents mid-transfer killed wake-lock protection
immediately (this Activity is `launchMode="singleTask"`, no
`excludeFromRecents`, so `onDestroy()` fires on that gesture). Separately,
the transfer lock had no renewal at all, so any burst >60s lost the lock on
its own regardless of the Activity lifecycle.

**Fix implemented and committed locally** (see
`HANDOFF_2026-07-10_WAKELOCK_FIX.md` for full detail):
- `SyncService.kt`: added `transferWakeLock`/`connectionWakeLock` fields,
  acquire/release methods, `ACTION_SET_TRANSFER_LOCK`/
  `ACTION_SET_CONNECTION_LOCK` intents, and companion `setTransferLockEnabled`/
  `setConnectionLockEnabled` functions. Both released in `onDestroy()`
  (genuine service death, unlike the old Activity-triggered release).
  Native timeout raised to 120s for both (safety net; Dart renewal is the
  real mechanism).
- `MainActivity.kt`: removed the Activity-owned `WakeLock` fields and their
  acquire/release methods entirely. The `conduit/wakelock` channel now just
  forwards to the `SyncService` companion functions above. No more wake-lock
  release calls in `onDestroy()`.
- `app_state.dart`: added `_transferWakeLockRenewal` (45s periodic timer,
  mirroring the existing `_connectionWakeLockRenewal`), started/stopped from
  `_onTransferState`, and released from both `dispose()` and `quit()`.
- Docs: corrected `Roadmap.md`'s Phase 0.4 row (was describing the old,
  broken design as current) and added the previously-undocumented Phase 0.6
  row (battery-saver mode, connection lock, discovery multicast toggle —
  code existed, table never mentioned it). Corrected a pre-Phase-0.4 stale
  "10-min cap" wake-lock description in `ARCHITECTURE.md` §8, added new §9.4
  documenting actual wake-lock ownership, and added an Appendix B changelog
  entry.

**Verification performed:** manual read of the full diff (all three changed
files), cross-checked call sites (`SyncService` companion functions called
correctly from `MainActivity`; `_onTransferState`/`dispose`/`quit` call sites
in `app_state.dart` checked for the new timer's lifecycle). **Not performed:**
`flutter analyze` / `flutter test` / an actual Android build — no toolchain
available in this environment. **Recommend running `flutter analyze` and
`flutter test` (and ideally a real device/emulator swipe-from-recents
mid-transfer test) before merging.**

**Known gap, unchanged by this fix:** zero automated test coverage existed
for the wake-lock/service code before this session and none was added — the
existing `flutter test` suite can't reach Kotlin service code. An
instrumented `androidTest/` suite exercising `SyncService` directly is the
right follow-up but is out of scope for what was asked this session.

**Delivery constraint:** no push credentials for `johnchk250/Conduit` in this
environment. Changes are committed locally; delivered to the user as a git
bundle + patch file to apply/push from their own machine.

---

## 2026-07-10 — Session start

**Environment notes (read first, affects everything below):**
- No `flutter`/`dart` SDK available in this sandbox, and no network path to
  fetch it (network egress is allowlisted to package registries like
  pypi/npm/crates/github — no Flutter SDK distribution host). **This means I
  cannot run `flutter analyze`, `flutter test`, or `flutter build`.**
- I also have no push credentials for `johnchk250/Conduit` — I can commit
  locally so nothing is left unsaved, but pushing to GitHub needs you to
  either pull my local commits or give me a token.
- Given this, my work this session is **manual code review + careful static
  checking** (reading call sites, signatures, imports, brace balance —
  the same discipline the prior session used for the Phase-4 send-widget
  work), not automated test runs. I'll flag anything that needs a real
  `flutter analyze`/`flutter test`/`flutter build` pass on your machine
  before shipping.

**State found on clone:**
- Repo: `johnchk250/Conduit`, branch `main`, 3 commits, clean working tree.
- `Roadmap.md`: Phases 0–5 all marked ✅ complete (through 2026-06-27).
- `docs/2026-07-05-send-widget-and-throughput.md`: describes a Phase-4
  follow-on (compact "send widget" popup + TCP_NODELAY + pipelined block
  fetch for ad-hoc transfers) that was **written and reviewed without a
  working Flutter install** — the doc's own §6 explicitly asks for
  `_run_analyze.bat` / `_run_test.bat` to be run before shipping. That
  hasn't happened yet (no HANDOFF doc or changelog entry confirms it).
- All files mentioned in that doc exist in the tree (`peer_session.dart`,
  `block_transfer.dart`, `file_send.dart`, `app_state.dart`,
  `dashboard_screen.dart`, `send_flow_view.dart`, `send_panel.dart`,
  `send_widget_screen.dart`, `tray.dart`, `windows/runner/main.cpp`).

**Plan for this session:**
1. ✅ Clone repo, orient, create this progress file.
2. ☐ Manually review the send-widget/throughput diff for correctness
   (signatures, call sites, obvious logic bugs) since it's unverified.
3. ☐ Cross-check `ARCHITECTURE.md` Appendix B change log is consistent with
   what's actually in the tree; add an entry if the send-widget work isn't
   logged there yet.
4. ☐ Report findings + next steps.

Checkpoints will be appended below as each numbered step finishes, and I'll
commit locally after each one.

---

## Checkpoint 1 (same session) — manual review of throughput/pipelining code

Reviewed `block_transfer.dart`'s `fetchFileBlockLevel` pipelining (sliding
`inFlight` window, `topUpPipeline`) and the FIFO request/response matching it
depends on (`engine.dart`'s `_sendBlockRequest` + `_BlockSink`,
`file_send.dart`'s equivalent queue). **Conclusion: correct.** Order is
preserved because both `session.send(frame)` and the matching
queue/`Completer` bookkeeping run synchronously (before any `await`) inside
each `sendRequest` call, so firing several requests before awaiting any of
them still yields responses in send order — no request-ID tagging needed,
matches what the code comments claim.

**Finding worth flagging:** the 2026-07-05 doc says the V2 sync engine's own
`fetchFileBlockLevel` call was left untouched at pipeline depth 1
("left alone here deliberately... if it ever becomes the bottleneck"). The
actual code in this snapshot (`engine.dart:21`, `const int
_syncPipelineDepth = 4;`, used at the needs-queue's fetch call site) has
already gone ahead and done that follow-up — undocumented, and with no
dedicated end-to-end test of the *real* engine needs-queue at depth >1 (only
the primitive itself is tested at depth 3/4, via a fake `sendRequest` in
`block_transfer_test.dart`). By inspection this looks safe (doesn't touch
`localSha`/version-vector paths, FIFO preserved), but it's a change to the
core sync engine's wire scheduling that the project's own hard constraint
(Roadmap.md §0) says should get extra scrutiny.

**Action taken:** documented this gap rather than silently leaving it — added
a 2026-07-09 `ARCHITECTURE.md` Appendix B changelog entry and a note under
Roadmap.md Phase 3, both recommending a real `flutter analyze`/`flutter
test`/`flutter build` pass plus a dedicated pipelined-needs-queue regression
test before this is fully trusted. Did not change any source logic — this
was a documentation/traceability fix only.

**Files touched this checkpoint:** `ARCHITECTURE.md`, `Roadmap.md`,
`PROGRESS.md`.

**Committed:** yes (see git log).

---

## Next up

- ☐ Optionally review the compact send-widget window-lifecycle code
  (`send_widget_screen.dart`, `tray.dart`'s bounds-suppression flag) for the
  same kind of by-inspection correctness pass.
- ☐ If you have a machine with the Flutter SDK, run `_run_analyze.bat` and
  `_run_test.bat` (ideally add a depth>1 needs-queue regression test first)
  and report back — I can't run these myself in this sandbox.
- ☐ Waiting on you for: whether to keep reviewing, start a new feature, or
  push these doc fixes (I can't push to GitHub myself — no credentials for
  `johnchk250/Conduit`; let me know if you want a token added, or I can hand
  you a patch/diff instead).

---

## 2026-07-10 (new task) — Ad-hoc send UI bug: targeted fix

**User report:** ad-hoc "Send to Conduit" is erratic — when Conduit's window
is already open, the send UI sometimes doesn't open at all, or opens but the
send never starts. Framed as: prior multi-window fix (Phase 3d single-
instance guarantee) didn't fully resolve window/UI integration. Scope for
this task: fix *only* this, nothing else.

**Plan:**
1. ☑ Re-clone repo fresh, re-orient (new session/container; previous
   session's local commits didn't persist — expected, no push credentials).
2. ☑ Trace the whole ad-hoc-send path end to end: `windows/runner/main.cpp`
   (single-instance + WM_COPYDATA) → `flutter_window.cpp` (method channel
   forwarding) → `app_state.dart` (`_onIncomingSharedFiles`, `sendWidgetMode`)
   → `dashboard_screen.dart` (routing) → `send_widget_screen.dart` (window
   geometry) → `send_flow_view.dart` (shared send engine/UI) → `tray.dart`
   (bounds suppression).
3. ☑ Root-caused two concrete bugs (below), both inside the send-widget
   integration layer specifically — native single-instance/WM_COPYDATA
   plumbing checks out correctly.
4. ☑ Applied targeted fixes (see below).
5. ☑ Report back; flag the no-Flutter-SDK verification caveat again.

### Bug 1 (primary): `notifyListeners()` fired mid-build/mid-mount

`SendFlowView.didChangeDependencies()` (`lib/src/ui/send_flow_view.dart`)
snapshots `AppState.pendingSharedFiles` into local fields — correct — but
then calls `state.clearPendingSharedFiles()` synchronously, which calls
`notifyListeners()`. `didChangeDependencies` runs while a widget is being
*mounted*, and for both send-UI hosts (`SendWidgetScreen` **and** the
full-shell `SendPanel`) that mount happens **inside** an ancestor's own
`build()` call (`DashboardScreen.build()`, either directly returning
`SendWidgetScreen`, or via the `_index = 3` tab switch for `SendPanel`).
Notifying the very `ChangeNotifier` an ancestor is currently watching, from
inside that ancestor's build, is the textbook "setState()/markNeedsBuild()
called during build" hazard — depending on framework/provider timing this
either throws (the send UI fails to render — "doesn't open") or the
resulting rebuild gets dropped/coalesced (the UI opens but nothing reacts
to the state change — "send doesn't start"). This matches the erratic,
timing-dependent symptoms reported, and it hits the send widget's *first*
mount — the common case, not an edge case — matching "not thorough," not
"occasionally flaky."

The code already knew the general shape of this problem — the second
pickup site in `build()` (for files arriving while already mounted) is
correctly deferred via `addPostFrameCallback` before touching AppState —
just not the first one (initial mount), which is the path a fresh
"Send to Conduit" trigger actually takes.

**Fix:** `didChangeDependencies()` still snapshots synchronously (so the
first `build()` already has the files, no visible delay), but the
`AppState.clearPendingSharedFiles()` call is deferred to a post-frame
callback — same safe pattern already used elsewhere in this file. Added an
`!identical(...)` guard on the second (build-time) pickup site so it
doesn't redundantly re-schedule a second clear for the same list on the
same frame — harmless before, just tidier now.

### Bug 2: stale window-close cleanup can race a fresh reopen

`SendWidgetScreen._close()` (`lib/src/ui/send_widget_screen.dart`) fires
`windowManager.setAlwaysOnTop(false)` and `DesktopTray.restoreNormalBounds()`
*unawaited* (deliberately, so a window-manager stall can't hang the close),
then immediately calls `AppState.exitSendWidgetMode()`. If a new "Send to
Conduit" arrives while that fire-and-forget cleanup is still in flight (two
files sent back-to-back, or one send auto-closing right as a second is
triggered), a brand-new `SendWidgetScreen` mounts and starts its own
resize/always-on-top/focus sequence — racing the old instance's stale
restore. Whichever finishes last wins, so depending on timing the window
can end up back at full size, not focused, or not on top right after the
new send widget opens — technically there, but the user doesn't see it
("doesn't open"), or sees it briefly then it visually reverts.

**Fix:** added a small monotonic "epoch" counter (`tray.dart`, alongside
the existing `suppressWindowBoundsPersistence` flag it already exports).
Each `SendWidgetScreen` mount claims the next epoch in `initState`
(synchronous, so ordering is deterministic even across rapid mounts). Its
`_close()` cleanup captures the epoch it's closing for and re-checks it's
still current before applying `setAlwaysOnTop(false)`/restoring bounds — if
a newer send-widget session has started since, the stale cleanup is a no-op
and leaves the new session's geometry alone. `_enterWidgetGeometry()` also
bails early if superseded, for the (rarer) reverse race.

**Not touched (out of scope for this fix):** native WM_COPYDATA/single-
instance code (`main.cpp`, `flutter_window.cpp`) — traced carefully, found
correct; throughput/pipelining code from the prior session's review;
anything on the `desktop_multi_window` follow-up mentioned in the Phase 4
doc (still a legitimate future improvement, not this bug).

## Checkpoint — fixes applied

**Diff applied (4 files):**
- `lib/src/ui/send_flow_view.dart` — `didChangeDependencies()` no longer
  calls `AppState.clearPendingSharedFiles()` synchronously (Bug 1's fix);
  the build()-time pickup gained an `!identical(...)` guard so it doesn't
  redundantly re-schedule for the same snapshot.
- `lib/src/desktop/tray.dart` — new `sendWidgetEpoch` counter +
  `beginSendWidgetEpoch()` / `isCurrentSendWidgetEpoch()` helpers, exported
  alongside the existing `suppressWindowBoundsPersistence` flag.
- `lib/src/ui/send_widget_screen.dart` — claims an epoch in `initState`;
  `_enterWidgetGeometry()` and `_close()` both re-check it before applying
  window-manager calls (Bug 2's fix).
- `PROGRESS.md` — this log.

**Sanity checks performed (no Flutter SDK available, see caveat below):**
- Re-read every touched function in full after editing, in place, to
  re-verify control flow (not just diffed the change in isolation).
- Bracket/paren/brace balance check on all 3 touched Dart files — balanced.
- Grepped the whole tree for every symbol touched
  (`clearPendingSharedFiles`, `pendingSharedFiles`, `SendFlowView`,
  `SendWidgetScreen`, `sendWidgetEpoch`) to confirm no other call site
  needed a matching update, and confirmed `SendPanel` (the full-shell "Send"
  tab, the other `SendFlowView` host) benefits from the Bug 1 fix
  automatically since it shares the exact same widget.
- Confirmed the general Flutter hazard behind Bug 1 (`notifyListeners()` /
  `markNeedsBuild()` fired on a ChangeNotifier an ancestor is mid-build on)
  is a real, documented class of bug via a web search cross-check, not just
  an assumption from memory.

**Verification caveat (same as every session so far):** no Flutter/Dart SDK
in this sandbox and no network path to fetch one, so this is a careful
manual review — signatures, call sites, control flow, Flutter/provider
framework semantics cross-checked against current documentation/known-issue
reports — not a `flutter analyze`/`flutter test` run. **Please run
`_run_analyze.bat` and `_run_test.bat` before shipping.** No existing test
in `test/` covers this UI flow (the one `flutter_test`-based file,
`widget_test.dart`, is a first-frame-only smoke test that avoids
`AppState.start()` because it touches real sockets/platform channels) — a
widget test that pre-populates `AppState.pendingSharedFiles` and mounts
`SendFlowView` under a `ChangeNotifierProvider` to assert no exception is
thrown during mount would directly cover Bug 1's fix, but building one
would need a real `AppState` instance (its constructor pulls in
identity/config/fs/engine dependencies) and I can't run it to confirm it's
correct — flagging as a good next step rather than guessing blind.

**Status: fix complete, not pushed** (no GitHub credentials for
`johnchk250/Conduit` in this session — same limitation as before). Local
commit made after this checkpoint; happy to produce a patch/diff file
instead if that's easier to apply on your end.

---

## 2026-07-10 — Confirmed pushed to GitHub; added .gitignore

User applied `0001-adhoc-send-ui-fix.patch` via `git am` on their own
machine and pushed to `origin/main`. Verified from this side with a fresh
clone: both commits (`6164b3a` progress log, `a45f6d9` the actual fix) are
present on GitHub with the right content — spot-checked the epoch-guard
symbols and the deferred `clearPendingSharedFiles()` call are actually in
the pushed files, not just present in commit messages.

**Follow-up found while verifying:** the repo has **no `.gitignore`** at
all — makes sense, since it was being managed via GitHub's manual file
upload rather than git before now. This is a real risk given the workflow
now in place: `git add -A` (used earlier in this session) stages
everything with no exceptions, so once the user builds locally
(`flutter build windows`, `build_release.bat`, etc.), the `build/` output
folder and other generated junk would get swept into the repo on the next
`git add -A` + push unless something excludes it. Confirmed nothing like
that has happened yet — a fresh clone has no `build/`, `.dart_tool/`, or
similar tracked.

**Fix:** added a standard Flutter `.gitignore` (the one `flutter create`
would generate) plus a couple of project-specific entries:
- `/logs/` — `capture_pc.bat`/`capture_android.bat` write timestamped
  diagnostic logs here; not something to version.
- Windows/Linux desktop `ephemeral/`/generated-plugin-registrant paths,
  for completeness alongside the top-level `/build/` rule.

User has already built the Windows app locally on their machine (before
this .gitignore existed), so their local `build/` folder currently exists
un-tracked. Once they add this `.gitignore` and run `git status`, it
should now show as ignored rather than untracked — told them to verify
that as a sanity check.

**Files touched:** `.gitignore` (new), `PROGRESS.md`.
**Status:** committed locally on this side; handed the file to the user
directly (single new file, simpler than a patch) with `git add`/commit/push
instructions rather than another `.patch`, since I still have no push
credentials for their repo.

---

## 2026-07-11 — Investigated repeated peer-disconnect cycling during Android Doze / Battery Saver

User shared two Activity-log screenshots showing a repeating
disconnect → heartbeat-timeout → reconnect → sync → disconnect cycle
(roughly every 72–90s) while the Android phone's screen was off and
battery saver was active on the phone. One event includes the desktop-side
error `SocketException: The semaphore timeout period has expired (OS
Error, errno 121)`, address/port of the Android peer. Asked: is this
normal, and why does it repeat so often?

**Investigation (read-only, no code changes this session):**

- `lib/src/net/peer_session.dart`: app-level heartbeat is a fixed
  `_hbInterval = 12s`, `_hbMissedThreshold = 6` → exactly 72s of silence
  before a session is declared dead (`hb_dead`) and torn down. This lines
  up with the ~72–90s gaps in the screenshots.
- Android side already does the right AOSP-level things: `SyncService` is
  a proper foreground service (`foregroundServiceType="dataSync"`,
  `FOREGROUND_SERVICE_DATA_SYNC` permission, persistent notification), it
  owns the connection/transfer wake locks (post `b452888` fix) with a 45s
  renewal timer, holds a `MulticastLock` for discovery, and requests
  `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`. Per current Android docs
  (developer.android.com/training/monitoring-device-state/doze-standby),
  an app on that exemption list is allowed to use the network and hold
  partial wake locks *during* Doze — so on stock AOSP behavior alone this
  should be fairly resilient.
- **Found a real, undocumented behavior in `lib/src/app_state.dart`
  `_applyBeaconMode()` (line 591):**
  `_setConnectionWakeLockEnabled(anyLive && !_config.batterySaverMode)`.
  When Conduit's own in-app **"Battery saver mode"** toggle
  (`dashboard_screen.dart`, `config_store.dart`) is on, the connection
  wake lock is deliberately *never* acquired — even while a peer session
  is live. The UI subtitle for that toggle only mentions the 1-hour
  watcher poll cadence ("Scan folders every hour instead of every 4s...");
  it does not disclose that it also stops holding the CPU awake for an
  active connection. With that lock off, the CPU is free to deep-sleep
  mid-session, the Dart heartbeat timer stalls, the Windows side blocks on
  `send()` until its own internal timeout fires (the "semaphore timeout"
  error, errno 121 — classic symptom of the remote side going dark),
  and Conduit's own 72s heartbeat-dead timer then closes the session. As
  soon as any Android-side wakeup happens (motion, notification, etc.)
  discovery/reconnect brings it back up, syncs the backlog, and the same
  thing repeats — hence the tight, repeating cycle.
- If Conduit's in-app battery saver toggle is **off** and this is purely
  the *phone's OS-level* Battery Saver + Doze, the exemptions above should
  mostly hold on stock Android, but this is a very well-documented pain
  point on OEM skins (Samsung/Xiaomi/OnePlus-style extra battery managers
  layered on top of AOSP, tracked by projects like dontkillmyapp.com) that
  can still suspend network/CPU for a foreground service despite the
  standard exemptions being granted. Distinguishing which of these is
  happening for this user needs one more piece of info (whether Conduit's
  own battery-saver toggle was on) — asked in chat, not yet confirmed.

**Assessment:** the cyclical reconnect pattern itself is not data-unsafe
(the log shows a clean resync — "3 files in sync" / "2 files in sync" —
immediately after each reconnect), so it's a battery-vs-reliability
trade-off rather than a bug causing loss. But the in-app toggle's
undisclosed side effect is worth fixing — either by updating the UI
copy to be accurate, or by decoupling "relax watcher polling" from
"allow the live connection to be dropped during idle" into two clearly
separate behaviors.

**Files touched:** none (read-only investigation this session).
**Status:** diagnosis delivered in chat; no code change made yet — holding
until the user confirms which condition (in-app toggle vs. OS-level
Battery Saver alone) actually applies, since the right fix differs
(UI copy / behavior split vs. Android-settings guidance to the user).
Logged as a candidate follow-up item below.

**Follow-up candidates (not yet actioned):**
1. Split Conduit's "Battery saver mode" toggle behavior: keep the 1-hour
   watcher-polling relaxation, but stop it from silently disabling the
   connection wake lock for an already-live session — or make that
   consequence explicit in the UI subtitle.
2. Consider whether the heartbeat's fixed 72s dead-timer should be more
   forgiving specifically when Conduit's own battery-saver mode is
   active, since the user opted into a laxer, battery-first mode.

**Confirmed:** user has the in-app "Battery saver mode" toggle **on**.
Root cause is confirmed as hypothesis 4 in `THINKING.md` — the connection
wake lock is intentionally never held while that toggle is on, so any
live session is exposed to Doze and gets cycled roughly every 72s whenever
the phone is idle long enough for CPU sleep to actually stall the
heartbeat. Presenting fix-direction options to the user next; no code
changed yet pending their choice (see `THINKING.md` for the options laid
out).

---

## 2026-07-11 (continued) — New session, resuming the disconnect-cycling fix

**Environment notes (same as prior sessions):** no `flutter`/`dart` SDK, no
push credentials for `johnchk250/Conduit` — manual review + careful static
checking again, changes committed locally and handed over as
patch/file(s), same as every prior session.

**Housekeeping done first:**
- Re-cloned the repo fresh (`main`, up to date through commit `21f4c4d`).
- The 2026-07-11 disconnect-cycling investigation entry existed in the
  user-held copy of `PROGRESS.md` but had never actually been committed to
  the repo (that session was read-only, so nothing got committed) —
  appended it here now so the repo's own history is complete.
- `THINKING.md` (reasoning-trail companion log, mirroring this file) did
  not exist in the repo before now — added it, seeded with the existing
  reasoning trail for the disconnect-cycling investigation, plus a new
  entry below.

**Re-examined the two candidate fixes before writing code** (full
reasoning in `THINKING.md`): confirmed via re-reading `_applyBeaconMode()`
that the connection wake lock is *only ever requested while a peer session
is already live* — the idle-battery savings from battery-saver mode come
entirely from a separate mechanism (watcher poll interval +
discovery-lock timing), untouched by this fix. So decoupling "relax
watcher polling" from "let the live connection lock lapse" has no idle-
battery cost; it only changes behavior while a peer is actively connected,
where the current behavior is actively worse anyway (repeated
teardown/rediscover/resync every ~72–90s). Treating this as the
recommended default fix, paired with correcting the UI copy — asking the
user for a quick confirm rather than assuming, since it's a live behavior
change to their app.

**Plan for this session:**
1. ✅ Re-clone, reconcile `PROGRESS.md`, add `THINKING.md`.
2. ✅ Get user confirmation on fix direction — user picked the recommended
   option: decouple + fix UI copy.
3. ✅ Implement in `app_state.dart` (`_applyBeaconMode`). `dashboard_screen.dart`
   needed **no change** — its existing subtitle only ever described the
   watcher-polling cadence, never the connection lock, so it was already
   accurate once the undisclosed side effect was removed (confirmed by
   reading the widget before assuming a copy edit was needed).
4. ✅ Manually verified: `grep`'d every remaining `batterySaverMode` usage
   in `lib/` (6 hits) to confirm the removed conditional was the only
   coupling between battery-saver mode and the connection lock; confirmed
   `setBatterySaverMode()` already calls `_applyBeaconMode()`, so toggling
   the setting mid-session re-evaluates the lock immediately — no
   additional wiring needed for that path.
5. ✅ Updated `ARCHITECTURE.md` Appendix B (new 2026-07-11 row) and
   `Roadmap.md` Phase 0.6 row per project convention.
6. ✅ Committed locally, produced patch file for the user to apply + push
   (see below).

**Checkpoint — fix implemented:**

`lib/src/app_state.dart` `_applyBeaconMode()`: changed
`_setConnectionWakeLockEnabled(anyLive && !_config.batterySaverMode)` to
`_setConnectionWakeLockEnabled(anyLive)`, with an inline comment explaining
why (full reasoning in `THINKING.md`'s "weighing the two fix directions"
entry). This is a one-line behavioral change plus documentation; no other
source files were touched.

**Files touched this session:** `PROGRESS.md`, `THINKING.md` (new),
`lib/src/app_state.dart`, `ARCHITECTURE.md`, `Roadmap.md`.

**Not performed (same standing limitation as every prior session):**
`flutter analyze` / `flutter test` / a real build — no Flutter/Dart SDK or
Android toolchain in this environment. Verification here was manual
read-through of the changed function, its comment, and every call site of
`batterySaverMode` and `setBatterySaverMode()`. **Recommend running the
existing test suite and, ideally, a real-device idle/Doze soak test (phone
screen off, Battery saver mode on, watch the Activity log for the
disconnect cycle) before considering this closed.**

**Status: fix complete, committed locally, not pushed** (no push
credentials for `johnchk250/Conduit` in this environment — same limitation
as every prior session). Delivered as a patch file — see delivery note
below.

