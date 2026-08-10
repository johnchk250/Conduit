/// Shared policy for deciding when a deletion burst is suspicious enough to
/// require an explicit user decision instead of propagating automatically.
///
/// The guard is intentionally aimed at catastrophic/near-folder wipes, not
/// ordinary cleanup. Both conditions must be true:
///   * at least [minimumDeletionCount] files are being deleted; and
///   * those files represent at least [dangerousPercent] of the relevant
///     pre-delete tracked/live set.
///
/// Keeping this policy in one place prevents the local scanner, receive-side
/// guard, and orphan-tombstone sweep from silently drifting to different
/// definitions of "mass deletion".
class DeleteSafetyPolicy {
  DeleteSafetyPolicy._();

  static const int minimumDeletionCount = 10;
  static const int dangerousPercent = 70;

  static bool shouldHold({
    required int deletedCount,
    required int existingCount,
  }) {
    if (deletedCount < minimumDeletionCount || existingCount <= 0) {
      return false;
    }
    return deletedCount * 100 >= existingCount * dangerousPercent;
  }
}
