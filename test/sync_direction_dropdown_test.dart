import 'package:conduit/src/protocol/wire.dart';
import 'package:conduit/src/ui/folder_pairs_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final direction in [
    SyncDirection.mirrorToPeer,
    SyncDirection.mirrorFromPeer,
  ]) {
    testWidgets('${direction.name} fits and opens on a narrow phone', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 240,
                child: SyncDirectionDropdownField(
                  value: direction,
                  onChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);

      await tester.tap(find.byType(DropdownButtonFormField<SyncDirection>));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  }
}
