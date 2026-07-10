# Handoff — Wake-lock ownership fix (2026-07-10)

## Summary

The transfer- and connection-tied Android wake locks (Roadmap Phase 0.4 /
0.6) were acquired directly on `MainActivity` rather than on `SyncService`,
despite a code comment claiming the transfer lock was "routed to the running
SyncService." They were not. Only the discovery/`MulticastLock` toggle
actually went through `SyncService`.

This mattered because `MainActivity` is `launchMode="singleTask"` with no
`excludeFromRecents`. `MainActivity.onDestroy()` explicitly released both
wake locks — so a plain swipe-from-recents gesture mid-transfer killed
wake-lock protection immediately, even though `shouldDestroyEngineWithHost()
= false` keeps the Dart sync engine (and the foreground `SyncService`)
running underneath. Separately, the transfer lock had no renewal at all
(unlike the connection lock, which already renewed every 45s) — so any
transfer burst longer than its flat 60s native timeout lost the lock on its
own, with no Activity-destruction required.

Net effect: any transfer running longer than ~60s, or any transfer
interrupted by the user backgrounding the app (a completely normal action),
could leave the device free to enter Doze mid-transfer — the exact failure
mode Phase 0.4 was meant to prevent.

## Fix

Moved real ownership of both locks into `SyncService`, mirroring how the
`MulticastLock` toggle already worked correctly (owned by the service,
outlives the Activity), and added renewal for the transfer lock to match the
connection lock's existing pattern.

### `SyncService.kt`
- New fields: `transferWakeLock`, `connectionWakeLock` (`PARTIAL_WAKE_LOCK`,
  reference-counted off, same as before).
- New companion constants/functions: `ACTION_SET_TRANSFER_LOCK`,
  `ACTION_SET_CONNECTION_LOCK`, `EXTRA_LOCK_ENABLED`,
  `setTransferLockEnabled(ctx, enabled)`, `setConnectionLockEnabled(ctx,
  enabled)` — same `startForegroundService`/intent pattern already used by
  `setDiscoveryNeeded`.
- `onStartCommand` handles the two new actions by acquiring/renewing or
  releasing the corresponding lock.
- `onDestroy()` now also releases both locks — this is safe and correct
  here because `SyncService.onDestroy()` only fires on genuine service
  death (OOM kill, intentional stop, OS reclaim), not on the Activity being
  swiped away.
- Native timeout raised from 60s (transfer) to 120s for both locks. This is
  a safety net against a lost renew/release message, not the intended hold
  duration — Dart's periodic renewal is the real mechanism now.

### `MainActivity.kt`
- Removed the `transferWakeLock`/`connectionWakeLock` fields and their
  `acquire*`/`release*` methods entirely — the Activity no longer holds any
  `PowerManager.WakeLock` itself.
- The `conduit/wakelock` channel's `"acquire"`/`"release"`/
  `"acquireConnection"`/`"releaseConnection"` cases now just forward to
  `SyncService.setTransferLockEnabled`/`setConnectionLockEnabled`.
- `onDestroy()` no longer releases these locks (there's nothing left to
  release on the Activity side).

### `app_state.dart`
- Added `Timer? _transferWakeLockRenewal`, mirroring the existing
  `_connectionWakeLockRenewal`.
- `_onTransferState(transferring)` now starts a 45s periodic renewal
  (`_renewTransferWakeLock`) when a burst begins, and cancels it + sends a
  final `release` when the burst ends — instead of firing a single `acquire`
  with no follow-up.
- Both `dispose()` and `quit()` now also call `_onTransferState(false)` (in
  addition to the existing `_setConnectionWakeLockEnabled(false)`) so an
  in-flight renewal timer and lock are cleaned up on teardown.

## Files changed

- `android/app/src/main/kotlin/com/conduit/conduit/SyncService.kt`
- `android/app/src/main/kotlin/com/conduit/conduit/MainActivity.kt`
- `lib/src/app_state.dart`
- `Roadmap.md` (Phase 0.4 row corrected; Phase 0.6 row added)
- `ARCHITECTURE.md` (§8 platform notes corrected; new §9.4; Appendix B entry)
- `PROGRESS.md` (this session's log)

## What was verified vs. not

**Verified by manual read-through** (no Flutter/Dart SDK or Android
toolchain available in the review environment, consistent with the prior
session's constraint):
- Every call site of the removed `MainActivity` methods now points at the
  new `SyncService` companion functions.
- `app_state.dart`'s new timer follows the exact same lifecycle pattern as
  the pre-existing, working `_connectionWakeLockRenewal`.
- No dangling references to the removed fields/methods remain in either
  Kotlin file (`grep`-checked).
- `PowerManager` import in `MainActivity.kt` is still needed (used by
  `openBatteryOptimizationSettings`), so left in place.

**Not verified — please run before merging:**
- `flutter analyze` / `flutter test` (154/154 expected; this change touches
  `app_state.dart` but not any of the paths the existing suite pins).
- An actual Android build + on-device test: start a transfer, swipe the app
  from recents mid-transfer, confirm (via `adb shell dumpsys power` or
  logcat) that `Conduit::Transfer` stays held until the burst legitimately
  ends.
- A long-burst test (transfer running past 120s) to confirm the renewal
  timer actually keeps the lock alive end-to-end on a real device.

## Known gap not addressed by this fix

There is still no automated test coverage for any of the wake-lock/service
code — the existing `flutter test` suite has no path into Kotlin service
code. This was true before this fix and remains true after. An instrumented
`androidTest/` suite exercising `SyncService` directly (acquire/renew/release
lifecycle, and ideally a real Activity-destroy-mid-transfer scenario) is the
recommended follow-up, but was out of scope for what was asked this session.

## Delivery note

This environment has no push credentials for `johnchk250/Conduit`. The fix
is committed locally in a throwaway clone; it's delivered to you as a git
bundle (and a plain patch, for easy review) rather than pushed directly.
