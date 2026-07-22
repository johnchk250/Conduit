import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:conduit/src/clipboard/clipboard_sync.dart';
import 'package:conduit/src/core/config_store.dart';
import 'package:conduit/src/net/peer_registry.dart';
import 'package:conduit/src/net/peer_session.dart';
import 'package:conduit/src/protocol/wire.dart';
import 'package:conduit/src/storage/db_factory.dart';
import 'package:conduit/src/sync/engine.dart';
import 'package:conduit/src/sync/manifest.dart';

/// Roadmap Phase 2 — clipboard sync tests.
///
/// Two layers under test:
///
///   1. **ClipboardController** — the pure echo-loop guard. This is the only
///      non-obvious logic in Phase 2 (see clipboard_sync.dart doc). Its job is
///      to stop the PC's auto-pusher from echoing a value the PC itself just
///      received and wrote. These tests pin the three properties: skip when
///      unchanged, push when new, skip within the suppress window after a local
///      write. Pure, no Flutter/IO — uses an injectable clock.
///
///   2. **Engine routing** — a `Msg.clipboardPush` arriving on a live session
///      fires the `onClipboardPush` callback with the text. This is the single
///      engine touch point for Phase 2; it must stay additive and segregated
///      from the V2 cases. Reuses the real `_handlePeerMessage` via
///      `handlePeerMessageForTest`, the same way engine_v2_test.dart does.
///
///   3. **ClipboardSync broadcast** — `sendCurrentClipboard` / the poll loop
///      emit a `clipboardPush` frame on every open paired session. A minimal
///      fake session + real `PeerConnectionRegistry` verifies the frame shape.
///
/// Engine-safe note: none of these tests touch the Index DB, version vectors,
/// or the needs-queue. They exist to guard the Phase 2 addition in isolation.

const _aliceDeviceId = 'AAAA-1111';
const _bobDeviceId = 'BBBB-2222';

void main() {
  DbFactory.init();

  group('ClipboardController (echo-loop guard)', () {
    test('pushes a genuinely new clipboard value', () {
      final c = ClipboardController();
      expect(c.onPolled('hash-A'), ClipboardPollDecision.push);
    });

    test('skips a value identical to the last one pushed', () {
      final c = ClipboardController();
      c.markOutboundPushed('hash-A');
      // Polling the same hash again must NOT re-push — that's the unchanged-
      // content skip, which is what keeps us from spamming the wire on every
      // poll tick once the clipboard is settled.
      expect(c.onPolled('hash-A'), ClipboardPollDecision.skip);
    });

    test('pushes a different value after a prior push', () {
      final c = ClipboardController();
      c.markOutboundPushed('hash-A');
      expect(c.onPolled('hash-B'), ClipboardPollDecision.push);
    });

    test('skips a value we just wrote locally (echo-loop break)', () {
      // The core safety property: phone sends Y → PC writes Y → PC's poller
      // sees Y. Without the suppress window, the PC would push Y right back,
      // starting an infinite echo loop. markLocallyWritten opens a window in
      // which the matching poll is skipped.
      var fakeNow = DateTime(2026, 6, 26, 12, 0, 0);
      final c = ClipboardController(now: () => fakeNow);
      c.markLocallyWritten('hash-Y');
      // Immediately after: the same hash is within the suppress window → skip.
      expect(c.onPolled('hash-Y'), ClipboardPollDecision.skip);
    });

    test('a NEW value is delayed by the suppress window but pushes after', () {
      // The suppress window blocks ALL hashes (not just the matching one):
      // during the async write lag the OS may report a stale old value that
      // differs from what we just wrote, and we must not echo it back. A
      // genuinely new copy lands during the window → skipped (delayed), but
      // after the window expires it pushes normally. Worst case is an 800ms
      // delay on a new copy made in the exact window — acceptable.
      var fakeNow = DateTime(2026, 6, 26, 12, 0, 0);
      final c = ClipboardController(now: () => fakeNow);
      c.markLocallyWritten('hash-Y');
      // During the window: even a different hash is skipped.
      expect(c.onPolled('hash-Z'), ClipboardPollDecision.skip);
      // After the 800ms window expires: the new value pushes.
      fakeNow = fakeNow.add(const Duration(seconds: 1));
      expect(c.onPolled('hash-Z'), ClipboardPollDecision.push);
    });

    test('suppress window expires, allowing the same hash again', () {
      // After the suppress window passes, a poll of the locally-written hash
      // is treated normally again (it matches lastHandledHash → skip, because
      // it's unchanged). This confirms the controller's state is consistent
      // over time, not that the window permanently blocks.
      var fakeNow = DateTime(2026, 6, 26, 12, 0, 0);
      final c = ClipboardController(now: () => fakeNow);
      c.markLocallyWritten('hash-Y');
      // Advance well past the 800ms suppress window.
      fakeNow = fakeNow.add(const Duration(seconds: 5));
      // Still the last-handled hash → skip (unchanged content), but a NEW
      // value now pushes because the window no longer blocks it.
      expect(c.onPolled('hash-Y'), ClipboardPollDecision.skip);
      expect(c.onPolled('hash-W'), ClipboardPollDecision.push);
    });
  });

  group('engine routes clipboardPush', () {
    late _EngineHarness h;

    setUp(() async {
      h = await _EngineHarness.create();
    });
    tearDown(() async {
      await h.dispose();
    });

    test('fires onClipboardPush with the text from an inbound frame', () async {
      h.connectAlice();
      final received = <(String, String)>[];
      h.alice = SyncEngine(
        fs: h.aliceFs,
        config: h.cfg,
        stateDir: h.stateDir,
        registry: h.registry,
        deviceId: _aliceDeviceId,
        onClipboardPush: (peerId, text) => received.add((peerId, text)),
      );
      // Re-wire the handler on the new engine instance.
      h.alice.onPeerConnected(h.session);

      await h.alice.handlePeerMessageForTest(h.session, {
        't': Msg.clipboardPush,
        'text': 'hello from Bob',
      });

      expect(received, [(_bobDeviceId, 'hello from Bob')]);
    });

    test('handles missing text field gracefully (empty string)', () async {
      h.connectAlice();
      var got = '';
      h.alice = SyncEngine(
        fs: h.aliceFs,
        config: h.cfg,
        stateDir: h.stateDir,
        registry: h.registry,
        deviceId: _aliceDeviceId,
        onClipboardPush: (peerId, text) => got = text,
      );
      h.alice.onPeerConnected(h.session);

      await h.alice.handlePeerMessageForTest(h.session, {
        't': Msg.clipboardPush,
        // no 'text' field
      });

      expect(got, '');
    });

    test('does not touch the V2 Index DB (engine-safe)', () async {
      // A clipboardPush must NOT create/modify any Index DB rows. Deliver one,
      // then confirm the DB (if any pair was opened) has no clipboard artefact.
      // Since clipboardPush carries no pairId, _pairById returns null and no DB
      // is even consulted — but this test pins that contract.
      h.connectAlice();
      h.alice = SyncEngine(
        fs: h.aliceFs,
        config: h.cfg,
        stateDir: h.stateDir,
        registry: h.registry,
        deviceId: _aliceDeviceId,
        onClipboardPush: (_, __) {},
      );
      h.alice.onPeerConnected(h.session);

      await h.alice.handlePeerMessageForTest(h.session, {
        't': Msg.clipboardPush,
        'text': 'x',
      });
      // No exception thrown and no sent frames is the success signal — the
      // handler must be a pure passthrough to the callback.
      expect(h.session.sent.where((m) => m['t'] == Msg.error), isEmpty);
    });
  });

  group('ClipboardSync broadcast', () {
    test('sendCurrentClipboard emits clipboardPush on paired ready sessions',
        () async {
      final registry = PeerConnectionRegistry();
      final session = _FakeSession();
      registry.publish(_bobDeviceId, session);

      final sync = ClipboardSync(
        registry: registry,
        pairedPeerIds: () => {_bobDeviceId},
        onLog: (_, __) {},
        onRemoteReceived: (_) {},
        now: DateTime.now,
        // Fake clipboard seam: returns fixed text, no system dependency.
        readClipboard: () async => 'hello from test',
        writeClipboard: (_) async {},
      );
      sync.setEnabled(true);

      final ok = await sync.sendCurrentClipboard();
      expect(ok, isTrue);
      expect(session.sent, isNotEmpty);
      final push = session.sent.single;
      expect(push['t'], Msg.clipboardPush);
      expect(push['text'], 'hello from test');
      sync.dispose();
    });

    test('rejects oversized clipboard payloads without sending', () async {
      final registry = PeerConnectionRegistry();
      final session = _FakeSession();
      registry.publish(_bobDeviceId, session);
      final oversized = 'x' * (maxAutomaticClipboardBytes + 1);

      final sync = ClipboardSync(
        registry: registry,
        pairedPeerIds: () => {_bobDeviceId},
        onLog: (_, __) {},
        onRemoteReceived: (_) {},
        now: DateTime.now,
        readClipboard: () async => oversized,
        writeClipboard: (_) async {},
      );
      sync.setEnabled(true);

      expect(await sync.sendCurrentClipboard(), isFalse);
      expect(session.sent, isEmpty);
      sync.dispose();
    });

    test('received clipboard fans out without echoing to its source', () async {
      const charlieId = 'CHARLIE-DEVICE-0001';
      final registry = PeerConnectionRegistry();
      final bob = _FakeSession();
      final charlie = _FakeSession();
      registry.publish(_bobDeviceId, bob);
      registry.publish(charlieId, charlie);

      final sync = ClipboardSync(
        registry: registry,
        pairedPeerIds: () => {_bobDeviceId, charlieId},
        onLog: (_, __) {},
        onRemoteReceived: (_) {},
        now: DateTime.now,
        readClipboard: () async => 'shared value',
        writeClipboard: (_) async {},
        isDesktopPlatform: () => false,
      );
      sync.setEnabled(true);

      await sync.onPushReceived(_bobDeviceId, 'shared value');

      expect(bob.sent, isEmpty);
      expect(charlie.sent, hasLength(1));
      expect(charlie.sent.single['text'], 'shared value');
      sync.dispose();
    });

    test('does not send to an unpaired peer', () async {
      final registry = PeerConnectionRegistry();
      final session = _FakeSession();
      registry.publish('UNKNOWN-PEER', session); // connected but NOT paired

      final sync = ClipboardSync(
        registry: registry,
        pairedPeerIds: () => {_bobDeviceId}, // Bob is paired but not connected
        onLog: (_, __) {},
        onRemoteReceived: (_) {},
        now: DateTime.now,
      );
      sync.setEnabled(true);

      final ok = await sync.sendCurrentClipboard();
      expect(ok, isFalse); // no paired peer received it
      expect(session.sent, isEmpty);
      sync.dispose();
    });

    test('onPushReceived is a no-op when disabled (feature off)', () async {
      final registry = PeerConnectionRegistry();
      final sync = ClipboardSync(
        registry: registry,
        pairedPeerIds: () => {},
        onLog: (_, __) {},
        onRemoteReceived: (_) {},
        now: DateTime.now,
      );
      // Not enabled.
      await sync.onPushReceived(_bobDeviceId, 'should be ignored');
      // No throw, no side effect — the acceptance bar for "feature off → no
      // clipboardPush is ever acted on".
      sync.dispose();
    });
  });

  group('ClipboardSync auto-poll timer (level-driven, regression)', () {
    // Pins the exact bug reported: the PC-side auto-poll used to be
    // EVENT-driven (only (re)armed from a connect/disconnect callback) and
    // would PERMANENTLY self-terminate the instant a single tick observed
    // hasConnectedPeer() == false — even a transient blip where the real TCP
    // session recovered on its own. After that, nothing but a fresh
    // connect/disconnect event could bring it back, so auto-push silently
    // stayed off for the rest of the idle session. These tests prove the
    // timer is now LEVEL-driven: it keeps running for as long as the feature
    // is enabled, regardless of how many blips it sees, and with NO reliance
    // on onPeerConnectivityChanged being called again after the blip.

    test('auto-poll pushes on the normal tick while a peer is connected', () {
      fakeAsync((async) {
        final registry = PeerConnectionRegistry();
        final session = _FakeSession();
        registry.publish(_bobDeviceId, session);

        var clipboardText = 'first value';
        final sync = ClipboardSync(
          registry: registry,
          pairedPeerIds: () => {_bobDeviceId},
          onLog: (_, __) {},
          onRemoteReceived: (_) {},
          now: DateTime.now,
          readClipboard: () async => clipboardText,
          writeClipboard: (_) async {},
          isDesktopPlatform: () => true, // force PC-poll path in the test
        );

        sync.setEnabled(true);
        async.elapse(const Duration(milliseconds: 1500));

        expect(session.sent, hasLength(1));
        expect(session.sent.single['text'], 'first value');
        sync.dispose();
      });
    });

    test(
        'a transient disconnect blip does NOT permanently kill the timer '
        '(the core regression)', () {
      fakeAsync((async) {
        final registry = PeerConnectionRegistry();
        final session = _FakeSession();
        registry.publish(_bobDeviceId, session);

        var clipboardText = 'value A';
        final sync = ClipboardSync(
          registry: registry,
          pairedPeerIds: () => {_bobDeviceId},
          onLog: (_, __) {},
          onRemoteReceived: (_) {},
          now: DateTime.now,
          readClipboard: () async => clipboardText,
          writeClipboard: (_) async {},
          isDesktopPlatform: () => true,
        );

        sync.setEnabled(true);

        // Normal tick: peer connected, pushes 'value A'.
        async.elapse(const Duration(milliseconds: 1500));
        expect(session.sent, hasLength(1));

        // Simulate the transient blip: the peer briefly disappears from the
        // registry for exactly one poll tick (e.g. a heartbeat hiccup or a
        // session being replaced mid-reconnect), with NO call to
        // onPeerConnectivityChanged — this is the worst case that used to
        // permanently null out the timer.
        registry.forceDrop(_bobDeviceId);
        async.elapse(const Duration(milliseconds: 1500));
        // No push happened this tick (nothing connected) — and critically,
        // no new clipboard content to push anyway.
        expect(session.sent, hasLength(1));

        // The underlying session recovers on its own, exactly as described:
        // "it's not a connection problem" — the peer is back, but crucially
        // we do NOT call onPeerConnectivityChanged() again here. If the old
        // event-driven code regressed, the timer would be null forever and
        // the assertions below would fail.
        registry.publish(_bobDeviceId, session);
        clipboardText = 'value B';
        async.elapse(const Duration(milliseconds: 1500));

        expect(session.sent, hasLength(2));
        expect(session.sent.last['text'], 'value B');
        sync.dispose();
      });
    });

    test('setEnabled(false) actually stops the timer (no ticks after)', () {
      fakeAsync((async) {
        final registry = PeerConnectionRegistry();
        final session = _FakeSession();
        registry.publish(_bobDeviceId, session);

        final sync = ClipboardSync(
          registry: registry,
          pairedPeerIds: () => {_bobDeviceId},
          onLog: (_, __) {},
          onRemoteReceived: (_) {},
          now: DateTime.now,
          readClipboard: () async => 'value',
          writeClipboard: (_) async {},
          isDesktopPlatform: () => true,
        );

        sync.setEnabled(true);
        async.elapse(const Duration(milliseconds: 1500));
        expect(session.sent, hasLength(1));

        sync.setEnabled(false);
        async.elapse(const Duration(seconds: 10));
        // Still just the one send from before disabling — the timer must
        // not keep firing once the feature itself is off.
        expect(session.sent, hasLength(1));
        sync.dispose();
      });
    });

    test('never arms the timer on a non-desktop platform', () {
      fakeAsync((async) {
        final registry = PeerConnectionRegistry();
        final session = _FakeSession();
        registry.publish(_bobDeviceId, session);

        final sync = ClipboardSync(
          registry: registry,
          pairedPeerIds: () => {_bobDeviceId},
          onLog: (_, __) {},
          onRemoteReceived: (_) {},
          now: DateTime.now,
          readClipboard: () async => 'value',
          writeClipboard: (_) async {},
          isDesktopPlatform: () => false, // e.g. Android
        );

        sync.setEnabled(true);
        async.elapse(const Duration(seconds: 10));
        expect(session.sent, isEmpty);
        sync.dispose();
      });
    });

    test('immediate push on peer connection ready', () {
      fakeAsync((async) {
        final registry = PeerConnectionRegistry();
        final session = _FakeSession();
        // Initially no peer connected.
        final sync = ClipboardSync(
          registry: registry,
          pairedPeerIds: () => {_bobDeviceId},
          onLog: (_, __) {},
          onRemoteReceived: (_) {},
          now: DateTime.now,
          readClipboard: () async => 'immediate value',
          writeClipboard: (_) async {},
          isDesktopPlatform: () => true,
        );

        sync.setEnabled(true);
        // Connect peer and mark ready.
        registry.publish(_bobDeviceId, session);

        // Trigger connectivity change event.
        sync.onPeerConnectivityChanged();

        // Wait for microtasks to run (since sendCurrentClipboard is async).
        async.elapse(const Duration(milliseconds: 10));

        expect(session.sent, hasLength(1));
        expect(session.sent.single['text'], 'immediate value');
        sync.dispose();
      });
    });

    test('unchanged clipboard is not re-sent to the same peer on reconnect', () {
      fakeAsync((async) {
        final registry = PeerConnectionRegistry();
        final session = _FakeSession();
        final sync = ClipboardSync(
          registry: registry,
          pairedPeerIds: () => {_bobDeviceId},
          onLog: (_, __) {},
          onRemoteReceived: (_) {},
          now: DateTime.now,
          readClipboard: () async => 'stable value',
          writeClipboard: (_) async {},
          isDesktopPlatform: () => true,
        );

        sync.setEnabled(true);
        registry.publish(_bobDeviceId, session);
        sync.onPeerConnectivityChanged();
        async.elapse(const Duration(milliseconds: 10));
        expect(session.sent, hasLength(1));

        registry.forceDrop(_bobDeviceId);
        registry.publish(_bobDeviceId, session);
        sync.onPeerConnectivityChanged();
        async.elapse(const Duration(milliseconds: 10));
        expect(session.sent, hasLength(1));
        sync.dispose();
      });
    });

    test('clipboard changed while offline is sent immediately on reconnect', () {
      fakeAsync((async) {
        final registry = PeerConnectionRegistry();
        final session = _FakeSession();
        var clipboardText = 'value A';
        final sync = ClipboardSync(
          registry: registry,
          pairedPeerIds: () => {_bobDeviceId},
          onLog: (_, __) {},
          onRemoteReceived: (_) {},
          now: DateTime.now,
          readClipboard: () async => clipboardText,
          writeClipboard: (_) async {},
          isDesktopPlatform: () => true,
        );

        sync.setEnabled(true);
        registry.publish(_bobDeviceId, session);
        sync.onPeerConnectivityChanged();
        async.elapse(const Duration(milliseconds: 10));
        expect(session.sent.single['text'], 'value A');

        registry.forceDrop(_bobDeviceId);
        clipboardText = 'value B';
        async.elapse(const Duration(seconds: 2));
        registry.publish(_bobDeviceId, session);
        sync.onPeerConnectivityChanged();
        async.elapse(const Duration(milliseconds: 10));

        expect(session.sent, hasLength(2));
        expect(session.sent.last['text'], 'value B');
        sync.dispose();
      });
    });

    test('failed broadcast does not mark as pushed (retries on next tick)', () {
      fakeAsync((async) {
        final registry = PeerConnectionRegistry();
        final failingSession = _FailingFakeSession();
        registry.publish(_bobDeviceId, failingSession);

        var clipboardText = 'value';
        final sync = ClipboardSync(
          registry: registry,
          pairedPeerIds: () => {_bobDeviceId},
          onLog: (_, __) {},
          onRemoteReceived: (_) {},
          now: DateTime.now,
          readClipboard: () async => clipboardText,
          writeClipboard: (_) async {},
          isDesktopPlatform: () => true,
        );

        sync.setEnabled(true);

        // Timer ticks. Broadcast fails due to exception.
        async.elapse(const Duration(milliseconds: 1500));

        // Replace failing session with working session.
        final workingSession = _FakeSession();
        registry.publish(_bobDeviceId, workingSession);

        // Wait for next timer tick. Since the previous failed, it should retry.
        async.elapse(const Duration(milliseconds: 1500));

        expect(workingSession.sent, hasLength(1));
        expect(workingSession.sent.single['text'], 'value');
        sync.dispose();
      });
    });

    test('successful broadcast marks as pushed (does not retry on next tick)',
        () {
      fakeAsync((async) {
        final registry = PeerConnectionRegistry();
        final session = _FakeSession();
        registry.publish(_bobDeviceId, session);

        var clipboardText = 'value';
        final sync = ClipboardSync(
          registry: registry,
          pairedPeerIds: () => {_bobDeviceId},
          onLog: (_, __) {},
          onRemoteReceived: (_) {},
          now: DateTime.now,
          readClipboard: () async => clipboardText,
          writeClipboard: (_) async {},
          isDesktopPlatform: () => true,
        );

        sync.setEnabled(true);

        // Timer ticks. Broadcast succeeds.
        async.elapse(const Duration(milliseconds: 1500));
        expect(session.sent, hasLength(1));
        expect(session.sent.single['text'], 'value');

        // Next timer tick. Since it succeeded, it should NOT send again.
        async.elapse(const Duration(milliseconds: 1500));
        expect(session.sent, hasLength(1)); // Still just 1 sent message

        sync.dispose();
      });
    });
  });

  // -------------------------------------------------------------------------
  // Background write recovery (Android 10+ clipboard restriction)
  // -------------------------------------------------------------------------

  group('ClipboardSync background write recovery', () {
    _FakeClipboard makeClipboard({String? initial}) {
      return _FakeClipboard(initial: initial);
    }

    ClipboardSync makeSync({
      required _FakeClipboard clipboard,
      bool Function()? isDesktopPlatform,
    }) {
      final registry = PeerConnectionRegistry();
      final session = _FakeSession();
      registry.publish(_bobDeviceId, session);
      session.markLinkReady();

      return ClipboardSync(
        registry: registry,
        pairedPeerIds: () => {_bobDeviceId},
        onLog: (_, __) {},
        onRemoteReceived: (_) {},
        now: DateTime.now,
        readClipboard: clipboard.read,
        writeClipboard: clipboard.write,
        isDesktopPlatform: isDesktopPlatform ?? (() => false),
      );
    }

    test(
        'pendingRemoteText is null when clipboard write succeeds immediately (foreground)',
        () async {
      final clip = makeClipboard();
      final sync = makeSync(clipboard: clip);
      sync.setEnabled(true);

      // write will succeed because the fake clipboard always works
      await sync.onPushReceived(_bobDeviceId, 'hello world');

      expect(sync.pendingRemoteText, isNull,
          reason:
              'Write verified successfully — no pending text should remain');
      expect(await clip.read(), 'hello world');
    });

    test('pendingRemoteText is set when the write call itself genuinely fails',
        () async {
      final clip = makeClipboard();
      // Simulate a genuine failure: the write call throws.
      final failingClip = _FailingWriteClipboard(delegate: clip);
      final registry = PeerConnectionRegistry();
      final session = _FakeSession();
      registry.publish(_bobDeviceId, session);
      session.markLinkReady();

      final sync = ClipboardSync(
        registry: registry,
        pairedPeerIds: () => {_bobDeviceId},
        onLog: (_, __) {},
        onRemoteReceived: (_) {},
        now: DateTime.now,
        readClipboard: failingClip.read,
        writeClipboard: failingClip.write,
        isDesktopPlatform: () => false,
      );
      sync.setEnabled(true);

      await sync.onPushReceived(_bobDeviceId, 'secret text');

      expect(sync.pendingRemoteText, 'secret text',
          reason:
              'The write call threw — text should be stored as pending for resume');
    });

    test(
        'pendingRemoteText is cleared on a successful phone write even when '
        'a same-process readback would be denied (regression test for the '
        'false "clipboard blocked" notification — 2026-07-11)', () async {
      final clip = makeClipboard();
      final focusRestricted = _FocusRestrictedReadClipboard(delegate: clip);
      final registry = PeerConnectionRegistry();
      final session = _FakeSession();
      registry.publish(_bobDeviceId, session);
      session.markLinkReady();

      final sync = ClipboardSync(
        registry: registry,
        pairedPeerIds: () => {_bobDeviceId},
        onLog: (_, __) {},
        onRemoteReceived: (_) {},
        now: DateTime.now,
        readClipboard: focusRestricted.read,
        writeClipboard: focusRestricted.write,
        // Phone, not desktop — this is the platform where the native write
        // channel is used and the OS read restriction applies.
        isDesktopPlatform: () => false,
      );
      sync.setEnabled(true);

      await sync.onPushReceived(_bobDeviceId, 'hello world');

      expect(focusRestricted.actuallyWritten, 'hello world',
          reason: 'The write itself genuinely succeeded');
      expect(sync.pendingRemoteText, isNull,
          reason: 'A successful write must not be reported as pending/'
              'blocked just because the OS denies the readback used to '
              'verify it — that denial is independent of write success on '
              'Android 10+ (focus-gated reads, not focus-gated writes)');
    });

    test('onResume commits the pending clipboard and clears it', () async {
      final clip = makeClipboard();
      final failingClip = _FailingWriteClipboard(delegate: clip);
      final registry = PeerConnectionRegistry();
      final session = _FakeSession();
      registry.publish(_bobDeviceId, session);
      session.markLinkReady();

      final sync = ClipboardSync(
        registry: registry,
        pairedPeerIds: () => {_bobDeviceId},
        onLog: (_, __) {},
        onRemoteReceived: (_) {},
        now: DateTime.now,
        readClipboard: failingClip.read,
        writeClipboard: failingClip.write,
        isDesktopPlatform: () => false,
      );
      sync.setEnabled(true);

      // Simulate receiving a push while the write genuinely fails.
      await sync.onPushReceived(_bobDeviceId, 'queued text');
      expect(sync.pendingRemoteText, 'queued text');

      // The transient failure clears — unblock and call onResume.
      failingClip.unblock();
      await sync.onResume();

      expect(sync.pendingRemoteText, isNull,
          reason:
              'After successful resume write, pending text should be cleared');
      expect(await clip.read(), 'queued text',
          reason: 'The pending text must be written on resume');
    });

    test('setEnabled(false) clears any pending clipboard', () async {
      final clip = makeClipboard();
      final failingClip = _FailingWriteClipboard(delegate: clip);
      final registry = PeerConnectionRegistry();
      final session = _FakeSession();
      registry.publish(_bobDeviceId, session);
      session.markLinkReady();

      final sync = ClipboardSync(
        registry: registry,
        pairedPeerIds: () => {_bobDeviceId},
        onLog: (_, __) {},
        onRemoteReceived: (_) {},
        now: DateTime.now,
        readClipboard: failingClip.read,
        writeClipboard: failingClip.write,
        isDesktopPlatform: () => false,
      );
      sync.setEnabled(true);
      await sync.onPushReceived(_bobDeviceId, 'queued text');
      expect(sync.pendingRemoteText, 'queued text');

      sync.setEnabled(false);
      expect(sync.pendingRemoteText, isNull,
          reason: 'Disabling sync should clear pending clipboard');
    });
  });
}

// ---------------------------------------------------------------------------
// Fake clipboard helpers for background write tests
// ---------------------------------------------------------------------------

/// A simple in-memory clipboard that always succeeds.
class _FakeClipboard {
  _FakeClipboard({String? initial}) : _value = initial;
  String? _value;
  Future<String?> read() async => _value;
  Future<void> write(String text) async => _value = text;
}

/// Simulates a GENUINE write failure — e.g. the native `conduit/clipboard`
/// channel throwing (see `MainActivity.kt`'s `CH_CLIPBOARD` "write" handler
/// erroring out), or the cold-start race noted in `_defaultWriteClipboard`
/// before the channel registers: [write] throws while blocked, and
/// succeeds once [unblock] is called. This is the one real failure mode the
/// native write path can hit, and it's already surfaced as a thrown
/// exception in production — [ClipboardSync.onPushReceived]'s `catch (e)`
/// is what's expected to handle it.
class _FailingWriteClipboard {
  _FailingWriteClipboard({required _FakeClipboard delegate})
      : _delegate = delegate;
  final _FakeClipboard _delegate;
  bool _blocked = true;

  void unblock() => _blocked = false;

  Future<String?> read() => _delegate.read();

  Future<void> write(String text) async {
    if (_blocked) {
      throw Exception('simulated clipboard write failure');
    }
    await _delegate.write(text);
  }
}

/// Simulates Android 10+'s OS-level clipboard READ restriction: this app
/// isn't focused (it's running from the background sync service), so any
/// readback is denied and comes back stale/empty — even though [write]
/// genuinely lands on the "system" clipboard (the delegate). This models
/// the real production asymmetry that caused the false "clipboard blocked"
/// notification bug (see `PROGRESS.md` / `THINKING.md`, 2026-07-11): a
/// same-process readback cannot be used to confirm a background write on
/// Android, independent of whether that write actually succeeded.
class _FocusRestrictedReadClipboard {
  _FocusRestrictedReadClipboard({required _FakeClipboard delegate})
      : _delegate = delegate;
  final _FakeClipboard _delegate;

  /// The write genuinely succeeds — inspect this directly in assertions
  /// instead of going through [read], which always simulates denial.
  String? get actuallyWritten => _delegate._value;

  Future<String?> read() async => null; // OS pretends the clipboard is empty

  Future<void> write(String text) => _delegate.write(text);
}

// ---------------------------------------------------------------------------
// Minimal engine harness (clipboard only — no Index DB / reconcile needed)
// ---------------------------------------------------------------------------

class _EngineHarness {
  _EngineHarness(this.tmp, this.cfg, this.stateDir, this.registry, this.session,
      this.aliceFs);

  final Directory tmp;
  ConfigStore cfg;
  late Directory stateDir;
  final PeerConnectionRegistry registry;
  final _FakeSession session;
  late SyncEngine alice;
  final _NoopFs aliceFs;

  static Future<_EngineHarness> create() async {
    final tmp = await Directory.systemTemp.createTemp('clipboard_test_');
    final stateDir = Directory(p.join(tmp.path, 'support'));
    await stateDir.create(recursive: true);

    final cfgFile = File(p.join(tmp.path, 'config.json'));
    final cfg = ConfigStore.forTest(cfgFile, {
      'folderPairs': [],
      'pairedPeers': [
        PairedPeer(
          deviceId: _bobDeviceId,
          name: 'Bob',
          platform: 'test',
          publicKeyB64: '',
        ).toJson(),
      ],
    });

    final registry = PeerConnectionRegistry();
    final aliceFs = _NoopFs();
    final session = _FakeSession();
    registry.publish(_bobDeviceId, session);

    // alice is (re)created per-test with the desired onClipboardPush callback.
    final h = _EngineHarness(tmp, cfg, stateDir, registry, session, aliceFs);
    h.alice = SyncEngine(
      fs: aliceFs,
      config: cfg,
      stateDir: stateDir,
      registry: registry,
      deviceId: _aliceDeviceId,
    );
    return h;
  }

  void connectAlice() {
    alice.onPeerConnected(session);
  }

  Future<void> dispose() async {
    await alice.dispose();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  }
}

/// A FileSystemAccess that does nothing — clipboard tests never touch the FS.
/// The engine only calls fs methods during reconcile, which we never run here,
/// so every member is a stub that absorbs any stray call.
class _NoopFs implements FileSystemAccess {
  @override
  bool get isAndroidSAF => false;
  @override
  Future<List<String>> listFiles(String rootPath) async => const [];
  @override
  Future<FileEntry?> stat(String rootPath, String relPath) async => null;
  @override
  Stream<List<int>> openRead(String rootPath, String relPath,
      [int offset = 0]) {
    return const Stream<List<int>>.empty();
  }

  @override
  Future<void> write(String rootPath, String relPath, List<int> data) async {}
  @override
  Future<void> append(String rootPath, String relPath, List<int> data) async {}
  @override
  Future<bool> delete(String rootPath, String relPath) async => false;
  @override
  Future<String> moveToVault(String rootPath, String relPath) async => '';
}

/// Minimal PeerSession fake — only send/onMessage/generation/peer/isClosed are
/// touched by the clipboard path. Heartbeat/socket members are no-ops so no
/// timer keeps the test zone alive.
class _FakeSession implements PeerSession {
  @override
  final PairedPeer peer = PairedPeer(
    deviceId: _bobDeviceId,
    name: 'Bob',
    platform: 'test',
    publicKeyB64: '',
  );

  @override
  final int generation = 1;

  final List<Map<String, dynamic>> sent = [];

  @override
  set onMessage(void Function(Map<String, dynamic> msg) handler) {}

  @override
  set onError(void Function(Object error) handler) {}

  @override
  set onDone(void Function() handler) {}

  @override
  bool get isClosed => false;

  bool _linkReady = true;

  @override
  bool get hasReceivedLinkReady => _linkReady;

  @override
  bool get isLinkReady => _linkReady && !isClosed;

  @override
  void Function()? onLinkReady;

  @override
  bool markLinkReady() {
    if (_linkReady) return false;
    _linkReady = true;
    onLinkReady?.call();
    return true;
  }

  @override
  void send(Map<String, dynamic> msg) {
    msg['msgId'] ??= 'test-${sent.length}';
    sent.add(msg);
  }

  @override
  void startHeartbeat({required void Function() onDead}) {}
  @override
  void restartHeartbeat() {}
  @override
  void handlePong(String? hbId) {}
  @override
  void stopHeartbeat() {}
  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailingFakeSession extends _FakeSession {
  @override
  void send(Map<String, dynamic> msg) {
    throw Exception('Simulated send failure');
  }
}
