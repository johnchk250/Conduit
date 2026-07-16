import 'dart:io';

import '../core/config_store.dart';
import '../core/identity.dart';
import '../platform/saf_access.dart';
import '../sync/manifest.dart';

typedef IdentityLoader = Future<DeviceIdentity> Function(String platform);
typedef ConfigLoader = Future<ConfigStore> Function();
typedef SupportDirectoryLoader = Future<Directory> Function();
typedef FileSystemAccessFactory = FileSystemAccess Function(String platform);

/// Dependencies that vary between production, tests, and platform hosts.
///
/// This is intentionally constructed at the application root rather than
/// stored in a service locator. The secure handshake and sync engine are not
/// replaceable here: integration tests should exercise their real behavior.
class AppDependencies {
  const AppDependencies({
    required this.loadIdentity,
    required this.loadConfig,
    required this.loadSupportDirectory,
    required this.createFileSystemAccess,
    required this.now,
  });

  factory AppDependencies.production() => AppDependencies(
        loadIdentity: (platform) =>
            DeviceIdentity.loadOrCreate(platform: platform),
        loadConfig: ConfigStore.load,
        loadSupportDirectory: ConfigStore.appSupportDir,
        createFileSystemAccess: (platform) => platform == 'android'
            ? const SafFileSystemAccess()
            : const LocalFileSystemAccess(),
        now: DateTime.now,
      );

  final IdentityLoader loadIdentity;
  final ConfigLoader loadConfig;
  final SupportDirectoryLoader loadSupportDirectory;
  final FileSystemAccessFactory createFileSystemAccess;
  final DateTime Function() now;
}
