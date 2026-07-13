# Work Progress Log (Claude session)

> Running log of what's been done, in-progress, and next. Updated at every
> checkpoint — never left in a half-written state. Newest entries at the top.

---

## 2026-07-12 (new session) — Clear-glass v6: flat backdrop + more-translucent panels (continuing an interrupted session)

**Context:** fresh sandbox, repo cloned to `/home/claude/work/Conduit`,
verified clean on `origin/main` at `bd032de` (the v5 commits from the prior
session — see `## 2026-07-12 — Clear-glass v5` entry below). The person
supplied a transcript (`Previous_agent_thinking.txt`) of a session that
started immediately after v5 landed: v5 was reported back as still not
matching expectation, this time against a reference screenshot the person
shared directly in that chat (not saved to this repo — I do not have the
image file itself, only the sampled color values recorded in that
transcript). That session sampled the reference image's colors and had
started editing `glass.dart` when it was interrupted before committing
anything — `git log` confirms none of that work reached `origin/main`. This
session picks up exactly where that one left off, using the colors it had
already locked in.

**What the reference called for** (per the interrupted session's own
sampling, taken as given rather than re-derived, since I don't have the
image): a flat, uniform background — no gradient, no animation — and panels
that are distinctly more see-through than v5's barely-there frost, with the
background clearly visible through them. Two color findings from that
session's pixel sampling:
- Flat background: consistent `RGB(39,81,106)` / `#27516A` across multiple
  open-area samples (margins, gaps between tiles).
- Tile fill: a subtle, consistent lightening of the same blue —
  `RGB(~35-36,91-92,125-127)` — not a white-tinted glass; a white-blend
  hypothesis was tested against the sample math and ruled out (red channel
  moved the wrong direction for a white mix).

**What I implemented in `lib/src/ui/glass.dart`:**
- `GlassColors`: replaced the 4-stop `bgTop/bgMid/bgMid2/bgBottom` gradient
  with a single flat `bg` field (`#27516A` dark). Removed `vignetteEdge`,
  `sweepCore`, `sweepEdge` — no longer meaningful once there's no gradient
  or sweep to shape.
- `panelFillA`/`panelFillB` (dark): switched from a white-alpha wash
  (0.09/0.02) to a light cyan-blue tint (`#8FD9FF`) at lower alpha
  (0.10/0.04) — matches the sampled tiles' hue family and pushes further
  toward "clearly see-through" per the ask. Exact-pixel reverse-engineering
  wasn't pursued (compressed screenshot, some samples landed on icon/edge
  artifacts per the transcript) — landed on a close, tasteful approximation
  instead, same call the interrupted session was already leaning toward.
- `borderBright`/`borderDim` (dark): bumped slightly (0.24→0.32,
  0.04→0.06) — with `BackdropFilter` gone (next point), the border is now
  the main thing that separates a panel's edge from the flat backdrop, so
  it needed to stay legible rather than getting softer.
- **Removed `BackdropFilter` from `_clearGlassSurface` entirely** (and the
  now-pointless `blurSigma` param from it, `GlassPanel`, and the
  `GlassNavBar`/`GlassNavRail` call sites that passed it). Once the backdrop
  is one flat color, blurring it is a no-op — blurring a uniform color
  returns that same uniform color — so this isn't a shortcut, it's the same
  visual result for zero per-frame cost. It also fully retires the Android
  flicker-risk category that v5's `Timer`-based sweep fix existed to
  manage: nothing left on screen re-samples/re-blurs on every paint.
- `GlassBackground`: converted from a `StatefulWidget` (Timer +
  `AnimatedAlign` driving the v5 light sweep) to a plain `StatelessWidget`
  painting one flat `DecoratedBox`. Removed `dart:async`/`dart:ui` imports
  from the file entirely — nothing left uses `Timer` or `ImageFilter`.
- Light mode: no reference image for it (same gap v5 had). Designed, not
  sampled — flattened the old 4-stop near-white gradient to one flat color
  (its old midpoint, `#E9E6F5`), and moved the fill alphas in the same
  "more see-through" direction (0.55/0.22 → 0.40/0.14) while staying high
  enough to read against a bright backdrop. Flagged in the code comment as
  unverified — please sanity-check once built.
- Updated `Roadmap.md`'s Phase 7 section and per-screen checklist row for
  `glass.dart` to describe v6 instead of v5, and confirmed (by grep, listed
  below) that `dashboard_screen.dart`'s row needed no code change since it
  only touches the shared widgets' public API.

**`dashboard_screen.dart`: not touched.** It only calls
`GlassColors.of(context)` and reads `c.violet/amber/teal/blue/mint/
textPrimary/textSecondary/textTertiary` (confirmed by grep — none of those
fields were removed or renamed), plus the `GlassPanel`/`GlassListTile`/
`GlassStatusBanner`/`GlassChip`/`GlassSectionLabel`/`GlassNavBar`/
`GlassNavRail` widgets by their existing public constructors. No
`blurSigma` or gradient-field references anywhere in it. Re-touching it
would have been a no-op edit, so it was left alone.

**Verification performed** (no Flutter/Dart SDK in this sandbox, same
standing limitation as every session in this log):
- Balanced-delimiter check (Python, brace/paren/bracket counts) on
  `glass.dart` after every edit — clean throughout.
- Same check swept across all of `lib/**/*.dart` at the end of the session:
  two pre-existing imbalances flagged in `activity_screen.dart` and
  `lib/src/sync/file_send.dart` — **neither file was touched this session**
  (confirmed via `git status --short`, which shows only `glass.dart`
  modified), so these are pre-existing false positives from unbalanced
  string literals, not a regression from this session's edits.
- Full top-to-bottom re-read of the rewritten `glass.dart`.
- Repo-wide grep for `GlassPanel(`, `blurSigma`, and every removed
  `GlassColors` field name (`.bgTop`, `.bgMid`, `.bgBottom`, `.vignetteEdge`,
  `.sweepCore`, `.sweepEdge`) across all of `lib/src/ui/*.dart` — zero hits
  outside `glass.dart` itself, confirming no other screen references
  anything that got removed.
- **Not verified:** an actual `flutter run`/`flutter analyze`, or a
  rendered screenshot to visually confirm the flat background and panel
  translucency actually match the reference image — no such tooling in
  this sandbox, and (unlike the v5 session) I never saw the reference image
  myself, only its already-sampled color values from the transcript.
  **Please build and run, and compare Overview against your reference
  screenshot directly** — if the fill still doesn't read right, the fastest
  path is re-sharing that image in a follow-up so the color sampling can be
  redone directly rather than relayed through a transcript.

**Files touched:** `lib/src/ui/glass.dart`, `Roadmap.md`, `PROGRESS.md`,
`THINKING.md`.

**Not done this session:** no other screen was converted — same 9 files
listed as `⬜ not started` in `Roadmap.md` before this session are still
untouched (they were never glass to begin with, so v6's changes don't
affect their status either way).

**Status: implementation complete for the v6 token/component rewrite,
verified by static analysis only (no SDK in this sandbox) — please
`flutter run` on Windows and Android and compare Overview against your
reference image before merging. Delivered as a `git format-patch` series
you can apply and push yourself — see delivery note at the end of this
session for the exact commands (no push credentials for
`johnchk250/Conduit` in this sandbox, same limitation as every prior
session).**

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

---

## 2026-07-11 (continued) — Confirmed pushed to GitHub

User applied both patches (`0001-progress-reconcile-disconnect-cycling...`,
`0002-fix-decouple-battery-saver-mode...`) via `git am` on their own
machine and pushed. Verified from this side with `git fetch origin` +
`git log origin/main`: both commits present —
`fd36436` (progress/THINKING reconcile) and `ca03805` (the actual fix) —
on top of the prior tip `21f4c4d`. Didn't stop at the commit log:
`git show origin/main:lib/src/app_state.dart` confirms the real code
change (`_setConnectionWakeLockEnabled(anyLive)`, no longer gated on
`batterySaverMode`) is present in the pushed file, and
`git show origin/main:ARCHITECTURE.md` / `:Roadmap.md` confirm both
doc updates landed too — not just asserted from the local commit, actually
read back from the remote.

**Files touched:** none this checkpoint (verification only).
**Status:** disconnect-cycling fix is live on `origin/main`. This
checkpoint entry itself was late — it was described in chat before it was
actually written here; corrected once flagged.


## 2026-07-11 (new session) — Clipboard "write failed" notification firing incorrectly

**Environment notes (same as prior sessions):** no `flutter`/`dart` SDK, no
push credentials for `johnchk250/Conduit` in this environment — manual
review + static reading, changes (if any) committed locally and handed
over as patch/file(s) for the user to apply and push themselves.

**Task handed off by user (this session):** repo re-cloned fresh. New bug
report — the PC→phone clipboard sync notification that's supposed to
appear only when the clipboard *couldn't* be written on the Android
device is instead appearing inconsistently, including cases where the
write actually succeeded and synced fine.

**Plan:**
1. Locate the clipboard-write path and the notification-trigger logic —
   likely `lib/src/clipboard/clipboard_sync.dart` +
   `lib/src/notifications/notifier.dart`, cross-checked against the
   Android platform channel in `MainActivity.kt`.
2. Read the actual write call and trace exactly what condition raises the
   "couldn't write" notification — success/failure signal, exception
   handling, timing/race conditions, platform-channel return values.
3. Identify why a successful write could still trip the failure path
   (stale state read, wrong return-value check, exception swallowed
   then treated as failure, async race between write result and
   notification decision, etc).
4. Write up root cause with cited line references before proposing a fix
   — confirm with user before changing behavior, per project convention
   in existing `PROGRESS.md`/`THINKING.md` history.

**Status: investigation starting now.**

## 2026-07-11 (continued) — Root cause found: false "clipboard couldn't be written" notification

**Root cause (full reasoning in `THINKING.md`):** `onPushReceived` in
`lib/src/clipboard/clipboard_sync.dart` writes via a native Android
channel that deliberately bypasses focus restrictions (`applicationContext`
→ `ClipboardManager`, see `MainActivity.kt` `CH_CLIPBOARD`), then
*verifies* that write by reading back through Flutter's own
`Clipboard.getData()` — the Activity-bound API the native write path was
specifically built to avoid. Verified against real Android platform
behavior (Android 10+ restricts clipboard *reads* to the focused app or
default IME, with no carve-out for the app that just wrote it, and a
foreground service does not count as focus). So the write succeeds
regardless of app focus, but the verify-read is denied whenever the app
isn't focused — i.e. almost every time this path is actually used
(backgrounded receive via the sync service) — causing `app_state.dart` to
treat a successful write as "blocked" and fire
`showClipboardSyncReceived` anyway. Whether the false notification
appears depends on whether Conduit happened to have focus at that
instant, matching the "inconsistent" symptom exactly.

Also checked: the native write path already correctly surfaces genuine
failures as a thrown `PlatformException` (Kotlin `result.error(...)` on a
`setPrimaryClip()` exception), which `onPushReceived`'s existing
`catch (e)` block already handles correctly. So the readback-based verify
step contributes no real failure detection on Android — only false
negatives.

**Proposed fix:** on Android, treat "native write call returned without
throwing" as success (skip the readback comparison); keep the existing
readback-based verify for non-Android platforms, where no such
OS-level read restriction exists. One documented trade-off: this would no
longer catch a hypothetical silent OEM/enterprise policy block that
doesn't throw — rarer than the reported bug, and consistent with how the
rest of this path already trusts the platform channel's exception
signal, but flagging it rather than claiming the fix is airtight.

**Status: root cause confirmed, fix proposed, no code changed yet** —
per project convention, confirming direction with the user before editing
`clipboard_sync.dart`.

## 2026-07-11 (continued) — Fix implemented

User confirmed: implement the proposed fix.

**Changes made:**
- `lib/src/clipboard/clipboard_sync.dart` — `onPushReceived`: on phone
  (`!isDesktopPlatform`), the write call completing without throwing is now
  treated as success; the readback-based verify (unreliable on Android per
  the root-cause analysis) is only used on desktop, where no OS read
  restriction applies. Doc comment added explaining both branches.
- `lib/src/notifications/notifier.dart` — refined `showClipboardSyncReceived`'s
  doc comment: "blocked" is now accurately defined as "the write call threw",
  not "the readback disagreed".
- `test/clipboard_sync_test.dart` — the three existing background-write
  tests were re-based on a corrected fake:
  - `_BlockedWriteClipboard` (modeled "write silently no-ops in the
    background", which doesn't reflect the real native write path) replaced
    by `_FailingWriteClipboard` (models a genuine thrown write failure —
    the one real failure mode the native channel can hit).
  - Added `_FocusRestrictedReadClipboard` (models Android's actual read
    restriction: write genuinely succeeds, readback is always denied) plus
    a new regression test asserting `pendingRemoteText` clears on a
    successful phone write even when the readback would be denied — this
    is the direct test for the reported bug.
  - Net: 3 tests re-based (not deleted, still cover genuine-failure +
    onResume + setEnabled(false) paths), 1 new test added.
- `ARCHITECTURE.md` — new Appendix B row (2026-07-11) documenting root
  cause + fix; header status line updated (155 tests: 154 prior + 1 new,
  not independently re-run — no Flutter toolchain here).
- `Roadmap.md` — short note added under the Phase 2 status line pointing to
  the fix.

**Verification performed (same standing limitation as every prior
session):** no `flutter`/`dart` SDK in this environment — could not run
`flutter analyze` / `flutter test` / a real build. Verification here was:
manual read-through of the changed method and every call site of
`isDesktopPlatform`/`_isDesktopPlatform` in both the source file and the
test file; a balanced-delimiter (braces/parens/brackets) sanity check on
both edited Dart files; re-read of every test in the "background write
recovery" group after editing to confirm none still reference the removed
`_BlockedWriteClipboard` class. **Recommend running the real test suite
and a real-device backgrounded-receive test (push from PC while the phone
is asleep/unfocused) before merging.**

**Status: fix complete, ready to commit locally and hand off as a patch**
(no push credentials for `johnchk250/Conduit` in this environment — same
limitation as every prior session).

## 2026-07-11 (new session) — Phase 6 scoping: ignore rules + version-restore UI

**Task:** from the uploaded `2026-07-11-phase6-planning.md` doc, implement only
two of the four proposed items: **ignore rules** (§4) and **version-restore UI**
(§5). Explicitly deferring sync preview (§3) and quick-setup wizard (§6) — not
requested this session. User priority: do not disturb or corrupt the working
app; verify workability before any critical change.

**Repo state confirmed on clone:** `main` at `490350e` (clipboard notification
fix), clean working tree, up to date with `origin/main`. The wake-lock fix from
the 2026-07-10 handoff doc is confirmed landed (`b452888`) and the project has
moved through two further sessions (disconnect-cycling fix `ca03805`,
clipboard fix `490350e`) since that handoff — memory of "not yet confirmed
pushed" is stale; it did land.

**Investigation performed before writing any code** (per project convention —
verify claims against actual source, not just the planning doc):

- `lib/src/sync/scanner.dart` — confirmed the plan's claimed injection point
  (`_isInternalArtefact` check, scanner.dart:87) is accurate. Ignore-rule
  matching will slot in immediately after it, before hashing.
- `lib/src/protocol/wire.dart` — confirmed `FolderPair`'s current shape
  (`id`, `name`, `localPath`, `direction`, `peerDeviceId`); the plan's proposed
  three new optional fields (`ignoreGlobs`, `ignoreExtensions`,
  `maxFileSizeBytes`) fit the existing nullable/default pattern used by
  `peerDeviceId`.
- `lib/src/sync/engine.dart` — confirmed both call sites of `_scanner.scan()`
  (`startPair` line ~383, `reconcile` line ~780) already have `pair` in scope,
  so ignore rules can flow through without any new plumbing at the call site.
- **Important finding not in the planning doc:** `startPair(pair)` closes over
  the `pair` object in the watcher's change-listener closure and the periodic
  reconcile timer closure. This means editing a pair's ignore rules and
  persisting via `_config.upsertPair` alone would NOT take effect until app
  restart — the running closures would keep using the stale `FolderPair` with
  the old (or absent) ignore rules. Fix: the ignore-rules editor must call
  `engine.stopPair(id)` then `engine.startPair(updatedPair)` after persisting,
  the same restart-the-watcher pattern already used implicitly when a pair is
  first added. Confirmed `stopPair` is designed for exactly this
  (cancels watcher/timer, closes + drops the Index DB handle, drops per-pair
  V2 bookkeeping) and is safe to call before `startPair` re-adds the same id.
- `lib/src/sync/manifest.dart` / `lib/src/platform/saf_access.dart` — confirmed
  `moveToVault(rootPath, relPath)` exists on both platforms and is genuinely
  dead code (grepped every call site in `lib/src/`, matches the plan's
  finding). Confirmed the Android native side also exists
  (`SafOps.kt:249`), so the Dart-side call is not stubbed against a missing
  native handler.
- `lib/src/sync/block_transfer.dart` — confirmed `_replacePartWithFinal`
  (block_transfer.dart:225) is the single choke point for both platform
  branches (`LocalFileSystemAccess` direct-rename path and the generic
  SAF write+delete path) where a fetched file overwrites an existing one.
  This is the intended vault hook for "restore a previous version of an
  edited file." Not on the do-not-touch list.
- `Roadmap.md` §0 — re-confirmed the project's own hard constraint:
  `_applyRemoteTombstone` is explicitly listed as must-not-touch. The
  planning doc's option (a) for delete-restore (a try/caught vault line
  inside `_applyRemoteTombstone`/`_propagateRemoteDeletes`) would violate
  that constraint directly. Given the explicit "don't disturb the working
  app" priority this session, proceeding with the plan's own recommended
  **option (b): edit-restore only, delete-restore out of scope for this
  pass.** This isn't treated as an open question — the project's existing
  hard constraint already answers it.
- `pubspec.yaml` — confirmed no glob-matching package present. No
  `flutter`/`dart` SDK and no pub.dev network access in this sandbox
  (network egress is allowlisted to a fixed domain list that does not
  include pub.dev), so a new dependency (`glob: ^2.1.2`, as the plan
  suggests) cannot be fetched or verified to resolve here. Deviating from
  the plan on this one point: implementing a small self-contained glob→regex
  matcher in Dart (supporting `*`, `**`, `?`, literal segments — the subset
  actually needed for ignore patterns) instead of adding an unverifiable new
  dependency. Lower risk, fully testable in this environment, easy to swap
  for the real `glob` package later if desired.
- `lib/src/ui/folder_pairs_screen.dart` — confirmed `_PairDetailScreen`
  (line 384) is the natural place to add "Ignore rules" and "Restore
  versions" entry points, consistent with where Sync Now / file list already
  live per-pair.
- `test/scanner_test.dart`, `test/block_transfer_test.dart` — confirmed test
  patterns (fake in-memory FS + real FFI SQLite `IndexDb` for scanner tests;
  similar fake-transport style for block_transfer tests). New tests will
  follow the same style. As with every prior session, no Flutter/Dart SDK
  here to actually run the suite — verification will be manual read-through
  plus hand-traced test cases, flagged clearly as unrun.

**Open question sent to the user before writing code:** retroactive-ignore
semantics (Roadmap plan §4.4) — when a rule is added after matching files are
already synced, should those files be frozen in place (recommended: stop
tracking further local edits, never tombstoned/deleted) or actively
tombstoned and delete-propagated to the peer (files disappear from both
sides)? This has real data-safety consequences (wrong choice = surprise
deletes on a peer device) so confirming before implementation rather than
assuming, per this session's explicit "don't corrupt the working app" ask.

**Status: investigation complete, no code changed yet.** Awaiting the
retroactive-ignore answer above before touching `scanner.dart`/`wire.dart`.

## 2026-07-11 (continued) — Ignore rules + version-restore implemented

**Both features fully implemented, tested (by hand-trace — no SDK available),
and documented.** Full technical writeup lives in `ARCHITECTURE.md` Appendix B
(2026-07-11 Phase 6 entry) and `Roadmap.md` §3 Phase 6 — this entry is a
shorter work-log pointer to that, plus anything not already captured there.

**Ignore rules (6.2):** implemented per the confirmed decision (freeze, don't
tombstone). New `ignore_rules.dart` (hand-rolled glob matcher — no `glob` pub
dependency, sandbox has no SDK/pub.dev access to verify one against), wired
into `scanner.dart`, `wire.dart` (`FolderPair` schema), `engine.dart` (both
scan call sites), `app_state.dart` (`updateIgnoreRules`, explicitly restarts
the pair's watcher — see THINKING.md for why), `folder_pairs_screen.dart`
(editor dialog).

**Version-restore (6.4), edit-only scope:** implemented per the doc's own
recommended option (b) — restoring a *deleted* file was ruled out without
needing to ask, since it requires touching `_applyRemoteTombstone`, already on
the do-not-touch list. `block_transfer.dart`'s `_replacePartWithFinal` now
vaults an existing file before an incoming fetch overwrites it (best-effort,
never blocks the transfer on failure). New `vault_log.dart` (per-pair JSON
catalog, deliberately not a `.syncversions/` directory listing — see below).
New `AppState.restoreVersion` + `version_history_screen.dart` UI.

**Bug caught and fixed during implementation, before it shipped:**
`LocalFileSystemAccess.moveToVault` returned an *absolute* path while the
Android SAF native implementation returned a *relative* one. This had zero
effect before this session (zero callers), but would have broken cross-
platform restore inconsistently once `_replacePartWithFinal` started
depending on the return value. Fixed both (duplicated) `manifest.dart` copies
to return a `rootPath`-relative path, matching SAF's convention — verified
safe to change precisely because nothing consumed the return value before
this session (confirmed by grep before making the change, not assumed).

**Also caught and fixed:** the vault-log entry's `sizeBytes` was initially
wired to the *incoming* peer file's size instead of the *vaulted (old)* file's
size — caught on self-review before finalizing, not by the person. Fixed by
changing `_replacePartWithFinal`'s `onVaulted` callback to a two-arg
`(vaultPath, oldSizeBytes)` signature, threading the correct value through
from both platform branches.

**Why version-restore needed no new native Android code:** `FileSystemAccess
.listFiles` (both platforms) already filters out `.syncversions/` — existing,
load-bearing scanner behavior, confirmed by reading both `manifest.dart` and
`SafOps.kt` before assuming. Writing new Kotlin to list vault contents would
mean shipping unverifiable native code (no Android SDK/emulator in this
sandbox to build or test it against). Instead, `vault_log.dart` keeps its own
small catalog of "what got vaulted and when," written purely on the Dart side,
and restore reads a *specific known* vaulted path back through the existing
`stat`/`openRead` native handlers — confirmed by reading `SafOps.kt` that
those resolve an exact path with no directory-level filtering, so no new
native code was needed at all.

**Pre-existing latent gap found, not fixed (out of scope):** the existing
pair-edit dialog's `addFolderPair` call is a no-op on the engine for an
already-running pair (`startPair`'s `if (_watchers.containsKey(...)) return`
guard) — editing name/localPath/direction on a live pair silently doesn't
take effect until app restart. Found while checking whether `updateIgnoreRules`
could reuse that path (it can't, for the same reason) — noted here and in
`Roadmap.md`/`ARCHITECTURE.md` for visibility, deliberately not fixed since
it's unrelated to this session's two requested features and touching it risks
scope creep into working code.

**Test-count bookkeeping:** actual baseline going into this session was 153
tests (verified directly against commit `490350e`, not trusted from
`ARCHITECTURE.md`'s prose, which claimed 154/155 in different places — another
small instance of the project's own "audit source, don't trust docs" principle
paying off). 39 new tests added (`ignore_rules_test.dart` 16,
`vault_log_test.dart` 8, `local_fs_access_test.dart` 7, +6 in
`scanner_test.dart`, +2 in `block_transfer_test.dart`) → 192 total. None of
this was run — no Flutter/Dart SDK in this sandbox, same constraint as every
prior session. Verification was: hand-tracing every test's expected outcome
against the exact algorithm (the glob matcher was additionally cross-checked
against a Python mirror of the same character-by-character translation logic,
since that's the one piece of new logic complex enough to be worth an
independent check); re-viewing every touched file in full after editing;
balanced-delimiter checks on every touched/new file; grepping for every call
site of every changed function signature to confirm no caller was missed;
and confirming every existing test fixture's `FileSystemAccess` fake that
stubs `moveToVault` (several across the suite, in files unrelated to this
session) is safe by construction under the new best-effort try/catch design,
whether it throws or no-ops.

**Docs updated:** `Roadmap.md` new Phase 6 section (6.1/6.3 marked not
started — out of scope this session; 6.2/6.4 marked complete with full
detail). `ARCHITECTURE.md` module map, test count, Appendix A (new test files
+ expanded coverage notes on existing ones), Appendix B (full changelog
entry). Copied the uploaded planning doc into `docs/2026-07-11-phase6-
planning.md` so the paths referenced throughout the new code comments and
docs actually resolve in the repo.

**Status: implementation complete for the two requested features.**
Delivered as downloadable files/patches (no direct GitHub push access, per
usual). Recommend, before merging: `flutter analyze` + `flutter test` (192
expected), and a manual pass — add an ignore rule and confirm an
already-synced file freezes rather than disappearing from the peer; edit the
same file from both devices to force a same-file overwrite and confirm the
old version shows up in "Restore versions" on both Windows and Android
(SAF's `moveToVault` path in particular, since that native code could not be
built or run here).

## 2026-07-12 — Liquid-glass UI redesign, resumed (dashboard shell converted)

**Context:** a prior session designed and built `lib/src/ui/glass.dart` (the
shared liquid-glass token/component library — `GlassColors`, `GlassBackground`,
`GlassPanel`, `GlassListTile`, `GlassStatusBanner`, `GlassChip`, `GlassButton`,
`GlassNavBar`/`GlassNavRail`) and had fully scanned `dashboard_screen.dart`
(NavRail, OverviewPage, SettingsHubPage, HeroBanner, InviteDialog) in
preparation for converting it, but that session ended before either the
library or any converted screen was ever committed — confirmed by `git log`
(no glass-related commits) and `grep -ri glass lib/` (zero real hits before
this session, only an unrelated `Icons.hourglass_top` false-positive). Picked
back up from the uploaded `glass.dart` + the previous session's thinking-log
export rather than redoing that design work.

**Landed this session:**
- `lib/src/ui/glass.dart` — added to the repo verbatim (uploaded file), no
  changes needed. It was already complete and self-contained.
- `lib/src/ui/dashboard_screen.dart` — fully converted, the one file the prior
  session had already scanned in full:
  - Wide layout: `NavigationRail` → `GlassNavRail` (`_NavRail` rebuilt on
    `GlassNavRail` + `GlassButton` for Pause/Resume/Quit); the adjacent
    `VerticalDivider` was dropped since a floating bordered rail doesn't need
    a hard-line neighbor.
  - Phone layout: `NavigationBar` → `GlassNavBar`; `Scaffold.extendBody` is
    now `true` so page content scrolls underneath the floating bar, with a
    90px bottom `SizedBox` on both list pages so the last row is never
    covered.
  - `_OverviewPage`: `_HeroBanner` (removed — fully superseded) →
    `GlassStatusBanner`; every `Card(ListTile(...))` → `GlassListTile`;
    device status `Chip`s → `GlassChip`. `Scaffold`/`AppBar` made
    transparent so the single shared `GlassBackground` (mounted once, in the
    shell around the NavRail/NavBar) shows through.
  - `_SettingsHubPage`: same treatment. The one deliberate behavior change —
    documented inline — is the "received files folder unset" warning, which
    used to be red subtitle text and is now a `GlassChip("Required")` in the
    trailing slot, since `GlassListTile`'s subtitle color isn't overridable
    per-instance. Judged as a clearer signal, not just a style-forced swap.
  - `SwitchListTile` → `GlassListTile` with a plain `Switch` in the trailing
    slot (no glass-styled switch exists in the component library; this is a
    reasonable extension of the pattern already established for the "trailing
    can be anything" slot, not a new component).
  - `_InviteDialog` (an `AlertDialog`) left untouched, per `glass.dart`'s own
    documented intent: modal surfaces stay standard Material for legibility,
    glass is for persistent chrome and content cards.
- `Switch` styling uses `activeThumbColor`, not the older `activeColor` —
  checked current Flutter API docs before writing it, since `activeColor` was
  deprecated (in favor of `activeThumbColor`/`activeTrackColor`) after Flutter
  3.31, and this project's Flutter is likely past that line given the current
  date.

**Verification (no Flutter/Dart SDK in this sandbox, same constraint as every
prior session — `which dart flutter` confirmed empty):**
- Balanced-delimiter check (custom Python scanner) on both
  `dashboard_screen.dart` and `glass.dart` — clean.
- Grepped for every Material widget this pass was supposed to remove
  (`Card(`, bare `ListTile(`, `SwitchListTile`, bare `Chip(`,
  `NavigationRail(`, `NavigationBar(`) inside `dashboard_screen.dart` — zero
  real hits (only a doc-comment mention of the old pattern).
- Re-viewed the entire edited file top to bottom after all edits to catch
  anything a mechanical check wouldn't (mismatched named-parameter renames,
  a stray `Colors.x` that should've become `c.x`, etc.).
- Not verified: actually running `flutter analyze` / `flutter test` / a real
  build. Recommend both before merging, plus a manual look on an actual
  device/emulator — this is a visual redesign, and no screenshot tool exists
  in this sandbox to self-check the rendered result.

**Deliberately NOT touched this session (full inventory, for continuity):**
`folder_pairs_screen.dart`, `pairing_screen.dart`, `remote_control_screen.dart`,
`send_flow_view.dart`, `send_panel.dart`, `send_widget_screen.dart`,
`clipboard_screen.dart`, `activity_screen.dart`, `version_history_screen.dart`
— all still 100% standard Material, none reference `glass.dart` yet. This
was a scope decision, not an oversight: converting all ~11 UI files
(≈4,900 lines) to a hand-verified (no-compiler) standard in one pass risks
shipping something broken across the whole app at once, versus one screen at
a time, each independently checkable. `dashboard_screen.dart` was chosen
first because it's the app's always-mounted root shell (nav rail/bar +
Overview + Settings) and because the prior session had already fully read it.
See `Roadmap.md` Phase 7 for the remaining per-screen checklist.

**Status: dashboard shell (nav + Overview + Settings) is fully glass. Rest of
the app is unconverted and functionally unaffected — everything outside
`dashboard_screen.dart` still builds on stock Material and hasn't been
touched.** Delivered as downloadable files/a git patch (no direct GitHub push
access from this sandbox, per usual); the person applies and commits locally.

---

## 2026-07-12 (new session) — Windows build broken by `activeThumbColor`: fixed

**User report:** `flutter build windows` failing with
`error GC6690633: No named parameter with the name 'activeThumbColor'` at
`dashboard_screen.dart:850` and `:867` (screenshot of the terminal output),
cascading into MSB8066 custom-build-step failures — those cascade errors are
just downstream consequences of the Dart compile error, not a separate bug.

**Root cause:** the prior (2026-07-12, same-day) session's glass-UI conversion
used `Switch(..., activeThumbColor: c.teal)`, reasoning in this file that
`activeColor` was deprecated "after Flutter 3.31" in favor of
`activeThumbColor`. That reasoning was correct about Flutter's own direction,
but wrong about which stable release actually shipped it — checked against
current Flutter release notes this session: `activeThumbColor` landed in the
**3.35.0** stable release (PR flutter/flutter#166382), not 3.31. This repo's
`pubspec.yaml` pins `environment.sdk: ^3.6.0` (Dart), which pairs with a
Flutter release well before 3.35 — so the local Flutter SDK genuinely doesn't
have that parameter yet, matching the exact compiler error.

**Fix:** reverted both `Switch` call sites in `dashboard_screen.dart` from
`activeThumbColor: c.teal` back to `activeColor: c.teal` — the older,
non-deprecated-on-this-SDK-version parameter, present on every Flutter
release including whatever this project is actually pinned to. On Flutter
3.35+ this will show as a deprecation warning (not an error) rather than
failing the build; on anything before 3.35 (this project's case) it's simply
correct, non-deprecated usage. This is the appropriate fix without knowing
the exact installed Flutter version — `activeColor` works everywhere.

**Verification performed:** `grep -rn "activeThumbColor|activeTrackColor"
lib/` across the whole tree — zero remaining hits (only the two call sites
existed, both fixed). Balanced-delimiter check (custom Python scanner) on the
edited file — clean. No Flutter/Dart SDK in this sandbox (same standing
limitation as every session), so this is still a manual-review fix, not a
verified `flutter build windows` pass — **please re-run your build to
confirm**, but this is a one-line-times-two, low-risk, high-confidence fix
for the exact error message reported.

**Also set up this session (infrastructure, not app code):** the person asked
for a persistently-tracked, git-friendly workflow — cloned the repo fresh
into this sandbox, confirmed this `PROGRESS.md`/`THINKING.md` pair already
existed as the running work-log (continuing the existing convention rather
than creating a new one), and is delivering this fix as a git patch file
(`0001-fix-switch-activeColor-windows-build.patch`) plus the full modified
repo as a zip, both placed in the chat's Files panel for download.

**Files touched:** `lib/src/ui/dashboard_screen.dart`, `PROGRESS.md`,
`THINKING.md`.

**Status: fix complete, committed locally, not pushed** (no push credentials
for `johnchk250/Conduit` in this sandbox — same limitation as every prior
session). Delivered as a patch file to apply via `git am` on your machine,
plus a full repo zip as a fallback — see delivery note in chat.

---

## 2026-07-12 (new session) — Settings glass UI: color vibrancy + Android flicker/perf fix

**User report:** two screenshots. (1) A phone Control Center for reference —
colorful, distinct frosted modules (WiFi blue, Focus indigo, Flashlight
warm-white, etc.). (2) Conduit's actual Settings screen on Windows — flat,
uniformly dark cards with almost no color, "not quite what I had in mind,
looks ugly." Also reported: on Android, the glass UI flickers and makes the
app feel slower.

**Root causes found (both in `lib/src/ui/glass.dart`), not stylistic
guesses:**

1. **Color never reached the glass.** `GlassListTile` already computes a
   per-row `accentColor` (violet for storage/activity-log/keep-alive, teal
   for status-bar/battery-saver — see `_SettingsHubPage` in
   `dashboard_screen.dart`), but never forwarded it to the `GlassPanel`
   underneath. `GlassPanel` itself only used `accentColor` for a soft outer
   drop-shadow — its actual fill gradient was always the same flat
   white-based `panelFillA`/`panelFillB` regardless of accent. Net effect:
   every row's icon chip was correctly colored, but the glass card behind
   it never was — hence the flat, monochrome look in the screenshot despite
   the color data already existing in the code.
2. **The ambient background never stopped animating.** `GlassBackground`
   drove its three drifting color blobs with a `SingleTickerProviderStateMixin`
   `AnimationController` on `repeat(reverse: true)` — regardless of its 28s
   duration, this ticks and repaints at a full 60fps forever. Every
   `GlassPanel`/`GlassListTile`/`GlassNavBar`/`GlassNavRail` on screen uses
   `BackdropFilter`, which re-samples and re-blurs whatever's beneath it on
   every paint it's asked to do. With the background never idle, all ~6
   stacked blur layers on the Settings screen were forced to redo an
   18-24 sigma Gaussian blur pass 60 times a second, forever — even while
   sitting on a completely static screen. That sustained, uncapped
   CPU/GPU load (worse on Android's rasterizer than Windows) is what reads
   as flicker/slowdown.

**Fixes applied (`lib/src/ui/glass.dart` only):**
- `GlassPanel`: when `accentColor` is set, the fill gradient now uses
  `accentColor.withValues(alpha: 0.20/0.07)` directly instead of the flat
  white-based fill, plus a light accent lerp into the top border. Alphas
  deliberately kept low so panels stay translucent glass, not solid-color
  cards — the earlier "flashy" pass's mistake was saturation/opacity, not
  the presence of color itself.
- `GlassListTile`: now forwards its computed `accentColor` into the inner
  `GlassPanel` (previously silently dropped).
- `GlassBackground`: replaced the perpetual 60fps `AnimationController` with
  a `Timer.periodic` (10s) that toggles a target position, eased via
  `AnimatedAlign` (an implicit animation, 4s ease). Net effect: the
  background — and every blur layer above it — now only repaints during
  short ~4s ease windows and sits fully static the other ~6s of each cycle,
  cutting sustained animation/re-blur load by roughly 60-65% versus before,
  with no visible loss of the "living ambient" effect.
- Updated `glass.dart`'s top-of-file design-intent doc comment, which
  explicitly described the flat/dim, always-animating design being
  replaced — left stale, it would have misled the next session.

**Checked but left alone:** `folder_pairs_screen.dart` has one other
`AnimationController.repeat()` (a loading-spinner rotation), but it's
condition-gated (`if (!isAnimating) repeat() else stop()`) and that screen
isn't glass-converted yet per the existing Phase 7 plan, so it isn't sitting
under any `BackdropFilter` and isn't part of this bug — confirmed via grep
across `lib/`, not assumed.

**Verification (same standing constraint as every prior session — no
Flutter/Dart SDK in this sandbox, `which flutter dart` confirmed empty):**
- Balanced-delimiter check (custom Python scanner) on the edited file —
  clean, before and after each edit.
- Full top-to-bottom re-read of the edited file after all changes.
- Grepped for every remaining `AnimationController`/`.repeat(` in `lib/` to
  confirm no other perpetual-animation source was missed.
- Not verified: an actual `flutter run` on Android to confirm the flicker
  is gone, or a rendered screenshot to visually confirm the new colors match
  intent — no screenshot/build tooling in this sandbox. **Please build and
  run on your Android device to confirm the flicker is resolved**, and take
  a look at Settings to confirm the color balance reads right (the exact
  tint alphas — 0.20/0.07 — are a reasonable starting point, not a
  pixel-matched copy of the Control Center reference, and are easy to
  nudge in `GlassPanel` if you want it more or less saturated).

**Not touched, flagged for a future pass if still wanted:** the deeper
architectural option of consolidating all of a screen's `BackdropFilter`s
into one shared blur pass (instead of one per tile) would cut cost further
still, but changes the visual structure (one frosted sheet vs. distinct
floating modules) and touches more call sites — scoped out this session in
favor of the lower-risk, more targeted fix above, consistent with this
project's usual one-bounded-change-at-a-time approach. Worth
revisiting only if the Timer/AnimatedAlign fix alone isn't enough on your
actual Android hardware.

**Files touched:** `lib/src/ui/glass.dart`, `PROGRESS.md`, `THINKING.md`.

**Status: fix complete, verified by static analysis only (no SDK in this
sandbox) — please `flutter run` on your Windows and Android targets to
confirm before merging.** Not committed or pushed (no local git identity
configured in this sandbox and no push credentials for
`johnchk250/Conduit`, same limitation as every prior session). Delivered as
a git patch file plus a full repo copy — see delivery note in chat.

---

## 2026-07-12 (new session) — Clear-glass v5: `glass.dart` rewrite + Overview re-touch

**User report:** the previous session's "vibrancy" fix (see the entry just
above this one) didn't land — reported back as "that didn't work out
great." The person supplied a fully worked static mockup
(`overview_redesign_preview_v5.html`) plus a **detailed written execution
plan** (`2026-07-12-clear-glass-v5-plan.md`, now committed at
`docs/2026-07-12-clear-glass-v5-plan.md`) that reverse-engineers every token
and structural decision out of that mockup and maps it onto this file. This
session's instruction was explicit: implement that plan as given, not
design a new one.

**What "clear-glass v5" changes, in one sentence:** color moves out of the
glass fill entirely — the panel/nav surface itself is always a neutral,
barely-there frost, and color instead lives only in icon-chip
borders/strokes, the hero status ring, and filled pills. This is a partial,
deliberate reversal of the immediately-prior "vibrancy" session (which
tinted panel fills/borders per accent) — called out explicitly here and in
`glass.dart`'s own doc comment so it doesn't read as accidentally
regressing that session's work.

**`lib/src/ui/glass.dart` — full rewrite, following the plan section by
section:**
- `GlassColors`: removed the five now-dead `*Glow` fields (only ever fed the
  removed background blobs); replaced the 3-stop near-black backdrop
  (`bgTop/Mid/Bottom`) with a 4-stop mid-tone slate-blue gradient
  (`bgTop/Mid/Mid2/Bottom`, exact hexes copied from the mockup); bumped
  `panelFillA` 0.08→0.09 and `borderBright` 0.20→0.24; added four new
  tokens the mockup introduces with no prior equivalent (`vignetteEdge`,
  `specularLine`, `sweepCore`, `sweepEdge`). Also added two token pairs of
  my own that the plan flagged as implementation judgment calls rather than
  literal mockup values: `ringBorderAlpha`/`ringGlowAlpha` (hero ring
  strength, tuned down for light mode per plan §7) and
  `navActiveFill`/`navActiveBorder` (nav bar/rail active-tab highlight —
  white overlay reads fine on dark glass but is nearly invisible on light
  glass, so light mode darkens instead of brightens; the mockup is dark-only
  and doesn't cover this).
- Extracted `_clearGlassSurface()`, a shared private helper now used by
  `GlassPanel`, `GlassNavBar`, and `GlassNavRail` alike (per plan §3.7),
  replacing three separately-hand-rolled `BackdropFilter`+`Container`
  decorations that had already drifted apart once (navbar's border used
  `borderDim`, panel used `borderBright` — that inconsistency is gone now
  that there's one formula). Also added the discrete 1px specular highlight
  (inset 8% each side, fading at both ends) every clear-glass surface now
  gets, replacing the old full-width inset-shadow highlight.
- `GlassPanel`: removed the accent-conditional fill/border branch entirely
  (fill is always `panelFillA/B` now); renamed `accentColor` → `ringColor`
  (deliberate rename, not a silent meaning-change — plan §3.2 argues for
  this explicitly, and it only touched 2 internal call sites). When set,
  `ringColor` now colors the border gradient's bright corner and adds a
  thin additive glow-ring shadow, instead of tinting the fill.
- `GlassListTile`: icon chip switched from a filled color wash to a
  bordered chip (neutral `white@6%` background, accent-colored 1px border —
  matches the mockup's `.icon-chip` exactly); **stopped forwarding
  `accentColor` into the inner panel** — this is the one deliberate
  re-reversal of the immediately-prior session's "previously dropped, now
  forwarded" fix, called out in both the commit and this file so it isn't
  mistaken for a regression; added text-shadows to title/subtitle (needed
  now that the backdrop is lighter/busier than the old near-black field —
  without it, white text was losing contrast in the brighter zones of the
  sweep).
- `GlassStatusBanner` (hero): switched from `GlassPanel(accentColor:)` to
  `GlassPanel(ringColor:)`; icon chip switched from a 28px filled gradient
  circle to the same bordered-chip treatment as row icons, just larger
  (44px, radius 13, matching the mockup's `.hero-icon` exactly).
- `GlassSectionLabel`: bumped `textSecondary`/12.5px → `textPrimary`/15px,
  added a text-shadow — this coincidentally now matches what
  `dashboard_screen.dart`'s own private `_sectionHeader` helper already did
  (a pre-existing, not-v5-caused divergence the plan flagged in §3.6), so
  that private helper is deleted this session in favor of every screen
  calling this one shared widget.
- `GlassChip`: fill alpha `.22/.13` → `.10/.05`, border `.36` → `.55`
  (quieter fill, more visible border — plan §3.8, no structural change).
- `GlassButton`: untouched — nothing in the mockup implies a change (plan
  §3.9).
- `GlassBackground`: replaced the three drifting colored blobs
  (violet/teal/amber) with one achromatic diagonal light sweep plus a radial
  vignette layer. **The performance-critical part:** the sweep is driven by
  the exact same `Timer.periodic` + implicit-animation (`AnimatedAlign`)
  pattern the immediately-prior session's flicker fix established for the
  blobs — *not* a literal port of the mockup's CSS
  `animation: sweep 13s ease-in-out infinite`, which would have been a
  free-running `AnimationController.repeat()` behind every `BackdropFilter`
  on screen and would have silently reintroduced the exact bug that session
  just fixed. Plan §3.1/§6 flag this as the single highest-consequence
  mistake available in the whole rollout — treated it as such. Backdrop and
  sweep gradient angles (165deg / 112deg) are converted from CSS angle
  convention to Flutter `Alignment` via `dx=sin(θ), dy=-cos(θ)` rather than
  eyeballed, so the direction is exact, not approximate.
- `GlassColors.light`: the mockup is dark-only, so per plan §7 this is
  *designed*, not copied — same structural rules (real backdrop luminance
  range, neutral glass, specular line, accent-only-on-content) at
  light-mode-appropriate contrast. Flagged in the code comments as a
  judgment call, not a verbatim source value, so a future session doesn't
  mistake it for something pulled off the mockup.

**`lib/src/ui/dashboard_screen.dart` — re-touch, not fresh conversion** (it
was already glass, just built against the now-reverted vibrancy semantics):
migrated all three Overview section headers from the private
`_sectionHeader(c, text)` helper to the shared `GlassSectionLabel(text)`
widget, then deleted `_sectionHeader` entirely. Confirmed (by reading
`glass.dart`'s new call graph, not assuming) that no other call site in this
file needed changes — `GlassStatusBanner`, `GlassListTile`, and `GlassChip`
all keep the exact same external parameter names they had before
(`accentColor:`), so every existing call in this file picks up the new
neutral tokens automatically. The Quick Actions row is **unchanged** — the
mockup's 3-across circular-shortcut layout was evaluated and explicitly
declined in the plan (§5); Overview keeps its single `Send files` row.
Net diff: 3 one-line swaps + one 11-line deletion — about as small as a
"re-touch" gets, matching the plan's own prediction in its §4 rollout table.

**`Roadmap.md`:** inserted the `glass.dart` v5 revision as its own row above
the existing per-screen checklist (plan §9's suggested edit, applied
verbatim), and updated the `dashboard_screen.dart` row to describe the
re-touch instead of the original conversion. The other 9 rows are untouched
— this session did not convert any of the remaining Material screens; see
"Not done this session" below.

**Also committed to the repo this session:** the plan doc itself
(`docs/2026-07-12-clear-glass-v5-plan.md`) and the source mockup
(`docs/overview_redesign_preview_v5.html`), matching this project's existing
`docs/` convention for dated planning documents (`2026-07-05-...`,
`2026-07-11-...`).

**Verification performed** (same standing constraint as every session in
this log — no Flutter/Dart SDK in this sandbox, `which flutter dart`
confirmed empty):
- Balanced-delimiter check (custom Python scanner, comment/string-aware) on
  both touched Dart files — clean, before and after every edit.
- Full top-to-bottom re-read of `glass.dart` after the rewrite.
- Grepped for every remaining `Glow`/`GlassPanel(`/`AnimationController`/
  `.repeat(` reference across all of `lib/` (not just the touched files) to
  confirm: no dangling references to the removed `*Glow` tokens; the
  renamed `GlassPanel(ringColor:)` param has exactly the 2 internal call
  sites the plan predicted; the only `AnimationController` in the touched
  files is `GlassButton`'s pre-existing one-shot tap-scale animation (not a
  `.repeat()`, not behind a `BackdropFilter` driving ambient motion) — the
  plan's §6/§8 guardrail check, run as specified.
- **Not verified:** an actual `flutter run`/`flutter analyze`, or a
  rendered screenshot to visually confirm the result matches the mockup —
  no such tooling in this sandbox, same limitation as every prior session.
  **Please build and run on both targets to confirm** — in particular, the
  sweep's motion (Timer+AnimatedAlign, alignment deltas of ±0.08/±0.04
  eyeballed against the CSS's own translate percentages rather than derived
  from a formula, since Flutter's `Alignment` and CSS `%`-translate aren't
  directly equivalent units) is the one piece of this session's work with
  no strong basis for confidence beyond "looks plausible on paper."

**Not done this session, and not claimed as done:** this is step 1-2 of the
plan's own §4 rollout table (`glass.dart` itself, then the
`dashboard_screen.dart` re-touch) — the plan's suggested order has 5 more
steps after this covering the other 9 screens (`send_widget_screen.dart`,
`send_panel.dart`, `version_history_screen.dart`, `activity_screen.dart`,
`clipboard_screen.dart`, `remote_control_screen.dart`,
`folder_pairs_screen.dart`, `pairing_screen.dart`, `send_flow_view.dart`,
roughly risk-ascending). None of those were touched this session — they're
still 100% standard Material, same as before. `Roadmap.md`'s checklist
reflects this accurately (still ⬜ for all 9).

**Files touched:** `lib/src/ui/glass.dart`, `lib/src/ui/dashboard_screen.dart`,
`Roadmap.md`, `PROGRESS.md`, `THINKING.md`,
`docs/2026-07-12-clear-glass-v5-plan.md` (added),
`docs/overview_redesign_preview_v5.html` (added).

**Status: implementation complete for plan steps 1-2 (shared library +
Overview re-touch), verified by static analysis only (no SDK in this
sandbox) — please `flutter run` on Windows and Android to confirm before
merging, and take a visual look at Overview in both light and dark mode
(light mode in particular got no mockup to check against — see plan §7 and
the `GlassColors.light` code comments). Committed locally (see delivery
note for the exact commits and how to bring them into your local clone/push
to GitHub yourself — no push credentials for `johnchk250/Conduit` in this
sandbox, same limitation as every prior session).

---

## 2026-07-12 (new session) — "Exact-match" pass: `glass.dart` + Overview against a real reference file

**Starting point:** the person said the current UI (v6, previous session)
still didn't look right, and this time supplied a real reference —
`conduit-glass-redesign.html` (a static, literal mockup with real CSS
custom properties, not a description) plus a matching screenshot. Different
mode from every prior session in this log: those were all working from a
verbal description or a remembered screenshot; this one has an actual
source-of-truth file to translate token-for-token. Read the full git log
(v1 through v6) and this file's own history before touching anything, to
understand what "didn't look right" had already been tried.

**What changed, file by file:**

- **`lib/src/ui/glass.dart` — full rewrite of the token/component layer.**
  Every `GlassColors` field now traces to a specific CSS custom property or
  rule in the reference (see the file's own doc comments for the mapping —
  every non-obvious choice, e.g. why `amber`/`teal` exist when the
  reference doesn't define them, is explained inline rather than left
  implicit). Structural change from v5/v6: the reference's `.glass` class
  is a **flat** translucent fill + flat 1px border (`rgba(255,255,255,
  .055)` / `rgba(255,255,255,.12)`), not the gradient-fill/gradient-border
  recipe v5/v6 both used — so `_clearGlassSurface` was replaced with a new
  `_glassSurface` that matches this literally, plus a real `BackdropFilter`
  blur (see the flicker-risk discussion below), a hero-only diagonal
  static light band (`_heroSweep`, matching `.hero::after` — confirmed by
  reading the CSS closely that this is *not* animated, unlike what v5
  assumed/added), and a `GlassBackground` that composites three static
  radial "glow" blobs (indigo/teal/sky, exact positions converted from the
  CSS's `at X% Y%` values) over a 3-stop vertical gradient, replacing v6's
  single flat color. Also corrected the nav bar/rail active-item styling:
  v5/v6 both deliberately made the active tab *neutral* (a design choice
  made without a real mockup to check against); the actual reference shows
  the active dock item with a violet gradient glow, so that's what it does
  now — this is a case where having a real reference caught a previous
  session's reasonable-sounding guess being wrong.

- **`lib/src/ui/dashboard_screen.dart` — `_OverviewPage` re-touch.** Dropped
  the page's own `Scaffold`/`AppBar` (`title: Text('Overview')`) in favor
  of the reference's actual structure: a plain `SafeArea` + `ListView`
  whose first child is the new `GlassPageTitle` widget (Manrope 800/30px,
  matching `h1.page-title`) — both the wide-desktop and mobile shells in
  `DashboardScreen.build` already provide a `Scaffold` + `GlassBackground`
  ancestor, so nothing was lost by removing the nested one. Folder-pair
  rows now show a small status dot before their subtitle
  (`GlassListTile.subtitleDotColor`/`subtitleLive`, matching the
  reference's `.status-idle`/`.status-live`) — the reference only shows
  two states (idle/live-green), so `Paused`→amber and `Error`→a new
  `GlassColors.danger` (red-400 family) dot are this session's own
  extensions for states the reference doesn't cover, not something copied
  from it (called out as such in the code comment). Device rows now use
  `subtitleMono: true` (JetBrains Mono, matching `.tile-sub.mono`) for the
  device-ID/IP line. Fixed the "Paired" chip's accent from `c.blue` to
  `c.violet` — the reference's one literal `.badge` example in the
  screenshot is exactly a violet "Paired" pill, and the prior code had
  guessed blue.
  **Deliberately kept, not shown in the reference:** the "Quick actions /
  Send files" row. The reference screenshot's content ends after "Devices
  on this network" with visible empty scroll space before the dock, which
  reads as the screenshot just not scrolling far enough to show it, not as
  an instruction to remove an existing, reachable feature — removing it
  would have been a functional regression nobody asked for, so it stays,
  restyled to match everything else.

- **`Roadmap.md`** — updated the Phase 7 shared-library description and the
  `glass.dart`/`dashboard_screen.dart` checklist rows to describe this
  pass instead of v6, matching this project's own convention of keeping
  that checklist in sync with what actually landed each session. The other
  9 screens' rows are untouched (still ⬜) — see "Not done this session"
  below.

- **`docs/2026-07-12-conduit-glass-redesign.html`** and
  **`docs/2026-07-12-conduit-glass-redesign-screenshot.png`** (added) — the
  person's reference file and screenshot, committed alongside the plan/
  mockup docs from the v5 session, matching this project's existing `docs/`
  convention for dated planning/reference material so a future session (or
  a future me) can re-check against the actual source instead of relying
  on this log's paraphrase of it.

**The one real engineering judgment call this session made, not just a
styling choice:** reintroducing `BackdropFilter`, which the immediately
prior session removed app-wide after tracing a real Android flicker bug to
it. That bug's mechanism (documented in this file's 2026-07-12 "Android
flicker/perf fix" entry and `THINKING.md`'s matching entry) was
specifically: `BackdropFilter` re-blurs whatever's beneath it on *every*
paint, with no caching, so a backdrop that's continuously animating (the
v5-era `Timer`-driven light sweep) forces every glass panel on screen to
pay full blur cost forever, even at rest — and that showed up as visible
flicker on Android. The new reference file has **no animation anywhere**
(checked carefully — no `@keyframes`, no `animation:` rule in the whole
stylesheet, including what looked like it might be a moving sweep on the
hero card but is actually a static gradient). Since the specific mechanism
behind the diagnosed bug isn't present in what's being matched here, blur
was brought back — but this is a confident diagnosis of *mechanism*, not a
benchmarked-and-confirmed fix, same caveat every performance-related entry
in this log has carried: **there is still no Flutter/Android environment in
this sandbox, so this has not been run on a real device.** Flagging this as
the top thing to verify before merging. If it turns out to still be a
problem, the fallback is narrow and documented directly in
`glass.dart`'s class doc comment: drop the one `ImageFilter.blur` call in
`_glassSurface`, nothing else in the file needs to change.

**Also scoped out, and said so directly rather than silently skipping:**
the reference screenshot's custom titlebar (traffic-light-style minimize/
maximize/close icons). Checked first whether this Windows build already
runs frameless (`grep -rn "titleBarStyle\|WindowOptions\|TitleBarStyle"`) —
it doesn't; the app currently uses the native OS titlebar, and
`window_manager` is a dependency but nothing puts the window into frameless
mode. Building a literal custom titlebar means a window-lifecycle change
(frameless mode + wiring real minimize/maximize/close through
`window_manager`), not a content-styling one, and this repo's own history
(tray init, wake-lock, disconnect-cycling) shows exactly this area has been
fragile before. Also Android has no window controls at all, so a literal
port would need to be conditional on `Platform.isWindows` regardless. Not
attempted, since there's no way to compile/run and verify a change to
window startup behavior in this sandbox — matched everything *below* the
titlebar exactly instead, which is also where 100% of the actual visual
complaint and every prior session's work was focused.

**Verification performed** (same standing constraint as every session in
this log — no Flutter/Dart SDK in this sandbox, `which flutter dart`
confirmed empty):
- A custom comment/string-aware balanced-delimiter Python scanner (same
  category of tool prior sessions used, rewritten fresh this session) on
  both touched Dart files — clean, both files, after every edit.
- Full top-to-bottom re-read of `glass.dart` after the rewrite, specifically
  checking every `GlassColors._(...)` call site (`dark`/`light`) supplies
  exactly the constructor's field set — caught and fixed one real bug this
  way (a leftover `subtitleDotGlow` constructor parameter with no matching
  field, left behind by a mid-session rename to `subtitleLive`, which would
  have been a compile error).
- Grepped all of `lib/` (not just the touched files) for every consumer of
  `GlassPanel`/`GlassListTile`/`GlassStatusBanner`/`GlassChip`/
  `GlassButton`/`GlassNavBar`/`GlassNavRail`/`GlassColors` — confirmed only
  `dashboard_screen.dart` uses any of them (the other 9 screens are still
  100% standard Material, unaffected by this rewrite by construction, not
  just by omission).
- **Not verified:** an actual `flutter run`/`flutter analyze`, or a
  rendered screenshot to compare against the reference — no such tooling in
  this sandbox, same limitation as every prior session. **Please run
  `flutter analyze` and `flutter run` on both Windows and Android before
  merging** — in particular the `BackdropFilter` reintroduction (Android,
  above) and light mode (still undesigned against any real reference, same
  caveat as every prior session — the new reference is dark-mode-only).

**Not done this session, and not claimed as done:** the other 9 screens
(`send_flow_view.dart`, `send_panel.dart`, `version_history_screen.dart`,
`activity_screen.dart`, `clipboard_screen.dart`, `remote_control_screen.dart`,
`folder_pairs_screen.dart`, `pairing_screen.dart`, `send_widget_screen.dart`)
are still untouched, standard Material. `Roadmap.md` says so plainly.

**Files touched:** `lib/src/ui/glass.dart`, `lib/src/ui/dashboard_screen.dart`,
`Roadmap.md`, `PROGRESS.md`, `THINKING.md`,
`docs/2026-07-12-conduit-glass-redesign.html` (added),
`docs/2026-07-12-conduit-glass-redesign-screenshot.png` (added).

**Status: implementation complete for `glass.dart` + the Overview screen,
verified by static analysis only (no SDK in this sandbox) — please
`flutter analyze` + `flutter run` on Windows and Android to confirm before
merging, with particular attention to the `BackdropFilter` reintroduction
on Android and a visual side-by-side against
`docs/2026-07-12-conduit-glass-redesign-screenshot.png`.** Committed
locally in this sandbox's clone (see the delivery note provided directly
to the person for exactly how to bring these commits into your own local
clone and push to GitHub yourself — no push credentials for
`johnchk250/Conduit` here, same limitation as every prior session in this
log).

---

## 2026-07-12 (same-day follow-up) — Perf fix: skip `BackdropFilter` on list tiles

**Reported:** tab switching felt slightly slower after the exact-match pass
landed and built successfully. Confirmed this was the expected trade-off,
not a bug: the Overview screen alone stacks up to 6 `BackdropFilter`
instances at once (1 hero + up to 3-4 list tiles + the nav bar), each a
real per-frame GPU blur pass, all built/painted together the moment a tab
switch brings a fresh page on screen — exactly the situation flagged as a
risk to verify when this was delivered (see the "exact-match" entry above),
just showing up as plain sluggishness rather than the Android-flicker
scenario that entry focused on.

**Fix (option 2 of 3 offered):** added a `blur` parameter to
`_glassSurface`/`GlassPanel` (defaults `true`, unchanged for normal
callers) and set it to `false` specifically in `GlassListTile` — the one
surface that multiplies per screen. `GlassStatusBanner` (hero, one per
screen) and the dock (`GlassNavBar`/`GlassNavRail`, calls `_glassSurface`
directly) keep the real blur, since those are the reference's actual
visual focal points and there's only ever one of each on screen — no
per-instance multiplication, so no per-instance cost to cut. List tiles
now paint a flat translucent fill directly over the (still-blurred, via
the hero/dock, and still-gradient) ambient background — reads as tinted
glass rather than literally frosted glass, a small, contained visual
difference for the majority of the perf win.

**Not done:** did not touch sigma value (still 16, unchanged) or attempt
sigma-reduction as an additional/alternative fix, since removing blur
entirely from the multiplying surface should already remove most of the
cost — no reason to also degrade the two remaining (single-instance)
blurred surfaces unless this alone turns out insufficient.

**Verification:** balanced-delimiter check clean (same tool as every prior
entry). Same standing limitation as always — no Flutter/Dart SDK in this
sandbox, so the actual before/after frame-time improvement has not been
measured here. Asked the person to confirm via Flutter DevTools'
Performance tab (`flutter run --profile`) before assuming this fully
resolves it; if tiles still feel busy with many folder pairs/devices, the
next lever is lowering the hero/dock's blur sigma, not re-adding blur
anywhere.

**Files touched:** `lib/src/ui/glass.dart` only (`_glassSurface`'s new
`blur` param, `GlassPanel`'s passthrough, `GlassListTile`'s override) —
isolated, no other file needed a change for this fix.

---

## 2026-07-13 — Perf follow-up 2: RepaintBoundary + lower blur sigma

**Reported:** the list-tile blur fix (previous entry) helped, but tab
switching was still "a little" slow. Investigated further rather than just
tuning numbers blind — found something bigger than blur-instance-count:
`DashboardScreenState.build()` calls `context.watch<AppState>()` at the
shell root (line 129), so the *entire* active page repaints on every
`AppState.notifyListeners()` anywhere in the app (38 call sites — sync
progress, discovery, clipboard, connection state, ...), not just changes
relevant to what's currently visible. During any active sync this can fire
continuously while just sitting on a tab, not only when switching. This
isn't something introduced by the glass redesign, and — importantly — it's
not an oversight either: the doc comment right above it explains this
broad watch is deliberate, there specifically so folder-pair invite
delivery can't be missed by a listener detaching at the wrong time (see
that comment for the full "Step 3 of the fix plan" reasoning). So this
wasn't touched — narrowing it without care could reintroduce the exact bug
class it exists to prevent, and that's a state-management change, not a
visual one; flagged it to the person as a bigger, separate option rather
than just doing it.

**What was safe to do without touching that architecture:** isolate the
expensive part (the blur) so it doesn't get swept into repaints that have
nothing to do with it.
- Wrapped the `BackdropFilter` in `_glassSurface` in a `RepaintBoundary`
  (only when `blur: true`, i.e. the hero and the dock — the two surfaces
  that still blur after the previous fix). Standard Flutter guidance for
  exactly this situation: give an expensive filter its own compositing
  layer so unrelated ancestor repaints don't force it to redo real GPU
  work every time.
- Same treatment for `GlassBackground`'s ambient layer (3 static radial
  blobs + linear gradient) — it's reconstructed as part of the same
  `DashboardScreen.build()` that runs on every `AppState` change, so
  without a boundary it was being asked to repaint alongside page content
  for reasons that have nothing to do with it, even though the layer
  itself never actually changes.
- Also lowered the hero/dock's blur `sigma` from 16 → 12 as a small
  additional cost reduction, independent of the boundary fix — a modest,
  low-risk trim on top, not a replacement for it.

**Offered, not done — needs the person's buy-in first:** properly scoping
`AppState` consumption with `context.select`/`Selector` per-field instead
of one broad `context.watch` at the root, so unrelated state changes don't
force a full-page rebuild at all (RepaintBoundary only stops the *paint*
from cascading, not the *rebuild* itself — build() still re-runs the
active page's whole widget tree on every notifyListeners() call, it's just
cheaper now because most of that re-run doesn't also repaint the blur).
This is the bigger remaining lever, but it's a genuinely different kind of
change (state-flow architecture, touching how every page reads `AppState`,
not a visual toggle) and the pendingInvite-delivery reasoning above means
it needs to be done carefully, screen by screen, not as a blanket
find-replace. Not started without the person confirming they want that
scope of change.

**Verification:** balanced-delimiter check clean. Same standing
limitation — no Flutter/Dart SDK here, so the actual frame-time
improvement from `RepaintBoundary` (which should be the more meaningful of
the two changes) hasn't been measured. Suggested checking DevTools'
"Highlight repaints" overlay to see the hero/dock/background stop
flashing on unrelated state changes, which would confirm this landed as
intended.

**Files touched:** `lib/src/ui/glass.dart` only.

---

## 2026-07-13 (session 2) — Glass redesign: Folders, Devices, Clipboard tabs

Extended the glass redesign from Overview + Settings (both in
`dashboard_screen.dart`, the only glass.dart consumer so far) to the three
remaining primary tabs: Folders, Devices, and Clipboard. Confirmed before
starting that `origin/main` HEAD (`86521b6`, the perf-fix commit on top of
the exact-match redesign) is the version to build on — no revert or rework
of `glass.dart` itself needed, this session only adds new consumers.

**Folders tab (`folder_pairs_screen.dart`):** replaced the
`Scaffold`+`AppBar`+`Card(ExpansionTile(...))` list with Overview's shell
pattern (`GlassPageTitle` inline, no own `AppBar`) and a new local
`_FolderPairCard` widget: a `GlassListTile` header (tap toggles
expand/collapse) with a second `GlassPanel` appearing directly beneath it
when expanded, holding progress/last-synced/pending-invite info and the
Details/Sync now/Edit/Remove actions as `GlassButton`s. Preserves the
original's one-tap-away actions rather than moving them behind a
drill-down into `_PairDetailScreen`. Removed the now-unused `_SyncBadge`/
`_SyncBadgeState` (rotating-avatar) classes — status is now conveyed by
the same colored/glowing subtitle dot Overview already uses for its own
folder-pair rows, for one consistent status vocabulary across the two
screens instead of two slightly different ones. FAB kept as a real
`FloatingActionButton.extended` (just recolored to the violet accent),
not reskinned into a custom glass shape.

**Devices tab (`pairing_screen.dart`):** replaced `TabController`/`TabBar`/
`TabBarView` with a new local `_GlassSegmentedControl` (two-segment pill
switcher) reusing `GlassNavBar`/`GlassNavRail`'s existing active-item
recipe (violet gradient fill + white-alpha border) rather than inventing a
new accent treatment. Paired-device and discovered-device lists reskinned
with `GlassListTile`/`GlassPanel`/`GlassButton`; the paired-device row's
`PopupMenuButton` (reconnect/disconnect/unpair) is kept as-is — same
standard-Material carve-out `glass.dart`'s own doc comment gives dialogs/
SnackBars/BottomSheets — only its trigger icon was restyled. Manual-connect
QR flow reskinned; the QR code's white background container was
deliberately *not* converted to a glass panel (a QR code needs real
black-on-white contrast to scan reliably). `_ScanScreen` (the pushed
camera route) is untouched, out of scope like other pushed sub-routes.

**Clipboard tab (`clipboard_screen.dart`):** the most direct translation —
every element already had a 1:1 `glass.dart` primitive: the sync toggle
became a `GlassListTile` with a `Switch` trailing, the three info cards
became `GlassPanel`s, and the send button reuses `GlassButton`'s existing
`selected` state (checkmark + "Sent!") instead of building a separate
result indicator. The original's inline spinner while sending isn't
reproduced (`GlassButton` has no spinner slot) — disabling the button and
swapping its icon to a sync glyph communicates the busy state instead, a
small, deliberate simplification. Removed the now-unused `_Card` helper
class (the interrupted cleanup from the end of the previous session,
finished at the start of this one) since every one of its call sites is
now a `GlassPanel`.

**Design decisions and the reasoning behind each are written up in
`THINKING.md`** (search "session 2") rather than repeated here — worth
reading before reviewing the diff, especially the Folders expand/collapse
call and the Devices segmented control, since neither has a reference
mockup to check against.

**Verification:** balanced-delimiter check clean on all three files (and
`glass.dart`, unchanged, as a sanity check) — braces/parens/brackets all
net zero. Cross-checked every `Glass*` widget call against its actual
constructor signature in `glass.dart` (params and types match) rather than
assuming from memory. No Flutter/Dart SDK in this sandbox, so — same
standing caveat as every glass-related entry above — please run
`flutter analyze` and a real build on both Windows and Android before
merging. Nothing in `sync/engine.dart`, `app_state.dart`, or any
protocol/wire code was touched; this is UI-layer only.

**Files touched:** `lib/src/ui/folder_pairs_screen.dart`,
`lib/src/ui/pairing_screen.dart`, `lib/src/ui/clipboard_screen.dart`.
`glass.dart` and `dashboard_screen.dart` untouched this pass.

**Remaining for future passes:** `_PairDetailScreen`, `_ScanScreen`,
`VersionHistoryScreen`, `ActivityScreen`, `RemoteControlScreen`,
`send_flow_view.dart`, `send_panel.dart`, `send_widget_screen.dart`, and
all dialogs — same "pushed sub-routes and modal surfaces stay standard
Material for now" boundary the redesign has followed since Settings.
