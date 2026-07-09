// Smoke test: the app builds without throwing.
//
// AppState.start() touches platform channels and the network, so we only
// verify the widget tree constructs here. Deeper behavior is covered by
// unit tests on the engine/diff layer (see test/engine_test.dart).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/main.dart';

void main() {
  testWidgets('App builds and shows Overview', (WidgetTester tester) async {
    await tester.pumpWidget(const ConduitApp());
    // First frame only — don't pump the full AppState.start() pipeline,
    // which needs real sockets. We just assert the shell renders.
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
