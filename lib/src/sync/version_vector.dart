/// Per-file version vector, the Syncthing-BEP model (REDESIGN.md §(2)).
///
/// A [VersionVector] is a map `{deviceId → counter}`. It is the ONLY ordering
/// authority in the new engine — it replaces both the legacy "last synced"
/// snapshot (which had no per-file provenance and could lose deletes) and the
/// Replaces the old size+mtime heuristic (which races against scan time).
///
/// ## Semantics
///
/// For two vectors `a` and `b`:
///   - `a == b` if their maps are equal (after dropping zero counters).
///   - `a >= b` ("a dominates-or-equals b") if `a[d] >= b[d]` for every device
///     `d`. Note the OR: equal counts are allowed.
///   - `a > b` ("a dominates b") if `a >= b` AND `a != b` — i.e. a is newer.
///   - **concurrent** if neither dominates the other. In the sync engine this
///     means a conflict: the loser is moved to `.syncversions` (see Phase 4).
///
/// Bumping is monotonic: when this device modifies a file, ONLY our own
/// counter is incremented — never anyone else's. Merging two vectors takes the
/// per-device max. This is what makes deletes propagate: a delete is just a
/// new vector with our counter bumped, so it dominates the live version.
///
/// ## Why per-device keys, not a single scalar
///
/// A single Lamport-style counter would lose information about WHICH device
/// saw what. With a vector, "I have seen device X's version 3" is a precise
/// statement that survives any reorder of network messages. This is the same
/// trick Syncthing, Riak, and Dynamo all use for exactly this problem.
///
/// ## Immutability
///
/// Instances are immutable. [bump], [merge], and [dropZero] return NEW vectors;
/// the receiver is never mutated. This makes them safe to share between the
/// scanner thread, the engine, and the SQLite row without defensive copies.
///
/// We deliberately do NOT implement `Map<K,V>`: that interface is full of
/// mutating methods (`[]=`, `addAll`, `update`, ...) which would all have to
/// throw to preserve immutability. A narrow, purpose-built API is clearer and
/// lets the compiler enforce that we never accidentally mutate one.
class VersionVector {
  /// Empty vector — the starting point for a brand-new file that no device
  /// has modified yet. Distinct from a vector that was bumped to 0 (which
  /// cannot exist; bumps always go to >=1).
  const VersionVector.empty() : _counts = const {};

  /// Build from an explicit map. Defensive copy is taken; zero entries are
  /// NOT pruned here (call [dropZero] if you need canonical form). Public so
  /// [VersionVector.fromJson] and callers (e.g. tests) can construct one.
  VersionVector(Map<String, int> counts)
      : _counts = Map<String, int>.unmodifiable(counts);

  final Map<String, int> _counts;

  /// Read-only view of the underlying counters. Returns an unmodifiable map;
  /// callers cannot mutate the vector through it. Useful when you need to
  /// iterate entries directly (e.g. diffing in Phase 4).
  Map<String, int> get counts => _counts;

  /// Counter for [deviceId], or 0 if this device is unknown. A missing key
  /// and a zero are observationally identical (see [dominatesEq]); this
  /// getter makes that explicit.
  int countFor(String deviceId) => _counts[deviceId] ?? 0;

  /// Whether [deviceId] is present in the vector (regardless of value).
  bool knows(String deviceId) => _counts.containsKey(deviceId);

  /// Number of devices recorded. After [dropZero] this is the canonical size.
  int get length => _counts.length;

  /// Whether the vector is the empty `{}`. Note: a vector with only zero
  /// entries is NOT [isEmpty] until [dropZero] is called.
  bool get isEmpty => _counts.isEmpty;

  // ---- ordering ------------------------------------------------------------

  /// `true` iff this vector dominates-or-equals [other]: every device's count
  /// here is >= the corresponding count there. Devices present in [other] but
  /// absent here are treated as count 0 here (a missing key IS a zero).
  ///
  /// Reflexive: `a >= a` is always true. Combined with [==] this gives the
  /// full partial order; [dominates] is the strict variant.
  bool dominatesEq(VersionVector other) {
    for (final entry in other._counts.entries) {
      final mine = _counts[entry.key] ?? 0;
      if (mine < entry.value) return false;
    }
    return true;
  }

  /// `true` iff this vector STRICTLY dominates [other]: dominatesEq AND not
  /// equal. This is the "newer" relation used by the sync diff in Phase 4.
  bool dominates(VersionVector other) => dominatesEq(other) && this != other;

  /// `true` iff neither vector dominates the other — a CONCURRENT (conflict)
  /// pair. Phase 4 uses this to decide `.syncversions` moves. Symmetric.
  bool concurrentWith(VersionVector other) =>
      !dominatesEq(other) && !other.dominatesEq(this);

  // ---- mutation (returns new instances) ------------------------------------

  /// Return a new vector with [deviceId]'s counter incremented by one (or set
  /// to 1 if absent). This is the "I changed this file" operation: only OUR
  /// counter moves, never a peer's. Monotonic — never decreases.
  VersionVector bump(String deviceId) {
    final next = Map<String, int>.from(_counts);
    next[deviceId] = (next[deviceId] ?? 0) + 1;
    return VersionVector(next);
  }

  /// Return a new vector taking the per-device MAX of this and [other]. Used
  /// when a peer's index entry arrives and we record "the highest version of
  /// this file I've observed". Idempotent and commutative.
  VersionVector merge(VersionVector other) {
    final next = Map<String, int>.from(_counts);
    other._counts.forEach((device, count) {
      final cur = next[device] ?? 0;
      if (count > cur) next[device] = count;
    });
    return VersionVector(next);
  }

  /// Canonical form: drop any zero entries. A zero count is observationally
  /// identical to an absent key (see [dominatesEq]), so we normalize before
  /// serializing and before equality checks to keep [==] and persistence
  /// stable. Returns `this` if already canonical, else a new vector.
  VersionVector dropZero() {
    if (!_counts.values.any((v) => v == 0)) return this;
    final next = Map<String, int>.from(_counts)..removeWhere((_, v) => v == 0);
    return VersionVector(next);
  }

  // ---- equality & hashing (canonical: zero-stripped) -----------------------

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! VersionVector) return false;
    final a = _canonical(_counts);
    final b = _canonical(other._counts);
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAllUnordered(
        _canonical(_counts).entries.map((e) => Object.hash(e.key, e.value)),
      );

  static Map<String, int> _canonical(Map<String, int> m) =>
      m.values.any((v) => v == 0)
          ? (Map<String, int>.from(m)..removeWhere((_, v) => v == 0))
          : m;

  // ---- serialization -------------------------------------------------------

  /// JSON form: an object `{deviceId: counter, ...}`. Zero entries are
  /// stripped so the persisted/transport form is canonical and round-trips
  /// through [==].
  Map<String, dynamic> toJson() => dropZero()._counts;

  /// Inverse of [toJson]. Accepts the empty object `{}` (→ [empty]). Throws
  /// [FormatException] on negative or non-integer counts — a corrupt vector
  /// on disk or off the wire is a hard error, not silently coerced.
  factory VersionVector.fromJson(Map<String, dynamic> j) {
    final counts = <String, int>{};
    j.forEach((device, raw) {
      final v = raw is int ? raw : (raw is num ? raw.toInt() : null);
      if (v == null) {
        throw FormatException(
            'VersionVector entry for "$device" is not an integer: $raw');
      }
      if (v < 0) {
        throw FormatException(
            'VersionVector entry for "$device" is negative: $v');
      }
      if (v != 0) counts[device] = v;
    });
    return VersionVector(counts);
  }

  /// Compact, debug-friendly representation, e.g. `VV{A:2,B:1}`. Device order
  /// is sorted for stable output (helps log diffing).
  @override
  String toString() {
    if (_counts.isEmpty) return 'VV{}';
    final keys = _counts.keys.toList()..sort();
    final body = keys.map((k) => '$k:${_counts[k]}').join(',');
    return 'VV{$body}';
  }
}
