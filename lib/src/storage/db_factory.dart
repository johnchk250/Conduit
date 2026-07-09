import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// One-time initialization for the SQLite backend used by the per-folder Index
/// DB (REDESIGN.md Phase 1).
///
/// `sqflite_common_ffi` provides a single FFI-based [DatabaseFactory] that
/// works on BOTH desktop (Windows/macOS/Linux) and Android. On Windows it
/// loads `sqlite3.dll` from the OS; on Android the native binary is shipped by
/// `sqlite3_flutter_libs` and `sqflite_common_ffi` resolves it. We MUST set
/// this factory globally before any `databaseFactory` call, otherwise
/// `sqflite_common_ffi` falls back to the (mobile-only) platform channel
/// `sqflite` plugin, which does NOT exist on Windows and would throw.
///
/// Idempotent: calling [init] more than once is a no-op. It is invoked from
/// `main.dart` before `runApp`, and again lazily from [IndexDb.open] so any
/// code path (including tests) is safe.
class DbFactory {
  DbFactory._();

  static bool _initialized = false;

  /// Initialize the FFI SQLite factory. Safe to call from any isolate; the
  /// underlying [databaseFactory] setter in `sqflite_common_ffi` is itself
  /// idempotent, and we add our own guard to keep the diagnostic log clean.
  static void init() {
    if (_initialized) return;
    // On Android sqflite_common_ffi needs to know where the bundled native
    // library lives; `sqfliteFfiInit()` registers the loader. On desktop it
    // is a no-op aside from setting the resolver. Either way it is required
    // before [databaseFactory] is used.
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _initialized = true;
    // ignore: avoid_print
    print('[Conduit][db] sqflite_ffi factory installed '
        '(platform=${Platform.isAndroid ? "android" : Platform.isWindows ? "windows" : "other"})');
  }

  /// Whether [init] has run in this isolate.
  static bool get isInitialized => _initialized;
}
