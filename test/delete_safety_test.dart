import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/src/sync/delete_safety.dart';

void main() {
  test('ordinary small deletions never trigger the safety hold', () {
    expect(
      DeleteSafetyPolicy.shouldHold(deletedCount: 1, existingCount: 1),
      isFalse,
    );
    expect(
      DeleteSafetyPolicy.shouldHold(deletedCount: 3, existingCount: 3),
      isFalse,
    );
    expect(
      DeleteSafetyPolicy.shouldHold(deletedCount: 9, existingCount: 10),
      isFalse,
    );
  });

  test('hold requires both ten deletions and seventy percent', () {
    expect(
      DeleteSafetyPolicy.shouldHold(deletedCount: 10, existingCount: 15),
      isFalse,
      reason: '10/15 is only 66.7%',
    );
    expect(
      DeleteSafetyPolicy.shouldHold(deletedCount: 10, existingCount: 14),
      isTrue,
      reason: '10/14 is 71.4%',
    );
    expect(
      DeleteSafetyPolicy.shouldHold(deletedCount: 70, existingCount: 100),
      isTrue,
    );
  });
}
