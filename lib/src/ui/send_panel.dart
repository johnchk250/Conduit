import 'package:flutter/material.dart';

import 'send_flow_view.dart';

/// Full-shell "Send" tab — the desktop NavigationRail / mobile bottom-nav
/// destination for the ad-hoc file-send flow (Roadmap Phase 3d).
///
/// This used to hold the entire flow; it now just supplies the AppBar chrome
/// around [SendFlowView], which is where all the actual logic (file
/// queueing, peer selection, send progress) and the redesigned UI live. That
/// split is what let Roadmap Phase 4's compact `SendWidgetScreen` popup
/// reuse the exact same flow instead of re-implementing it at a smaller
/// size.
class SendPanel extends StatelessWidget {
  const SendPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Send File'), elevation: 0),
      body: const SafeArea(child: SendFlowView(compact: false)),
    );
  }
}
