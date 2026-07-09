import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'src/app_state.dart';
import 'src/storage/db_factory.dart';
import 'src/ui/theme.dart';
import 'src/ui/dashboard_screen.dart';

/// Diagnostic note: prior to this change, an uncaught exception anywhere in
/// the widget tree (build/layout/paint) would, in a RELEASE build, render
/// Flutter's default release [ErrorWidget] — a bare, unlabeled grey box.
/// That is almost certainly what the "mobile screen goes blank" symptom in
/// the pairing audit actually was: a real exception with no visible trace.
///
/// This file now:
///   1. Replaces [ErrorWidget.builder] so build-time errors render a visible
///      message instead of a blank box, in every build mode.
///   2. Installs [FlutterError.onError] and [PlatformDispatcher.onError] so
///      framework- and zone-level errors are captured.
///   3. Runs the whole app inside [runZonedGuarded] so async errors that
///      escape normal try/catch (e.g. a synchronous throw inside a raw
///      `Socket.listen` data callback — see FrameCodec) are caught instead
///      of silently vanishing.
///   4. Appends every captured error to `crash_log.txt` in the app support
///      directory, so a blank/odd screen can be diagnosed after the fact
///      without a debugger attached.
Future<void> _logCrash(Object error, StackTrace stack,
    {String source = 'unknown'}) async {
  try {
    final dir = Platform.isWindows
        ? Directory(p.join(Platform.environment['APPDATA'] ?? '.', 'Conduit'))
        : await getApplicationSupportDirectory();
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'crash_log.txt'));
    final entry = StringBuffer()
      ..writeln('--- ${DateTime.now().toIso8601String()} [$source] ---')
      ..writeln(error.toString())
      ..writeln(stack.toString())
      ..writeln();
    await file.writeAsString(entry.toString(),
        mode: FileMode.append, flush: true);
  } catch (_) {
    // Best-effort only — never let crash logging itself throw.
  }
  // ignore: avoid_print
  print('[Conduit][$source] $error\n$stack');
}

void main() {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();

    // Build-time errors: show the real message instead of a blank/grey box.
    ErrorWidget.builder = (FlutterErrorDetails details) {
      _logCrash(details.exception, details.stack ?? StackTrace.empty,
          source: 'build');
      return Material(
        color: Colors.red.shade900,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Conduit hit an error while building the UI:\n\n'
              '${details.exception}\n\n'
              '${details.stack}',
              style: const TextStyle(
                  color: Colors.white, fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ),
      );
    };

    // Framework-level errors (layout, paint, gesture callbacks, etc).
    FlutterError.onError = (FlutterErrorDetails details) {
      _logCrash(details.exception, details.stack ?? StackTrace.empty,
          source: 'flutter');
      FlutterError.presentError(details);
    };

    // Errors from the platform (engine) side that aren't routed through the
    // current zone, e.g. some plugin callback failures.
    PlatformDispatcher.instance.onError = (error, stack) {
      _logCrash(error, stack, source: 'platform');
      return true; // handled — don't crash the isolate
    };

    // REDESIGN.md Phase 1: install the FFI SQLite factory BEFORE any code that
    // could open the per-folder Index DB. Done once, globally, here so every
    // later code path (engine, scanner) sees the same factory. The legacy sync
    // path doesn't use SQLite, so this is a pure no-op for the old engine.
    DbFactory.init();

    runApp(const ConduitApp());
  }, (error, stack) {
    // Catches anything that escapes the above — including a synchronous
    // throw inside a raw Socket.listen data callback (e.g. a malformed
    // frame in FrameCodec), which is NOT caught by any try/catch in the
    // async handshake chain since it never becomes a rejected Future there.
    _logCrash(error, stack, source: 'zone');
  });
}

class ConduitApp extends StatelessWidget {
  const ConduitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState(),
      child: MaterialApp(
        title: 'Conduit',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.system,
        home: const DashboardScreen(),
      ),
    );
  }
}
