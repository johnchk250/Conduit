import '../app_state.dart';
import '../controllers/app_controllers.dart';
import 'app_dependencies.dart';

/// Application composition root and lifecycle owner.
class AppRuntime {
  AppRuntime({
    AppDependencies? dependencies,
    AppState? appState,
  }) : appState = appState ??
            AppState(
                dependencies: dependencies ?? AppDependencies.production()) {
    lifecycle = AppLifecycleController(this.appState);
    connections = ConnectionController(this.appState);
    folders = FolderSyncController(this.appState);
    transfers = TransferController(this.appState);
    deviceServices = DeviceServicesController(this.appState);
  }

  final AppState appState;
  late final AppLifecycleController lifecycle;
  late final ConnectionController connections;
  late final FolderSyncController folders;
  late final TransferController transfers;
  late final DeviceServicesController deviceServices;

  Future<void> start() => lifecycle.start();

  void dispose() {
    deviceServices.dispose();
    transfers.dispose();
    folders.dispose();
    connections.dispose();
    lifecycle.dispose();
    appState.dispose();
  }
}
