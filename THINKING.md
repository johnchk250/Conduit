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
