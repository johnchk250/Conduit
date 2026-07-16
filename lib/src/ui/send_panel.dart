import 'package:flutter/material.dart';
import 'typography.dart';

import 'glass.dart';
import 'send_flow_view.dart';

/// Full-shell "Send" tab — the desktop NavigationRail / mobile bottom-nav
/// destination for the ad-hoc file-send flow (Roadmap Phase 3d).
///
/// Reskinned to match the transparent Scaffold pattern of other tabs.
/// Automatically detects if it was pushed as a sub-route (e.g. from the mobile share flow)
/// and displays a back button if so.
class SendPanel extends StatelessWidget {
  const SendPanel({super.key, this.initialPeerId});
  final String? initialPeerId;

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.canPop(context);
    final c = GlassColors.of(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ---- Pushed title bar with back button -------------------------
            if (canPop)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 16, 20, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new_rounded),
                      color: c.textPrimary,
                      iconSize: 20,
                      onPressed: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Send',
                        style: AppTypography.manrope(
                          textStyle: TextStyle(
                            color: c.textPrimary,
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.5,
                          ),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),

            // ---- Body content ----------------------------------------------
            Expanded(
              child: SendFlowView(
                compact: false,
                hideTitle: canPop,
                initialPeerId: initialPeerId,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
