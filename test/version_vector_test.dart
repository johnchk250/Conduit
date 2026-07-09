import 'package:conduit/src/sync/version_vector.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit tests for [VersionVector]. The ordering semantics are the load-bearing
/// part of the whole redesign — every later phase depends on these being
/// exactly right — so the tests deliberately over-specify: every branch of
/// dominates/concurrent/equality/merge/bump is covered with both the happy
/// and the boundary cases.
void main() {
  // Helper: build a vector from varargs. E.g. v('A', 2, 'B', 1) → VV{A:2,B:1}.
  // Up to 4 device/count pairs (8 positional args) — plenty for unit tests.
  VersionVector v(
    String k1,
    int v1, [
    String? k2,
    int? v2,
    String? k3,
    int? v3,
    String? k4,
    int? v4,
  ]) {
    final m = <String, int>{k1: v1};
    if (k2 != null) m[k2] = v2!;
    if (k3 != null) m[k3] = v3!;
    if (k4 != null) m[k4] = v4!;
    return VersionVector(m);
  }

  group('dominatesEq (>=)', () {
    test('reflexive: a >= a', () {
      final x = v('A', 2);
      expect(x.dominatesEq(x), isTrue);
    });

    test('equal vectors dominate-eq each other', () {
      expect(v('A', 2).dominatesEq(v('A', 2)), isTrue);
    });

    test('strictly-higher counter dominates', () {
      expect(v('A', 3).dominatesEq(v('A', 2)), isTrue);
    });

    test('strictly-lower counter does NOT dominate', () {
      expect(v('A', 1).dominatesEq(v('A', 2)), isFalse);
    });

    test('extra device on the dominating side still dominates', () {
      // VV{A:2,B:1} >= VV{A:2}  — extra info doesn't break dominance.
      expect(v('A', 2, 'B', 1).dominatesEq(v('A', 2)), isTrue);
    });

    test('extra device on the dominated side breaks dominance', () {
      // VV{A:2} is NOT >= VV{A:2,B:1} — we lack B's count.
      expect(v('A', 2).dominatesEq(v('A', 2, 'B', 1)), isFalse);
    });

    test('missing key treated as zero', () {
      // VV{A:2} >= VV{A:2,C:0} because C:0 == missing C.
      expect(v('A', 2).dominatesEq(VersionVector({'A': 2, 'C': 0})), isTrue);
    });
  });

  group('dominates (>)', () {
    test('strict dominance: same device, higher counter', () {
      expect(v('A', 3).dominates(v('A', 2)), isTrue);
    });

    test('equality is NOT strict dominance', () {
      expect(v('A', 2).dominates(v('A', 2)), isFalse);
    });

    test('extra device makes it strict', () {
      // VV{A:2,B:1} strictly dominates VV{A:2}.
      expect(v('A', 2, 'B', 1).dominates(v('A', 2)), isTrue);
    });
  });

  group('concurrentWith (conflict)', () {
    test('divergent single-device counts are concurrent', () {
      // A:1 vs A:2 is NOT concurrent — one dominates.
      expect(v('A', 1).concurrentWith(v('A', 2)), isFalse);
    });

    test('split-brain: A knows A2, B knows B2 — concurrent', () {
      expect(v('A', 2).concurrentWith(v('B', 2)), isTrue);
    });

    test('true concurrent: overlapping but neither dominates', () {
      // VV{A:2,B:1} vs VV{A:1,B:2} — neither >= the other.
      expect(v('A', 2, 'B', 1).concurrentWith(v('A', 1, 'B', 2)), isTrue);
    });

    test('symmetric', () {
      final a = v('A', 2, 'B', 1);
      final b = v('A', 1, 'B', 2);
      expect(a.concurrentWith(b), equals(b.concurrentWith(a)));
    });

    test('equal vectors are not concurrent', () {
      expect(v('A', 2).concurrentWith(v('A', 2)), isFalse);
    });
  });

  group('bump', () {
    test('absent device → 1', () {
      expect(VersionVector.empty().bump('A'), v('A', 1));
    });

    test('present device → +1', () {
      expect(v('A', 2).bump('A'), v('A', 3));
    });

    test('only the named device moves', () {
      expect(v('A', 2, 'B', 5).bump('A'), v('A', 3, 'B', 5));
    });

    test('does not mutate the receiver', () {
      final original = v('A', 2);
      final bumped = original.bump('A');
      expect(original, v('A', 2));
      expect(bumped, v('A', 3));
    });
  });

  group('merge', () {
    test('per-device max', () {
      expect(
        v('A', 2, 'B', 1).merge(v('A', 1, 'B', 3)),
        v('A', 2, 'B', 3),
      );
    });

    test('disjoint keys union', () {
      expect(v('A', 2).merge(v('B', 3)), v('A', 2, 'B', 3));
    });

    test('commutative', () {
      final a = v('A', 2, 'B', 1);
      final b = v('A', 1, 'B', 3);
      expect(a.merge(b), b.merge(a));
    });

    test('idempotent', () {
      final a = v('A', 2, 'B', 1);
      expect(a.merge(a), a);
    });

    test('does not mutate the receiver', () {
      final original = v('A', 2);
      original.merge(v('A', 5));
      expect(original, v('A', 2));
    });
  });

  group('equality & canonicalization', () {
    test('zero entries ignored for equality', () {
      expect(VersionVector({'A': 2, 'B': 0}), v('A', 2));
    });

    test('order-independent', () {
      expect(v('A', 1, 'B', 2), v('B', 2, 'A', 1));
    });

    test('hash matches for equal-but-differently-ordered', () {
      expect(v('A', 1, 'B', 2).hashCode, v('B', 2, 'A', 1).hashCode);
    });

    test('hash matches for zero-vs-absent', () {
      expect(VersionVector({'A': 2, 'B': 0}).hashCode, v('A', 2).hashCode);
    });

    test('empty vectors equal', () {
      expect(VersionVector.empty(), VersionVector.empty());
    });
  });

  group('dropZero', () {
    test('strips zeros, keeps non-zeros', () {
      expect(VersionVector({'A': 2, 'B': 0, 'C': 1}).dropZero(),
          v('A', 2, 'C', 1));
    });

    test('returns same instance when already canonical', () {
      final x = v('A', 2);
      expect(identical(x.dropZero(), x), isTrue);
    });
  });

  group('serialization', () {
    test('round-trip through JSON', () {
      final original = v('A', 2, 'B', 1);
      final rt = VersionVector.fromJson(original.toJson());
      expect(rt, original);
    });

    test('empty round-trips', () {
      expect(VersionVector.fromJson({}), VersionVector.empty());
    });

    test('zero entries stripped on serialize', () {
      final vv = VersionVector({'A': 2, 'B': 0});
      expect(vv.toJson(), {'A': 2});
    });

    test('rejects negative count', () {
      expect(() => VersionVector.fromJson({'A': -1}), throwsFormatException);
    });

    test('accepts num that is integral (JSON may decode as num)', () {
      expect(VersionVector.fromJson({'A': 2.0}), v('A', 2));
    });

    test('rejects non-numeric count', () {
      expect(() => VersionVector.fromJson({'A': 'two'}), throwsFormatException);
    });
  });

  group('immutability', () {
    test('counts map is unmodifiable', () {
      final vv = v('A', 1);
      expect(() => vv.counts['A'] = 5, throwsUnsupportedError);
      expect(() => vv.counts['B'] = 2, throwsUnsupportedError);
      expect(() => vv.counts.clear(), throwsUnsupportedError);
    });
  });

  group('toString', () {
    test('empty', () {
      expect(VersionVector.empty().toString(), 'VV{}');
    });
    test('sorted keys for stable output', () {
      // Insertion order B,A but output should be sorted A,B.
      expect(v('B', 2, 'A', 1).toString(), 'VV{A:1,B:2}');
    });
  });
}
