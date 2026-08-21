// Regression tests for GlassButton input handling.
//
// The accessibility rework once replaced the pointer GestureDetector with
// FocusableActionDetector (which handles ONLY focus/cursor/keyboard), leaving
// every GlassButton in the app dead to taps. These tests pin both input
// paths: pointer tap and keyboard activation.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/src/ui/glass.dart';

const _accent = Color(0xFFA78BFA);

Widget _host({bool enabled = true, VoidCallback? onTap}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: GlassButton(
          icon: Icons.sync_rounded,
          label: 'Sync now',
          accentColor: _accent,
          enabled: enabled,
          onTap: onTap,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('GlassButton responds to pointer taps', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(onTap: () => taps++));
    await tester.tap(find.byType(GlassButton), warnIfMissed: true);
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('GlassButton activates via keyboard (Tab then Enter)',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(onTap: () => taps++));
    // The button is the only focusable widget in this tree.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    // Pump past the press-animation delay timer started by activation.
    await tester.pump(const Duration(milliseconds: 120));
    expect(taps, 1);
  });

  testWidgets('disabled GlassButton ignores pointer taps', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(enabled: false, onTap: () => taps++));
    await tester.tap(find.byType(GlassButton), warnIfMissed: true);
    await tester.pump();
    expect(taps, 0);
  });
}
