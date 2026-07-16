import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../diagnostics/connection_doctor.dart';

class ConnectionDoctorScreen extends StatefulWidget {
  const ConnectionDoctorScreen({super.key, this.peerId});

  final String? peerId;

  @override
  State<ConnectionDoctorScreen> createState() => _ConnectionDoctorScreenState();
}

class _ConnectionDoctorScreenState extends State<ConnectionDoctorScreen> {
  Future<List<DiagnosticCheck>>? _checks;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _checks ??= _run();
  }

  Future<List<DiagnosticCheck>> _run() =>
      ConnectionDoctor(context.read<AppState>()).run(peerId: widget.peerId);

  void _retry() => setState(() => _checks = _run());

  Future<void> _runAction(DiagnosticAction action) async {
    final state = context.read<AppState>();
    switch (action) {
      case DiagnosticAction.openWindowsFirewall:
        try {
          await Process.start(
            'control.exe',
            const ['firewall.cpl'],
            mode: ProcessStartMode.detached,
          );
        } catch (error) {
          if (mounted) _showMessage('Could not open Firewall settings: $error');
        }
      case DiagnosticAction.copyWindowsFirewallCommand:
        final executable = Platform.resolvedExecutable.replaceAll('"', '');
        final command =
            'netsh advfirewall firewall add rule name="Conduit" dir=in '
            'action=allow program="$executable" protocol=TCP '
            'localport=${state.listenerPort} profile=private enable=yes';
        await Clipboard.setData(ClipboardData(text: command));
        if (mounted) {
          _showMessage(
            'Firewall command copied. Run it in an Administrator terminal.',
          );
        }
      case DiagnosticAction.openAndroidBatterySettings:
        state.openBatteryOptimizationSettings();
      case DiagnosticAction.openAndroidNotificationSettings:
        state.openNotificationSettings();
      case DiagnosticAction.requestBluetoothPermissions:
        await state.requestBluetoothPermissions();
        if (mounted) {
          _showMessage('Bluetooth permission request completed.');
          _retry();
        }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String _actionLabel(DiagnosticAction action) => switch (action) {
        DiagnosticAction.openWindowsFirewall => 'Open Firewall Settings',
        DiagnosticAction.copyWindowsFirewallCommand => 'Copy setup command',
        DiagnosticAction.openAndroidBatterySettings => 'Open battery settings',
        DiagnosticAction.openAndroidNotificationSettings =>
          'Open notification settings',
        DiagnosticAction.requestBluetoothPermissions =>
          'Review Bluetooth permission',
      };

  IconData _actionIcon(DiagnosticAction action) => switch (action) {
        DiagnosticAction.openWindowsFirewall => Icons.security_outlined,
        DiagnosticAction.copyWindowsFirewallCommand => Icons.copy_outlined,
        DiagnosticAction.openAndroidBatterySettings =>
          Icons.battery_saver_outlined,
        DiagnosticAction.openAndroidNotificationSettings =>
          Icons.notifications_outlined,
        DiagnosticAction.requestBluetoothPermissions => Icons.bluetooth,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connection Doctor'),
        actions: [
          IconButton(
            tooltip: 'Run checks again',
            onPressed: _retry,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Copy sanitized diagnostics',
            onPressed: () async {
              final export = await ConnectionDoctor(context.read<AppState>())
                  .exportSanitized(peerId: widget.peerId);
              await Clipboard.setData(ClipboardData(text: export));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Sanitized diagnostics copied.'),
                  ),
                );
              }
            },
            icon: const Icon(Icons.copy_all_outlined),
          ),
        ],
      ),
      body: FutureBuilder<List<DiagnosticCheck>>(
        future: _checks,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _DoctorFailure(error: snapshot.error, onRetry: _retry);
          }
          final checks = snapshot.data ?? const [];
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: checks.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final check = checks[index];
              final (icon, color) = switch (check.status) {
                DiagnosticStatus.ok => (
                    Icons.check_circle_outline,
                    Colors.green
                  ),
                DiagnosticStatus.warning => (
                    Icons.warning_amber_rounded,
                    Colors.orange
                  ),
                DiagnosticStatus.error => (Icons.error_outline, Colors.red),
                DiagnosticStatus.pending => (Icons.hourglass_top, Colors.blue),
              };
              return Card(
                child: ListTile(
                  minVerticalPadding: 14,
                  leading: Icon(icon,
                      color: color, semanticLabel: check.status.name),
                  title: Text(check.title),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 4),
                      Text(check.explanation),
                      if (check.remediationAction case final action?) ...[
                        const SizedBox(height: 6),
                        Text(
                          action,
                          style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      if (check.actions.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final action in check.actions)
                              OutlinedButton.icon(
                                onPressed: () => _runAction(action),
                                icon: Icon(_actionIcon(action), size: 18),
                                label: Text(_actionLabel(action)),
                              ),
                          ],
                        ),
                      ],
                      if (check.technicalDetails case final details?) ...[
                        const SizedBox(height: 6),
                        SelectableText(
                          details,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _DoctorFailure extends StatelessWidget {
  const _DoctorFailure({required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 12),
              Text('Diagnostics failed: $error', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
}
