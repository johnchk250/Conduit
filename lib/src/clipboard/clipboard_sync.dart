import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../net/peer_registry.dart';
import '../protocol/wire.dart';

/// Roadmap Phase 2 — clipboard sync.
///
/// Two directions, with an asymmetric shape dictated by Android's privacy
/// model (see Roadmap §2 of Phase 2):
///
///   PC → phone, automatic: the PC watches its own clipboard and pushes to a
///   connected phone. The PC may read its clipboard at any time.
///
///   phone → PC, manual (in-app button): stock Android 10+ forbids a
///   backgrounded app from reading the clipboard, so the phone never polls.
///   Instead the user opens Conduit and taps "Send clipboard now" on the
///   Clipboard screen. The actual clipboard read happens while the app is
///   foreground — the only legal shape. (This mirrors KDE Connect's manual
///   phone→desktop flow; a "floating popup anywhere you copy" is impossible on
///   stock Android and was intentionally dropped — see HANDOFF_2026-06-27.)
///
/// The single non-obvious problem is the ECHO LOOP: phone sends Y → PC writes
/// Y → PC's watcher sees Y and would push Y back → phone writes Y → … forever.
/// [ClipboardController] breaks it with a pure, unit-testable rule (see its
/// doc). Everything else here is wiring.
///
/// Engine-safe: this module lives ENTIRELY outside the sync engine. It sends
/// `Msg.clipboardPush` over live sessions and writes the local clipboard via
/// Flutter's `Clipboard`. It never touches the Index DB, the version vectors,
/// or the needs-queue. Reverting Phase 2 = deleting this file + its one engine
/// callback + its one wire constant.

/// Outcome of [ClipboardController.onPolled].
enum ClipboardPollDecision {
  /// The polled hash is genuinely new — the caller should push it.
  push,

  /// The polled hash matches what we last handled, or we're inside the
  /// suppress window after a local write — skip.
  skip,
}

/// Pure logic that decides whether a freshly-observed clipboard should be
/// pushed, so the echo loop can't run away.
///
/// Invariants held:
///   1. After we push a value (or a peer's value is written locally), we
///      remember its hash. A subsequent poll that sees the SAME hash is a skip
///      — we don't re-broadcast unchanged content.
///   2. After a LOCAL write (us writing a value we just received), we open a
///      short suppress window. The OS clipboard write is async, so without it
///      our own next poll tick could race the write landing and re-push. The
///      window covers that lag.
///
/// This class has no Flutter / IO dependencies — it's fully unit-testable.
class ClipboardController {
  ClipboardController({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  String? _lastHandledHash;
  DateTime? _suppressUntil;

  /// The hash of the value most recently handled (pushed or written), exposed
  /// for diagnostics and tests.
  String? get lastHandledHash => _lastHandledHash;

  /// Record that we pushed [hash] outbound.
  void markOutboundPushed(String hash) {
    _lastHandledHash = hash;
  }

  /// Record that we wrote [hash] to our own clipboard (received from a peer).
  /// Opens the suppress window so our own next poll doesn't echo it back.
  void markLocallyWritten(String hash) {
    _lastHandledHash = hash;
    _suppressUntil = _now().add(_suppressWindow);
  }

  /// Decide what to do with a polled clipboard whose content hashes to [hash].
  /// Use the SAME hash function the caller uses (see [hashOf]).
  ClipboardPollDecision onPolled(String hash) {
    if (hash == _lastHandledHash) return ClipboardPollDecision.skip;
    final until = _suppressUntil;
    if (until != null && _now().isBefore(until)) {
      return ClipboardPollDecision.skip;
    }
    return ClipboardPollDecision.push;
  }

  /// Suppress window covers the async lag between Clipboard.setData and the
  /// OS confirming the write (so our own poll doesn't race it).
  static const _suppressWindow = Duration(milliseconds: 800);
}

/// SHA-256 of [text], hex-encoded. Used as the clipboard identity so two
/// identical copies are recognised as "no change" without comparing raw text.
String hashOf(String text) => sha256.convert(utf8.encode(text)).toString();

/// Host-facing clipboard sync orchestrator. Owns the poll timer and the
/// outbound/inbound paths. The poll runs ONLY while all of: enabled, this is
/// the PC (Android never auto-polls), and at least one paired peer is
/// connected. The inbound path (peer push) writes the local clipboard and is
/// reachable on BOTH platforms.
class ClipboardSync {
  ClipboardSync({
    required this.registry,
    required this.pairedPeerIds,
    required this.onLog,
    required this.onRemoteReceived,
    required this.now,
    this.readClipboard = _defaultReadClipboard,
    this.writeClipboard = _defaultWriteClipboard,
    bool Function()? isDesktopPlatform,
  }) : _isDesktopPlatform = isDesktopPlatform ?? (() => Platform.isWindows);

  /// Live session lookup. Sends go to every OPEN session whose peer is paired.
  final PeerConnectionRegistry registry;

  /// Returns the set of paired peer device ids — used to decide which live
  /// sessions are valid clipboard destinations.
  final Set<String> Function() pairedPeerIds;

  /// Content-free log sink: `(message, isError)`. NEVER receives clipboard text.
  final void Function(String message, bool isError) onLog;

  /// Fired when a peer's clipboard lands locally (text already written). Used
  /// by the UI to refresh state. `peerName` is best-effort (may be the id).
  final void Function(String peerName) onRemoteReceived;

  /// Injectable clock for tests.
  final DateTime Function() now;

  /// Injectable clipboard read/write seams. Default to Flutter's Clipboard;
  /// tests pass fakes so they don't depend on a system clipboard round-trip.
  final Future<String?> Function() readClipboard;
  final Future<void> Function(String text) writeClipboard;

  /// Whether this device should run the automatic PC-side poll. Defaults to
  /// `Platform.isWindows`; overridable in tests so the timer logic itself
  /// (level-driven arming, survival across a connectivity blip) can be
  /// exercised without depending on the host OS running the test suite.
  final bool Function() _isDesktopPlatform;

  final _controller = ClipboardController();
  Timer? _timer;
  bool _enabled = false;
  String? _pendingRemoteText;

  bool get isEnabled => _enabled;

  /// Exposed for testing pending background writes
  String? get pendingRemoteText => _pendingRemoteText;

  /// Enable/disable clipboard sync (driven by the config flag). Enabling arms
  /// the PC poll if conditions are met; disabling tears it down.
  void setEnabled(bool enabled) {
    _enabled = enabled;
    if (!enabled) {
      stopPolling();
      _pendingRemoteText = null;
    } else {
      _maybeStartPolling();
    }
  }

  /// Called by AppState whenever peer connectivity changes (connect/disconnect).
  ///
  /// The poll timer is now LEVEL-DRIVEN (see [_maybeStartPolling]): once
  /// armed, it keeps running for as long as the feature is enabled, and each
  /// tick independently re-checks [hasConnectedPeer]. This callback is kept
  /// as a cheap, idempotent safety net — e.g. it (re)arms the timer if
  /// [ClipboardSync] happened to be constructed while a peer was already
  /// connected — but correctness no longer depends on AppState calling this
  /// for every single connect/disconnect transition.
  void onPeerConnectivityChanged() {
    if (_enabled) {
      _maybeStartPolling();
      if (hasConnectedPeer()) {
        unawaited(sendCurrentClipboard());
      }
    }
  }

  /// Arms the poll timer for as long as the feature stays enabled.
  ///
  /// Deliberately does NOT gate on [hasConnectedPeer]: a peer being connected
  /// right now is a per-tick concern (checked inside [_pollOnce]), not a
  /// precondition for the timer existing. Gating here was the root cause of
  /// a bug where auto-sync would permanently stop after being idle: the old
  /// code only (re)started the timer from a connect/disconnect *event*, and
  /// [_pollOnce] would kill the timer the instant a single tick observed
  /// `hasConnectedPeer() == false` — including on a momentary blip (a
  /// heartbeat hiccup, a session being replaced mid-reconnect) where the
  /// underlying TCP session recovered fine on its own. Once that happened,
  /// nothing short of another connect/disconnect event could bring the timer
  /// back, so auto-push silently stayed off until the user manually sent a
  /// clipboard (which happens to call `sendCurrentClipboard`, not this path,
  /// but incidental window-focus/reconnect activity around that action was
  /// enough to fire a fresh event and re-arm it).
  ///
  /// Making the timer level-driven removes that dependency entirely: it runs
  /// continuously (one cheap dictionary/set lookup per tick, ~1.5s cadence)
  /// and is fully self-healing against any missed or coalesced connectivity
  /// transition.
  void _maybeStartPolling() {
    // PC-only. Android cannot read the clipboard from the background, so the
    // automatic PC→phone path only exists on desktop. The phone side is the
    // manual in-app "Send clipboard now" button.
    if (!_isDesktopPlatform()) return;
    if (!_enabled) return;
    if (_timer != null) return; // already running — idempotent no-op
    _timer = Timer.periodic(_pollInterval, (_) => _pollOnce());
  }

  void stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _pollOnce() async {
    // Only stop the timer because the FEATURE was turned off. A missing peer
    // is just "nothing to push this tick" — it must never tear the timer
    // down, or we're back to the permanent-stall bug (see
    // _maybeStartPolling doc). setEnabled(false) already calls stopPolling()
    // directly, so this is a belt-and-suspenders guard against the timer
    // firing one more time in the same event-loop turn as a disable.
    if (!_enabled) {
      stopPolling();
      return;
    }
    if (!hasConnectedPeer()) return;
    final text = await readClipboard();
    if (text == null) return;
    final hash = hashOf(text);

    if (_controller.onPolled(hash) == ClipboardPollDecision.push) {
      if (_broadcast(text)) {
        _controller.markOutboundPushed(hash);
      }
    }
  }

  /// Manual send: read the CURRENT clipboard (legal because the app is
  /// foreground when the user taps this) and push to all connected peers.
  /// Returns true if at least one peer received it.
  Future<bool> sendCurrentClipboard() async {
    final text = await readClipboard();
    if (text == null || text.isEmpty) return false;
    if (!hasConnectedPeer()) return false;
    final success = _broadcast(text);
    if (success) {
      _controller.markOutboundPushed(hashOf(text));
    }
    return success;
  }

  /// A peer pushed its clipboard — write ours and record the hash so our own
  /// poll doesn't echo it back.
  ///
  /// Success signal differs by platform (2026-07-11 fix — see `PROGRESS.md`
  /// / `THINKING.md` for the full investigation):
  ///
  ///   * Phone (`!_isDesktopPlatform()`, i.e. Android): the write goes
  ///     through the native `conduit/clipboard` channel, which uses
  ///     `applicationContext` specifically so it keeps working while the app
  ///     is backgrounded (see `MainActivity.kt`). A same-process readback
  ///     CANNOT verify that write: Android 10+ restricts clipboard *reads*
  ///     to whichever app currently has window focus (or the default IME) —
  ///     with no exception for the app that just wrote the data, and a
  ///     foreground service does not count as focus. So immediately after a
  ///     backgrounded write, a readback is denied by the OS regardless of
  ///     whether the write succeeded, which used to cause this method to
  ///     treat a successful write as "blocked". The native channel already
  ///     reports genuine write failures correctly (it throws), so on this
  ///     platform "the write call returned without throwing" IS the success
  ///     signal — no readback needed or trustworthy.
  ///
  ///   * Desktop (Windows): no such OS read restriction exists, so the
  ///     readback comparison remains a valid (and slightly stronger) check.
  Future<void> onPushReceived(String peerId, String text) async {
    if (!_enabled) return; // feature off → ignore
    final hash = hashOf(text);
    _pendingRemoteText = text;
    try {
      await writeClipboard(text);
      if (!_isDesktopPlatform()) {
        // Phone: the write call completing without throwing is the only
        // trustworthy signal available (see doc comment above).
        _pendingRemoteText = null;
      } else {
        final verify = await readClipboard();
        if (verify == text) {
          _pendingRemoteText = null;
        }
      }
    } catch (e) {
      onLog('Failed to write clipboard: $e', true);
      return;
    }
    _controller.markLocallyWritten(hash);

    onRemoteReceived(peerId);
  }

  /// Recover a pending clipboard write when the app is resumed (foregrounded).
  Future<void> onResume() async {
    final pending = _pendingRemoteText;
    if (pending != null && pending.isNotEmpty) {
      try {
        await writeClipboard(pending);
        final verify = await readClipboard();
        if (verify == pending) {
          _pendingRemoteText = null;
          onLog('Successfully wrote pending remote clipboard on resume', false);
        }
      } catch (e) {
        onLog('Failed to write pending clipboard on resume: $e', true);
      }
    }
  }

  bool hasConnectedPeer() {
    final paired = pairedPeerIds();
    for (final id in registry.readyPeerIds) {
      if (paired.contains(id)) return true;
    }
    return false;
  }

  /// Send [text] to every open session whose peer is paired. Returns true if
  /// at least one send succeeded.
  bool _broadcast(String text) {
    var sent = false;
    final paired = pairedPeerIds();
    for (final id in registry.readyPeerIds.toList()) {
      if (!paired.contains(id)) continue;
      final session = registry.openSessionFor(id);
      if (session == null) continue;
      try {
        session.send({'t': Msg.clipboardPush, 'text': text});
        sent = true;
      } catch (e) {
        onLog('Failed to send clipboard to $id: $e', true);
      }
    }
    if (sent) {
      onLog(
          'Sent clipboard (${text.length} chars) to connected peer(s)', false);
    }
    return sent;
  }

  /// Poll cadence for the automatic PC→phone watcher. Tuned for "feels
  /// instant" (~1–2s, per the Roadmap acceptance bar) while staying cheap: a
  /// clipboard read is a single OS call, not a filesystem walk.
  static const _pollInterval = Duration(milliseconds: 1500);

  void dispose() {
    stopPolling();
  }
}

// ---- Default clipboard read/write via Flutter's Clipboard ----------------
//
// The production defaults; tests inject fakes (see clipboard_sync_test.dart)
// so they don't depend on a system clipboard round-trip.

Future<String?> _defaultReadClipboard() async {
  try {
    final data = await Clipboard.getData('text/plain');
    return data?.text;
  } catch (_) {
    return null;
  }
}

Future<void> _defaultWriteClipboard(String text) async {
  if (Platform.isAndroid) {
    // On Android 10+ Flutter's Clipboard.setData() uses the Activity context,
    // which the OS may reject when the Activity is paused (background). Instead
    // we go through the native conduit/clipboard channel, which calls
    // ClipboardManager via applicationContext — the same process that hosts the
    // foreground SyncService. Android allows clipboard writes from foreground-
    // service processes, so this path works reliably in the background.
    const _ch = MethodChannel('conduit/clipboard');
    try {
      await _ch.invokeMethod<void>('write', {'text': text});
    } catch (_) {
      // If the native channel fails (e.g. during cold-start before the
      // FlutterEngine registers the handler), fall through to the Flutter API.
      await Clipboard.setData(ClipboardData(text: text));
    }
  } else {
    await Clipboard.setData(ClipboardData(text: text));
  }
}
