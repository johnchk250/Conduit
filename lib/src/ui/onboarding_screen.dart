import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../controllers/app_controllers.dart';
import 'folder_setup/folder_setup_flow.dart';
import 'folder_pairs_screen.dart';
import 'pairing_screen.dart';
import 'send_panel.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, this.reopened = false});

  final bool reopened;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  static const _pageCount = 5;

  Future<void> _finish() async {
    await context.read<AppLifecycleController>().completeOnboarding();
    if (widget.reopened && mounted) Navigator.of(context).pop();
  }

  void _next() {
    if (_page == _pageCount - 1) {
      _finish();
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Set up Conduit'),
        actions: [
          TextButton(
            onPressed: _finish,
            child: Text(widget.reopened ? 'Done' : 'Skip'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            LinearProgressIndicator(value: (_page + 1) / _pageCount),
            Expanded(
              child: PageView(
                controller: _controller,
                onPageChanged: (value) => setState(() => _page = value),
                children: [
                  const _OnboardingPage(
                    icon: Icons.sync_lock,
                    title: 'Your files, directly between your devices',
                    body:
                        'Conduit is local-first. Paired devices verify pinned identities and all sessions use authenticated encryption. There is no plaintext fallback.',
                  ),
                  _OnboardingPage(
                    icon: Icons.fact_check_outlined,
                    title: 'Device readiness',
                    body: Platform.isAndroid
                        ? 'Conduit explains permissions before requesting them. For reliable background sync, allow notifications, choose folders through Android’s folder picker, and consider unrestricted battery use.'
                        : 'Keep Conduit allowed on private networks. Windows firewall rules are always an explicit user action; the Connection Doctor can help identify local blockers.',
                    footer:
                        'This device: ${state.identity.name} (${state.identity.deviceId})',
                  ),
                  const _EmbeddedStep(
                    title: 'Pair a device',
                    explanation:
                        'Use the same secure pairing screen available from Devices. You can continue and pair later.',
                    child: PairingScreen(),
                  ),
                  _FirstUseStep(state: state),
                  _OnboardingPage(
                    icon: Icons.check_circle_outline,
                    title: 'You’re ready',
                    body: state.pairedPeers.isEmpty
                        ? 'Setup is saved. Pair a device from Devices whenever you are ready, then create a folder or send a file.'
                        : 'Your paired devices, transfers, folder status, and Connection Doctor are available from the five main destinations.',
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  if (_page > 0)
                    TextButton(
                      onPressed: () => _controller.previousPage(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOut,
                      ),
                      child: const Text('Back'),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _next,
                    child:
                        Text(_page == _pageCount - 1 ? 'Finish' : 'Continue'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FirstUseStep extends StatelessWidget {
  const _FirstUseStep({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) => _OnboardingPage(
        icon: Icons.rocket_launch_outlined,
        title: 'Choose your first use',
        body:
            'Folder setup always asks for a destination device. Android folders use a persisted system folder grant rather than raw shared-storage paths.',
        footerWidget: Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: state.pairedPeers.isEmpty
                  ? null
                  : () => runFolderSetupFlow(
                        context,
                        onCustom: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const FolderPairsScreen(),
                          ),
                        ),
                      ),
              icon: const Icon(Icons.auto_awesome_outlined),
              label: const Text('Set up a synced folder'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SendPanel()),
              ),
              icon: const Icon(Icons.send_outlined),
              label: const Text('Send a file'),
            ),
          ],
        ),
      );
}

class _EmbeddedStep extends StatelessWidget {
  const _EmbeddedStep({
    required this.title,
    required this.explanation,
    required this.child,
  });

  final String title;
  final String explanation;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Column(
              children: [
                Text(title, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 6),
                Text(explanation, textAlign: TextAlign.center),
              ],
            ),
          ),
          Expanded(child: child),
        ],
      );
}

class _OnboardingPage extends StatelessWidget {
  const _OnboardingPage({
    required this.icon,
    required this.title,
    required this.body,
    this.footer,
    this.footerWidget,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? footer;
  final Widget? footerWidget;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Column(
              children: [
                const SizedBox(height: 24),
                Icon(icon, size: 72, semanticLabel: title),
                const SizedBox(height: 24),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 16),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                if (footer case final text?) ...[
                  const SizedBox(height: 20),
                  SelectableText(text, textAlign: TextAlign.center),
                ],
                if (footerWidget case final widget?) ...[
                  const SizedBox(height: 24),
                  widget,
                ],
              ],
            ),
          ),
        ),
      );
}
