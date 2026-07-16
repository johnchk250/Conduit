import 'dart:io';

import 'package:conduit/src/core/config_store.dart';
import 'package:conduit/src/core/identity.dart';
import 'package:conduit/src/runtime/app_dependencies.dart';
import 'package:conduit/src/sync/manifest.dart';

AppDependencies testDependencies({
  required DeviceIdentity identity,
  required ConfigStore config,
  required Directory supportDirectory,
  DateTime Function()? now,
}) =>
    AppDependencies(
      loadIdentity: (_) async => identity,
      loadConfig: () async => config,
      loadSupportDirectory: () async => supportDirectory,
      createFileSystemAccess: (_) => const LocalFileSystemAccess(),
      now: now ?? DateTime.now,
    );
