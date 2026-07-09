// Regression test for the manifest-exchange timeout.
//
// Symptom (captured 2026-06-23): every inbound `manifest` / `folder_invite` /
// `chunk` on Android threw
//
//   Concurrent modification during iteration: _Map len:N.
//     #2 RecentMsgIds.saw (engine.dart:1015)
//     #3 SyncEngine._handlePeerMessage (engine.dart:774)
//
// inside the idempotency guard — BEFORE the manifest ever reached its handler.
// The handler therefore never completed the PC's `_manifestWaiters` completer,
// and the PC's `await ...timeout(15s)` fired every time. Root cause: `saw()`
// swept stale entries by calling `_seen.remove(key)` *while still iterating*
// `_seen.entries.iterator`, which Dart forbids. Once any single entry aged
// past the 60s TTL (inevitable on a long-lived heartbeat session), the very
// next non-ping/pong message tripped the sweep and crashed the handler.
//
// These tests drive the TTL-sweep path with a tiny injectable TTL so no
// real-time waits are needed, and assert the sweep runs without throwing.

import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/src/sync/engine.dart';

void main() {
  group('RecentMsgIds', () {
    test('saw() does not throw when a stale entry needs sweeping', () async {
      final r = RecentMsgIds(ttl: const Duration(milliseconds: 5));
      r.saw('stale-1');
      // Cross the TTL so 'stale-1' is sweepable. A 0-delay yield is not enough
      // on a fast host, so wait a concrete 20ms.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // Pre-fix this threw ConcurrentModificationError because the sweep
      // removed from `_seen` while iterating it.
      expect(() => r.saw('fresh-1'), returnsNormally);
      expect(r.saw('fresh-1'), isTrue,
          reason: 'second sighting is a duplicate');
    });

    test('saw() sweeps many stale entries in one call without throwing',
        () async {
      final r = RecentMsgIds(ttl: const Duration(milliseconds: 5));
      // Seed a burst, let them all go stale together, then one fresh saw() must
      // walk the whole stale head of the map without CME.
      for (var i = 0; i < 100; i++) {
        r.saw('old-$i');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(() => r.saw('after-burst'), returnsNormally);
    });

    test('saw() reports duplicates and accepts new ids', () {
      final r = RecentMsgIds();
      expect(r.saw('a'), isFalse, reason: 'first sighting is new');
      expect(r.saw('a'), isTrue, reason: 'second sighting is a duplicate');
      expect(r.saw('b'), isFalse);
    });

    test('saw() does not sweep fresh entries', () {
      final r = RecentMsgIds(ttl: const Duration(seconds: 60));
      r.saw('fresh-a');
      r.saw('fresh-b');
      // Nothing stale, so the second id is still recognized as a duplicate on
      // a third call — proving the sweep didn't over-evict the fresh entries.
      expect(r.saw('fresh-b'), isTrue);
    });
  });
}
