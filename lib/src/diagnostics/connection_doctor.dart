import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../core/config_store.dart';
import '../net/transport.dart';
import '../protocol/wire.dart';

enum DiagnosticStatus { pending, ok, warning, error }

enum DiagnosticAction {
  openWindowsFirewall,
  copyWindowsFirewallCommand,
  openAndroidBatterySettings,
  openAndroidNotificationSettings,
  requestBluetoothPermissions,
}

@immutable
class DiagnosticCheck {
  const DiagnosticCheck({
    required this.id,
    required this.title,
    required this.status,
    required this.explanation,
    this.remediationAction,
    this.technicalDetails,
    this.actions = const [],
  });

  final String id;
  final String title;
  final DiagnosticStatus status;
  final String explanation;
  final String? remediationAction;
  final String? technicalDetails;
  final List<DiagnosticAction> actions;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'status': status.name,
        'explanation': explanation,
        if (remediationAction != null) 'remediationAction': remediationAction,
        if (technicalDetails != null) 'technicalDetails': technicalDetails,
        if (actions.isNotEmpty)
          'actions': actions.map((action) => action.name).toList(),
      };
}

class ConnectionDoctor {
  const ConnectionDoctor(this.appState);

  final AppState appState;

  Future<List<DiagnosticCheck>> run({String? peerId}) async {
    if (!appState.isStarted) {
      return const [
        DiagnosticCheck(
          id: 'startup',
          title: 'Application startup',
          status: DiagnosticStatus.error,
          explanation: 'Conduit has not finished initializing.',
          remediationAction: 'Wait a moment, then run the checks again.',
        ),
      ];
    }

    final checks = <DiagnosticCheck>[
      const DiagnosticCheck(
        id: 'identity',
        title: 'Identity and configuration',
        status: DiagnosticStatus.ok,
        explanation: 'Device identity and configuration loaded successfully.',
      ),
      const DiagnosticCheck(
        id: 'secure_protocol',
        title: 'Secure protocol',
        status: DiagnosticStatus.ok,
        explanation: 'Secure Transport v1 is required; plaintext is disabled.',
        technicalDetails: 'wireProtocol=${Msg.protocolVersion}',
      ),
      DiagnosticCheck(
        id: 'listener',
        title: 'Local listener',
        status: DiagnosticStatus.ok,
        explanation: 'The connection listener is running.',
        technicalDetails: 'platform=${appState.identity.platform}',
      ),
      DiagnosticCheck(
        id: 'bluetooth',
        title: 'Bluetooth fallback',
        status: appState.bluetoothStatusHealthy
            ? DiagnosticStatus.ok
            : DiagnosticStatus.warning,
        explanation: appState.bluetoothStatus,
        remediationAction: appState.bluetoothStatusHealthy
            ? null
            : 'Review Bluetooth permissions or leave LAN enabled.',
        actions: Platform.isAndroid && !appState.bluetoothStatusHealthy
            ? const [DiagnosticAction.requestBluetoothPermissions]
            : const [],
      ),
    ];

    for (final pair in appState.config.folderPairs) {
      try {
        await appState.fs.listFiles(pair.localPath);
        checks.add(
          DiagnosticCheck(
            id: 'folder_${pair.id}',
            title: 'Folder access: ${pair.name}',
            status: DiagnosticStatus.ok,
            explanation: 'The saved folder grant/path is readable.',
            technicalDetails: 'pair=${_short(pair.id)}',
          ),
        );
      } catch (error) {
        checks.add(
          DiagnosticCheck(
            id: 'folder_${pair.id}',
            title: 'Folder access: ${pair.name}',
            status: DiagnosticStatus.error,
            explanation: 'The saved folder is no longer accessible.',
            remediationAction: 'Edit the folder pair and reselect the folder.',
            technicalDetails: error.runtimeType.toString(),
          ),
        );
      }
    }

    if (Platform.isAndroid) {
      checks.add(
        const DiagnosticCheck(
          id: 'android_background',
          title: 'Android background operation',
          status: DiagnosticStatus.warning,
          explanation:
              'Android may restrict background networking and folder access.',
          remediationAction:
              'Allow notifications and set battery use to Unrestricted.',
          actions: [
            DiagnosticAction.openAndroidBatterySettings,
            DiagnosticAction.openAndroidNotificationSettings,
          ],
        ),
      );
    } else if (Platform.isWindows) {
      checks.add(
        const DiagnosticCheck(
          id: 'windows_firewall',
          title: 'Windows firewall',
          status: DiagnosticStatus.warning,
          explanation:
              'Conduit cannot prove firewall reachability from inside the app.',
          remediationAction:
              'Allow the current Conduit executable on private networks.',
          actions: [
            DiagnosticAction.openWindowsFirewall,
            DiagnosticAction.copyWindowsFirewallCommand,
          ],
        ),
      );
    }

    if (peerId != null) {
      PairedPeer? peer;
      for (final candidate in appState.pairedPeers) {
        if (candidate.deviceId == peerId) {
          peer = candidate;
          break;
        }
      }
      if (peer == null) {
        checks.add(
          const DiagnosticCheck(
            id: 'peer_pin',
            title: 'Peer identity',
            status: DiagnosticStatus.error,
            explanation: 'This device is not paired or its pin was removed.',
            remediationAction: 'Pair the device again from the Devices page.',
          ),
        );
      } else {
        final connection = appState.connectionStateFor(peerId);
        final discovered =
            appState.discoveredPeers.any((item) => item.deviceId == peerId);
        checks.add(
          DiagnosticCheck(
            id: 'peer_discovery',
            title: 'Peer discovery',
            status: discovered ? DiagnosticStatus.ok : DiagnosticStatus.warning,
            explanation: discovered
                ? 'The peer is visible on a current transport.'
                : 'The peer is not currently discovered; a saved address may still work.',
            remediationAction:
                discovered ? null : 'Check that both devices share a network.',
          ),
        );
        checks.add(
          DiagnosticCheck(
            id: 'peer_connection',
            title: 'Secure peer connection',
            status: connection.phase == PeerConnectionPhase.connected
                ? DiagnosticStatus.ok
                : connection.phase == PeerConnectionPhase.connecting
                    ? DiagnosticStatus.warning
                    : DiagnosticStatus.error,
            explanation: connection.phase == PeerConnectionPhase.connected
                ? 'TCP and secure verification succeeded over ${connection.transport?.label ?? 'the active transport'}.'
                : connection.phase == PeerConnectionPhase.connecting
                    ? 'A connection attempt is in progress.'
                    : 'No verified secure session is active.',
            remediationAction: connection.phase == PeerConnectionPhase.connected
                ? null
                : 'Retry the connection and verify the peer identity pin.',
            technicalDetails:
                'peer=${_short(peerId)} phase=${connection.phase.name}',
          ),
        );
      }
    }
    return checks;
  }

  Future<String> exportSanitized({String? peerId}) async {
    final checks = await run(peerId: peerId);
    final body = <String, dynamic>{
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'appVersion': '2.0.0+2',
      'wireProtocol': Msg.protocolVersion,
      'platform': appState.identity.platform,
      'localDevice': _short(appState.identity.deviceId),
      'pairedPeers': appState.pairedPeers
          .map(
            (peer) => {
              'id': _short(peer.deviceId),
              'platform': peer.platform,
              'connection':
                  appState.connectionStateFor(peer.deviceId).phase.name,
            },
          )
          .toList(),
      'folderPairs': appState.config.folderPairs
          .map(
            (pair) => {
              'id': _short(pair.id),
              'direction': pair.direction.name,
              'status': appState.stateFor(pair.id)?.status ?? 'idle',
            },
          )
          .toList(),
      'checks': checks.map((check) => check.toJson()).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(body);
  }

  static String _short(String value) => value.length <= 8
      ? value
      : '${value.substring(0, 4)}…${value.substring(value.length - 4)}';
}
