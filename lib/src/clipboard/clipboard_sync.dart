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

  /// Clear remembered content when the feature is disabled. Re-enabling then
  /// treats the current clipboard as a fresh value and synchronizes it once.
  void reset() {
    _lastHandledHash = null;
    _suppressUntil = null;
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

/// Automatic clipboard payload ceiling. This keeps an accidentally copied
/// multi-megabyte document from causing large allocations and protocol frames
/// on every connected device.
const maxAutomaticClipboardBytes = 256 * 1024;

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
  bool _pollInProgress = false;
  bool _enabled = false;
  String? _pendingRemoteText;
  String? _lastObservedHash;
  bool _allowFanoutForObservedValue = false;
  final Map<String, String> _lastSentHashByPeer = <String, String>{};

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
      _lastObservedHash = null;
      _allowFanoutForObservedValue = false;
      _lastSentHashByPeer.clear();
      _controller.reset();
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
    if (!_enabled) return;
    _maybeStartPolling();
    if (hasConnectedPeer() && _isDesktopPlatform()) {
      unawaited(_syncAfterConnectivityChange());
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
    // is just "nothing to push this tick" — it must never tear the timer down.
    if (!_enabled) {
      stopPolling();
      return;
    }
    if (!hasConnectedPeer() || _pollInProgress) return;
    _pollInProgress = true;
    try {
      final text = await readClipboard();
      if (text == null || !_isPayloadAllowed(text, outbound: true)) return;
      final hash = hashOf(text);
      final changed = hash != _lastObservedHash;

      if (changed) {
        if (_controller.onPolled(hash) != ClipboardPollDecision.push) {
          // A different value copied during the short echo-suppression window
          // must be retried on the next tick. Do not remember it as observed
          // until the controller actually permits the push.
          _allowFanoutForObservedValue = false;
          return;
        }
        _lastObservedHash = hash;
        _allowFanoutForObservedValue = true;
      }

      if (_allowFanoutForObservedValue) {
        final sent = _broadcastToMissingPeers(text, hash);
        if (sent.isNotEmpty) _controller.markOutboundPushed(hash);
      }
    } finally {
      _pollInProgress = false;
    }
  }

  /// Reconcile the current desktop clipboard with per-peer delivery state. An
  /// unchanged value is not re-sent to a peer that already received it, but a
  /// new peer (or a clipboard change made during an outage) gets the latest
  /// value immediately instead of waiting for the next timer tick.
  Future<void> _syncAfterConnectivityChange() async {
    if (!_enabled || !hasConnectedPeer() || _pollInProgress) return;
    _pollInProgress = true;
    try {
      final text = await readClipboard();
      if (text == null || !_isPayloadAllowed(text, outbound: true)) return;
      final hash = hashOf(text);
      final changed = hash != _lastObservedHash;

      if (changed) {
        if (_controller.onPolled(hash) != ClipboardPollDecision.push) {
          // A different value copied during the short echo-suppression window
          // must be retried on the next tick. Do not remember it as observed
          // until the controller actually permits the push.
          _allowFanoutForObservedValue = false;
          return;
        }
        _lastObservedHash = hash;
        _allowFanoutForObservedValue = true;
      }

      // Per-peer hashes suppress unchanged reconnect re-sends. A clipboard
      // value copied while the peer was offline still has no delivery record,
      // so it is sent immediately when that peer returns.
      if (_allowFanoutForObservedValue) {
        final sent = _broadcastToMissingPeers(text, hash);
        if (sent.isNotEmpty) _controller.markOutboundPushed(hash);
      }
    } finally {
      _pollInProgress = false;
    }
  }

  /// Manual send: read the CURRENT clipboard (legal because the app is
  /// foreground when the user taps this) and push to all connected peers,
  /// or to a single [targetPeerId] if specified.
  /// Returns true if at least one peer received it.
  Future<bool> sendCurrentClipboard({String? targetPeerId}) async {
    final text = await readClipboard();
    if (text == null || text.isEmpty || !_isPayloadAllowed(text, outbound: true)) {
      return false;
    }
    if (!hasConnectedPeer()) return false;
    final hash = hashOf(text);
    final sent = _broadcast(text, targetPeerId: targetPeerId, hash: hash);
    if (sent.isNotEmpty) {
      _lastObservedHash = hash;
      _allowFanoutForObservedValue = targetPeerId == null;
      _controller.markOutboundPushed(hash);
    }
    return sent.isNotEmpty;
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
    if (!_isPayloadAllowed(text, outbound: false)) return;
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
    _lastObservedHash = hash;
    // The source peer already has this value. Keep fan-out enabled so a third
    // paired device receives it, while the per-peer delivery map prevents an
    // echo back to the sender now or after a reconnect.
    _allowFanoutForObservedValue = true;
    _lastSentHashByPeer[peerId] = hash;
    final forwarded = _broadcastToMissingPeers(text, hash);
    if (forwarded.isNotEmpty) _controller.markOutboundPushed(hash);

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

  Set<String> _broadcastToMissingPeers(String text, String hash) {
    final missing = registry.readyPeerIds
        .where((id) => _lastSentHashByPeer[id] != hash)
        .toSet();
    return _broadcast(text, targetPeerIds: missing, hash: hash);
  }

  /// Send [text] to paired, ready peers. Returns the ids whose send call
  /// succeeded and records the per-peer hash for reconnect deduplication.
  Set<String> _broadcast(
    String text, {
    String? targetPeerId,
    Set<String>? targetPeerIds,
    required String hash,
  }) {
    final sent = <String>{};
    final paired = pairedPeerIds();
    final peerIds = targetPeerIds ??
        (targetPeerId != null
            ? registry.readyPeerIds.where((id) => id == targetPeerId).toSet()
            : registry.readyPeerIds.toSet());
    for (final id in peerIds) {
      if (!paired.contains(id)) continue;
      final session = registry.openSessionFor(id);
      if (session == null || !session.isLinkReady) continue;
      try {
        session.send({'t': Msg.clipboardPush, 'text': text});
        sent.add(id);
        _lastSentHashByPeer[id] = hash;
      } catch (e) {
        onLog('Failed to send clipboard to $id: $e', true);
      }
    }
    if (sent.isNotEmpty) {
      onLog(
          'Sent clipboard (${text.length} chars) to ${sent.length} peer(s)',
          false);
    }
    return sent;
  }

  bool _isPayloadAllowed(String text, {required bool outbound}) {
    final bytes = utf8.encode(text).length;
    if (bytes <= maxAutomaticClipboardBytes) return true;
    onLog(
      '${outbound ? 'Clipboard' : 'Received clipboard'} ignored: '
      '$bytes bytes exceeds the $maxAutomaticClipboardBytes-byte limit',
      true,
    );
    return false;
  }

  /// Poll cadence for the automatic PC→phone watcher. Tuned for "feels
  /// instant" (~1–2s, per the Roadmap acceptance bar) while staying cheap: a
  /// clipboard read is a single OS call, not a filesystem walk.
  static const _pollInterval = Duration(milliseconds: 1500);

  void dispose() {
    stopPolling();
    _lastSentHashByPeer.clear();
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
    const channel = MethodChannel('conduit/clipboard');
    try {
      await channel.invokeMethod<void>('write', {'text': text});
    } catch (_) {
      // If the native channel fails (e.g. during cold-start before the
      // FlutterEngine registers the handler), fall through to the Flutter API.
      await Clipboard.setData(ClipboardData(text: text));
    }
  } else {
    await Clipboard.setData(ClipboardData(text: text));
  }
}
