import 'package:flutter_test/flutter_test.dart';
import 'package:conduit/src/sync/engine.dart';

void main() {
  group('ReconcileReason', () {
    test('enum contains all required reason codes', () {
      expect(ReconcileReason.values, contains(ReconcileReason.initialSeed));
      expect(ReconcileReason.values, contains(ReconcileReason.localChange));
      expect(
          ReconcileReason.values, contains(ReconcileReason.peerIndexChanged));
      expect(ReconcileReason.values, contains(ReconcileReason.peerConnected));
      expect(
          ReconcileReason.values, contains(ReconcileReason.replacementSession));
      expect(ReconcileReason.values, contains(ReconcileReason.manual));
      expect(
          ReconcileReason.values, contains(ReconcileReason.periodicSafetyNet));
    });
  });
}
