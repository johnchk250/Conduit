# Send Widget & Ad-Hoc Transfer Throughput — Roadmap Phase 4

## 1. Motivation

Two complaints about the ad-hoc "Send to Conduit" flow (Phase 3d):

1. Triggering it from Explorer's right-click menu opens the **entire app** —
   full dashboard, NavigationRail, everything — just to push one file.
   KDE Connect's equivalent is a small, disposable "send to device" popup.
2. The transfer itself felt **much slower than KDE Connect** on the same
   LAN, even though both are plain TCP.

This doc covers both fixes plus the accompanying UI redesign. It assumes
familiarity with `docs/2026-06-21-conduit-design.md`.

## 2. Why the transfer was slow

`fetchFileBlockLevel` (block_transfer.dart) pulled blocks **stop-and-wait**:
send one `request`, await the matching `response`, only then send the next.
For an N-block file that's N sequential round trips. On a LAN a round trip
might be a couple of milliseconds — invisible for one message, but multiply
by however many 1 MiB blocks a real file needs and the transfer spends most
of its wall-clock time idle, waiting on the network, rather than actually
moving bytes. KDE Connect (and most serious transfer protocols) keep several
requests in flight at once specifically to avoid this.

Two independent fixes, both scoped to avoid touching the V2 sync engine's
own steady-state behavior:

### 2.1 TCP_NODELAY

Dart sockets don't enable `TCP_NODELAY` by default, so Nagle's algorithm can
briefly delay the small successive writes `secure_frame.dart` makes (4-byte
length prefix, then the JSON payload). `peer_session.dart` now sets it
explicitly on both the outbound connect path (`connectMultiHost`) and the
inbound accept path (`_handleIncoming`) — best-effort, wrapped in `try/catch`
since the option isn't guaranteed to be settable on every platform/socket
state, and a connection that works with Nagle's algorithm on must never be
made to fail over this.

### 2.2 Pipelined block fetch

`fetchFileBlockLevel` gained an optional `pipelineDepth` parameter (default
**1**, which is byte-for-byte the original stop-and-wait loop — every
existing call site and test is unaffected). At depth > 1 it keeps that many
`request`s outstanding simultaneously: fire several `sendRequest` calls
without awaiting the earlier ones first, then drain the responses in strict
block order as they arrive.

This required **no wire-protocol change**. Both serve loops
(`serveFileBlockLevel` and `file_send.dart`'s `_serveBlocks`) already consume
their request stream with a single `await for`, responding to each buffered
request before reading the next — i.e. strictly FIFO. Firing several
requests before awaiting any of them just means the peer's serve loop never
runs dry waiting for the next request to land; responses still come back in
the order they were sent, so a simple sliding window (`inFlight` list,
topped up as each oldest entry is consumed) is sufficient — no need to tag
requests with an ID and reorder responses.

`file_send.dart` passes `pipelineDepth: 8` for ad-hoc receives only (see
`_adHocPipelineDepth`). **The V2 sync engine's own call in `engine.dart` is
untouched** and keeps the default depth of 1 — this fix is deliberately
scoped to the ad-hoc send path the user actually asked about, not the
background reconciliation loop, to keep risk to the core engine at zero.

Tests: `block_transfer_test.dart` gained an end-to-end correctness test at
depth 4 (real serve loop) and a focused unit test that proves requests are
actually issued concurrently — up to `pipelineDepth`, sliding as responses
arrive — rather than just checking the final result matches.

## 3. The compact send widget

### 3.1 Why not a second native window

The obvious KDE Connect-style implementation is a genuinely separate native
window. That needs a multi-window plugin (e.g. `desktop_multi_window`),
which isn't in `pubspec.yaml` today. Adding a new native Windows plugin
dependency without being able to run `flutter pub get` / `flutter build
windows` to verify it actually links is too risky to introduce sight
unseen — so this phase reshapes the **one** window Conduit already has
instead of adding a second one.

**Known trade-off**: if the main dashboard is already open and visible when
a "Send to Conduit" fires, it will still shrink into the compact popup (and
restore afterwards) rather than opening an independent little window beside
it. Swapping to a real multi-window implementation later is a natural
follow-up once it can be built and tested against an actual Windows target.

### 3.2 How the reshape works

- `AppState.sendWidgetMode` (bool, Windows-only) is the on/off signal. It's
  set in `_onIncomingSharedFiles` — the same place that already receives
  paths forwarded from the native `--send`/WM_COPYDATA flow — and cleared
  by `exitSendWidgetMode()`. AppState never touches window geometry itself;
  it's purely the signal `DashboardScreen.build()` switches on.
- `DashboardScreen` is the app's single, permanently-mounted root route (see
  its own doc comment). `build()` now checks `sendWidgetMode` immediately
  after the `isStarted` guard and, if true, returns `SendWidgetScreen`
  directly — before `_showInviteDialogIfNeeded` or
  `_navigateToSendIfSharedFiles` run, and without touching the `_index`
  field that remembers which NavigationRail/BottomNav tab was active. Since
  `DashboardScreen`'s State is never recreated, that field survives
  untouched, so the full shell reappears exactly where the user left it once
  the widget closes.
- `SendWidgetScreen` does the actual `window_manager` work: on mount, it
  resizes to a fixed 400×560, centers, pins always-on-top (so a "send this
  real quick" popup doesn't get lost behind other windows), shows, and
  focuses. On close (header's × button, or `SendFlowView`'s
  auto-close-on-success callback) it reverses all of that, restoring the
  window from the same saved-bounds SharedPreferences keys
  `desktop/tray.dart` already trusts (`restoreNormalBounds()`, extracted
  from `DesktopTray.init()` so both call sites share one source of truth for
  "what does normal look like").
- `desktop/tray.dart` exports one new top-level flag,
  `suppressWindowBoundsPersistence`. `SendWidgetScreen` sets it before
  resizing and clears it after restoring; `_CloseHandler._saveWindowBounds`
  checks it first. Without this, the widget's own resize would itself fire
  `onWindowResized` and silently overwrite the user's real saved window size
  with the popup's dimensions.
- `windows/runner/main.cpp` creates the native window at 400×560 to begin
  with when the process cold-starts from `--send` args (rather than the
  normal 1280×720), so there's no visible flash of a full-size window before
  Dart shrinks it a frame later. Kept in manual sync with
  `SendWidgetScreen`'s `_popupWidth`/`_popupHeight` — native and Dart code
  can't share a source file across that boundary.
- Android is untouched: it has no window to resize, so `sendWidgetMode` is
  gated to `Platform.isWindows` and the OS share sheet keeps using the
  existing full-screen Send tab.

## 4. UI redesign (`SendFlowView`)

All the actual send logic — file queueing from both the OS share mechanism
and the in-app picker, peer selection/auto-select, the block-pull progress
callback — moved out of `send_panel.dart` into a new shared widget,
`SendFlowView` (`lib/src/ui/send_flow_view.dart`), parameterized by a
`compact` flag. `SendPanel` (the full-shell "Send" tab) and
`SendWidgetScreen` (the popup) are now both thin hosts around the same
widget, so the redesigned flow, the throughput fix, and any future change
only need to exist once.

Highlights of the redesign:

- **Device row**: the old dropdown-plus-separate-"Reconnect"-buttons became
  a horizontal row of tappable avatar chips — one per *paired* device
  (not just connected ones, so an offline device is still visible and
  actionable), each showing a platform icon, a green/grey connection dot,
  and a selection ring. Tapping a connected chip selects it; tapping an
  offline one reconnects it in place, folding what used to be a separate UI
  affordance into the same control used to pick the destination.
- **Sending state**: a custom animated ring (`_TransferRing`, built on the
  stock `CircularProgressIndicator` + `TweenAnimationBuilder` — no new
  dependencies) replaces the plain spinner, with live speed (MB/s or KB/s,
  smoothed) and ETA computed from successive progress callbacks.
- **Result state**: sending previously had no distinct "done" visual beyond
  a SnackBar; there's now an explicit success/error state with its own
  iconography, and — compact mode only, and only on a clean sweep — a brief
  confirmation before the popup closes itself automatically.
- **Bug fix noticed along the way**: the original build-time pickup logic
  for newly-arrived shared files overwrote `_sharedFiles` unconditionally,
  even mid-send — a file shared while a previous batch was still in flight
  could get silently dropped once the send loop finished and cleared the
  queue. The rewrite gates that pickup on `_phase != sending`, so a share
  that lands mid-transfer is picked up on the very next idle frame instead.

No drag-and-drop: genuine OS-level file-drop-onto-window needs a plugin
(`desktop_drop`) that isn't in `pubspec.yaml` either, for the same
can't-verify-the-build reason as §3.1. The "click to choose files" zone is
styled to invite a drop but is honestly just a large tap target into the
existing `file_picker` flow.

## 5. Files touched

| File | Change |
|---|---|
| `lib/src/net/peer_session.dart` | TCP_NODELAY on connect + accept |
| `lib/src/sync/block_transfer.dart` | `pipelineDepth` param on `fetchFileBlockLevel` |
| `lib/src/sync/file_send.dart` | ad-hoc receive uses `pipelineDepth: 8` |
| `lib/src/app_state.dart` | `sendWidgetMode` flag + `exitSendWidgetMode()` |
| `lib/src/ui/dashboard_screen.dart` | routes to `SendWidgetScreen` when active |
| `lib/src/ui/send_flow_view.dart` | **new** — shared send engine + redesigned UI |
| `lib/src/ui/send_panel.dart` | reduced to a thin AppBar wrapper |
| `lib/src/ui/send_widget_screen.dart` | **new** — compact popup + window lifecycle |
| `lib/src/desktop/tray.dart` | `suppressWindowBoundsPersistence`, `restoreNormalBounds()` |
| `windows/runner/main.cpp` | compact initial window size for `--send` cold starts |
| `test/block_transfer_test.dart` | two new pipelining tests |

## 6. Not done / follow-ups

- A real second native window (via `desktop_multi_window` or similar), once
  it can be pinned and build-verified on an actual Windows machine.
- Genuine drag-and-drop (`desktop_drop`), same caveat.
- Raising `engine.dart`'s own `fetchFileBlockLevel` call to a non-default
  pipeline depth, if the background sync engine's steady-state throughput
  ever becomes the bottleneck instead of ad-hoc sends specifically. Left
  alone here deliberately.
- This was all written and reviewed without a working `flutter` install in
  the environment it was produced in (no network access to the Flutter/Dart
  SDK distribution) — every change was checked by hand (signatures, call
  sites, imports, brace balance, line-ending conventions, and the exact
  `window_manager`/`dart:io` API surface via documentation lookups) rather
  than by running `flutter analyze` / `flutter test`. Please run
  `_run_analyze.bat` and `_run_test.bat` before shipping.
