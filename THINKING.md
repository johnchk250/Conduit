# THINKING.md — Reasoning log

Companion to `PROGRESS.md`. `PROGRESS.md` records *what was done and found*;
this file records the *reasoning trail* — hypotheses considered, evidence
checked, and why alternatives were ruled in/out — for sessions where that
trail is worth keeping. Not every checkpoint needs an entry here; use it
when the "why" is non-obvious or future-Claude would otherwise have to
re-derive it.

---

## 2026-07-11 — Repeated peer-disconnect cycling during Doze / Battery Saver

**Question:** is the connect→disconnect→reconnect cycling shown in the
Activity log (screenshots) normal, given phone screen-off + battery saver?

**Hypotheses considered, in order:**

1. *TCP keepalive is too loose to catch a half-dead peer.* Ruled out as the
   primary cause — the app doesn't rely on OS TCP keepalive at all;
   `peer_session.dart` runs its own app-level heartbeat (12s ping /
   6-missed threshold = 72s dead-timer). The observed ~72–90s gaps in the
   screenshots match this budget almost exactly, which points at the
   heartbeat *correctly detecting* an underlying stall, not at the
   heartbeat itself being miscalibrated.

2. *Wake lock isn't actually being held during a live session (regression
   in the `b452888` fix).* Checked `SyncService.kt` — wake lock ownership
   and the 45s renewal timer look correct post-fix. Also checked
   `app_state.dart`'s `_setConnectionWakeLockEnabled` — the renewal timer
   and channel calls are wired correctly *when the lock is supposed to be
   on*. So not a regression in the recent fix itself.

3. *Doze suspends network even for battery-optimization-exempt apps.*
   Checked current Android docs
   (developer.android.com/training/monitoring-device-state/doze-standby)
   directly rather than relying on training-data memory, since this is
   exactly the kind of platform-behavior detail that can drift or be
   misremembered. Docs are explicit: an app on the
   `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` exemption list *can* use the
   network and hold partial wake locks during Doze. Conduit requests this
   exemption (`MainActivity.kt`) and also runs `SyncService` as a proper
   `dataSync`-type foreground service, which is the stronger of the two
   mechanisms. So — assuming the user actually granted that permission
   prompt and no OEM layer overrides it — stock-AOSP Doze alone shouldn't
   fully explain a *tight, repeating* cycle. Flagged OEM-specific extra
   battery managers (Samsung/Xiaomi/etc., "dontkillmyapp.com" territory)
   as a real but *unverifiable-from-here* possibility — device-specific,
   not visible from the code.

4. *Something in-app is turning the connection wake lock off even while a
   session is live.* This is what actually panned out: `app_state.dart`
   `_applyBeaconMode()` → `_setConnectionWakeLockEnabled(anyLive &&
   !_config.batterySaverMode)`. Conduit's own "Battery saver mode" toggle
   (user-facing, defaults off, see `config_store.dart`) forces the
   connection wake lock off unconditionally, including for an already-live
   session. Cross-checked the UI copy in `dashboard_screen.dart` — it only
   describes the 1-hour watcher-polling relaxation, says nothing about the
   connection lock. This is a plausible, code-confirmed root cause *if*
   the user has that toggle on, and it would fully explain a tight,
   repeating cycle: CPU free to sleep mid-session → heartbeat timer stalls
   → Windows-side `send()` eventually aborts with the semaphore-timeout
   error → app's own 72s dead-timer fires → teardown → reconnect on next
   wakeup → repeat.

**Why not just pick hypothesis 4 and stop there:** the user's phrasing
("battery saver is on") is ambiguous between the *phone's* OS-level
Battery Saver and *Conduit's own* in-app toggle of the same name — they
are different mechanisms with different fixes (UI/behavior change in our
code vs. Android-settings guidance for the user). Answered with both
branches explained and asked which one applies, rather than guessing and
possibly sending the user down the wrong path.

**Not yet done:** no code change. If the user confirms hypothesis 4, the
natural fix is to decouple "relax watcher polling" from "let the live
connection lock lapse," or at minimum make the UI copy honest about the
trade-off. Waiting for confirmation before touching code.

---

## 2026-07-11 (continued) — Weighing the two fix directions before touching code

**Question:** hypothesis 4 is confirmed. Of the two follow-up candidates
logged in `PROGRESS.md` (decouple the behavior vs. just fix the UI copy),
is this actually a judgment call the user needs to make, or is one option
simply correct?

**Re-examined `_applyBeaconMode()` with the specific question: what does
"decouple" actually cost in battery terms?**

`_setConnectionWakeLockEnabled(anyLive && !_config.batterySaverMode)` —
the `anyLive` term (`_registry.readyPeerIds.isNotEmpty`) means this lock is
only ever requested while a peer session is *already connected*. It is
never held while idle/disconnected — that path is already covered
separately by `_setDiscoveryLockEnabled(!anyLive)` and the engine's watcher
poll-interval change (`_engine.setBatterySaverMode(true)`, driven straight
off `_config.batterySaverMode` at startup, line ~311 — a completely
separate code path from the wake lock).

So removing `!_config.batterySaverMode` from that line (i.e. "decouple")
does **not** change battery behavior while idle at all. Its only effect is:
during battery-saver mode, if a peer session is *live*, hold the lock
instead of letting Doze stall it. The realistic alternative cost isn't "no
extra battery use" — it's repeated teardown/rediscovery/TCP
handshake/backlog-resync every ~72–90s for as long as the peer stays
nearby, which is not obviously cheaper than just holding a partial wake
lock for the (typically short) life of that session. This changes my
assessment from "genuine trade-off, ask the user which they want" to
"looks like a straightforward bug — battery saver mode's watcher-polling
relaxation got a second, unrelated, and strictly-worse effect bundled into
the same conditional, most likely by copy-paste/scope creep rather than
intent." The UI copy never described this second effect, which supports
"unintended" over "intentional trade-off the user should weigh."

**Decision:** treat "decouple" as the correct default fix rather than a
50/50 choice, and pair it with the accurate-copy fix (do both, they're not
mutually exclusive). Still surfacing this to the user as a single
confirm-and-go question rather than silently shipping it — it's their
repo and the reasoning above, while I think it's solid, rests on my
reading of *why* the code is shaped this way, which I can't fully verify
(no commit message or doc explains the original intent behind bundling the
two). Framed the question so proceeding with the recommended fix is the
default, one-tap path.

## 2026-07-11 (continued) — Root-causing the false "clipboard couldn't be written" notification

**Bug report:** PC→phone clipboard notification (meant to fire only when
Android blocks the background clipboard write) fires inconsistently,
including cases where the write genuinely succeeded and synced.

**Traced the write path first** (`clipboard_sync.dart` `onPushReceived`):
write goes through `writeClipboard(text)`, which on Android
(`_defaultWriteClipboard`) calls a native `MethodChannel('conduit/clipboard')`
→ Kotlin `CH_CLIPBOARD` handler in `MainActivity.kt`, which sets the
clip via `applicationContext.getSystemService(ClipboardManager)`. The
in-code comment explains *why*: Flutter's own `Clipboard.setData()` is
Activity-bound and can misbehave when the Activity is paused, so this
routes through the same process as the foreground `SyncService` instead —
deliberately built to work while the app is backgrounded.

**Then traced how "did it work" gets decided.** Immediately after the
native write call returns (no exception), `onPushReceived` calls
`readClipboard()` — and *that* function (`_defaultReadClipboard`) is NOT
the same native path. It's Flutter's own `Clipboard.getData('text/plain')`,
which is the same Activity-bound plugin API the write path was explicitly
built to avoid. If `verify != text`, `_pendingRemoteText` stays set, and
`app_state.dart`'s `_onClipboardPushReceived` reads that as "the OS
blocked the write" and fires `showClipboardSyncReceived`.

**This asymmetry is the whole bug.** Confirmed against Android's actual
platform behavior (searched to verify rather than assume): Android 10+
restricts clipboard *reads* to whichever app currently has window focus,
or the default IME — with no exception for the app that just wrote the
data, and explicitly *not* satisfied by running as a foreground service.
Writes were never restricted this way; only reads are. So:

- The write (native, applicationContext) succeeds regardless of focus —
  that's exactly what it was built for.
- The verify-read (Flutter plugin, Activity-bound) is denied whenever the
  app lacks focus — i.e. almost always in the exact backgrounded scenario
  this write path exists to handle — and the OS doesn't throw for this,
  it just silently returns empty/null, so `verify` comes back not-equal
  to `text` even though the system clipboard is correct.
- Net effect: whether the false notification fires depends on whether the
  phone happened to have Conduit focused at the instant the push landed —
  which matches the user's description of "inconsistent" exactly, and has
  nothing to do with whether the write actually succeeded.

**Checked for a loophole before concluding this is unconditional:** no
`READ_CLIPBOARD`-adjacent permission, and Conduit isn't registered as an
input method (grepped `AndroidManifest.xml` — no IME service, no related
permission), so there's no legitimate way for this app to read back its
own background write. Also checked the existing test
(`pendingRemoteText is set when clipboard write is blocked (background)`)
— its fake `_BlockedWriteClipboard` simulates "write succeeds, readback
returns something else" as *the* model of "OS blocked it." That's exactly
the conflation causing the bug: on real Android, "readback disagrees" and
"OS blocked the write" are two different, independent conditions, and the
test (correctly) exercises only the *intentional* meaning of the fake
without catching that production code has no way to tell them apart.

**Why the native write channel doesn't have this same problem:** writing
via `ClipboardManager.setPrimaryClip()` isn't gated by focus at the OS
level — only reads are. The Kotlin handler already surfaces genuine write
failures correctly, via `result.error("CLIPBOARD_WRITE", ...)` on a thrown
exception from `setPrimaryClip()`, which Dart receives as a
`PlatformException` and the existing `catch (e)` block in
`onPushReceived` already handles correctly (logs + returns, leaving
`_pendingRemoteText` set — that path is fine as-is).

**So the readback-based verify step, on Android specifically, does not
detect anything the exception path doesn't already catch — it can only
ever produce false negatives.** Concluded the fix is to stop using it as
the success signal on Android: trust "the native write call completed
without throwing" as success, keep the existing readback-based verify for
non-Android platforms where no such read restriction exists (Windows).

**Residual limitation to be upfront about:** this trusts the OS API's own
exception behavior. If some OEM/enterprise policy silently swallowed a
write without throwing, this fix would miss it and never show the
"pending — open app to paste" notification for that case. This is
strictly rarer than the reported bug (which fires on effectively every
backgrounded receive) and matches how the rest of the write path already
trusts the platform channel's own success/exception signal, but worth
naming rather than presenting the fix as literally 100% detection.

**Not yet done:** no code change — surfacing root cause + fix direction to
the user first, per project convention (see prior disconnect-cycling
session: confirm before touching behavior).

## 2026-07-11 (new session) — Scoping ignore rules + version-restore, before writing code

Read the uploaded Phase 6 planning doc in full first (it's explicitly framed
as "plan only, nothing implemented" and written by a prior audit pass, so
treating its file/line claims as things to re-verify against the actual repo,
not take on faith — same discipline as every prior session on this project).

Two things stood out as needing a decision before code, and the doc itself
flags both:

**1. Retroactive-ignore semantics (§4.4).** The scanner's tombstone sweep
(`priorLive` vs `seenPaths` diff in `scanner.dart`) can't distinguish "this
file was locally deleted" from "this file just started being ignored" unless
the ignore-check explicitly adds ignored paths to `seenPaths` before
`continue`-ing past the hash/upsert step. Get this wrong and a user adding an
ignore rule for, say, a large already-synced folder would watch it vanish
from their peer's device too — the opposite of what "ignore" should mean.
The doc's own recommendation (freeze, don't tombstone) is clearly the safer
default and is what I'd pick, but it's a real behavior choice with a
real peer-visible consequence, so surfacing it rather than assuming — this is
exactly the kind of thing the project's existing convention (confirm before
touching sync-adjacent behavior) exists for.

**2. Version-restore scope (§5.3).** Traced this myself rather than just
trusting the doc's framing. Re-read `Roadmap.md` §0's hard constraint list —
`_applyRemoteTombstone` is explicitly named as must-not-touch, no exceptions
carved out. The doc's option (a) for delete-restore requires a line inside
that exact function. That's not an "Aminul could go either way" question in
the way retroactive-ignore is — it's already answered by a constraint the
project itself wrote down as non-negotiable, well before this session
started. So: not asking about this one, just doing edit-restore only (option
b) and noting the reasoning in PROGRESS.md so it's visible, not silently
decided.

**3. The `glob` package.** Caught this by checking what's actually available
in the sandbox before assuming the plan's suggested dependency was safe to
add. No `flutter`/`dart` binary, and the network egress allowlist for this
container doesn't include pub.dev (checked the configured domain list) — so
`flutter pub get` would fail even if I wrote the pubspec line, and I'd have
no way to confirm the package resolves or that its API surface matches what
I'd be coding against. Given the explicit "verify workability before any
critical change" instruction this session, adding a dependency I can't
verify felt like exactly the kind of thing to avoid. A hand-rolled glob
matcher covering just the patterns ignore-rules actually need (`*`, `**`,
`?`, literal path segments) is a small, fully self-contained, and
unit-testable substitute — deliberately choosing "smaller and verifiable"
over "matches the plan's suggested package."

**On the wake-lock-fix memory being stale:** the repo has moved through two
more sessions (disconnect-cycling, clipboard notification) since the
2026-07-10 handoff doc that's still sitting in memory as "not confirmed
pushed." `git log` on fresh clone shows it landed at `b452888` with normal
history after it. Worth noting in case this comes up again — memory is a
snapshot, the repo is ground truth.

**Next:** waiting on the retroactive-ignore answer, then implementing in the
doc's own recommended sequencing — ignore rules first (§4), version-restore
second (§5) — verifying each with manual read-through + hand-traced test
cases before moving to the next, rather than writing both features and
verifying at the end. Smaller verified increments over one big unverified
batch, given no SDK access to lean on for automated verification here.
