import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../app_state.dart';
import '../desktop/tray.dart';
import 'send_flow_view.dart';

/// Roadmap Phase 4: the compact, KDE-Connect-style popup a Windows
/// "Send to Conduit" (or share-sheet delivery) opens instead of the full
/// dashboard.
///
/// Conduit has exactly one native window — there's no `desktop_multi_window`
/// dependency here, deliberately: adding a second native windowing plugin
/// isn't something to pin and wire up without being able to verify the
/// Windows build compiles. So "popup" means temporarily reshaping *that one*
/// window: small, centered, briefly pinned on top so it doesn't get lost
/// behind whatever the user was doing, then restored to its normal
/// size/position the moment the send finishes or the user dismisses it.
///
/// [DashboardScreen] swaps to this screen — instead of the normal
/// NavigationRail/BottomNav shell — for as long as [AppState.sendWidgetMode]
/// is true, and swaps back automatically once [_close] flips that off. Since
/// DashboardScreen's own State is never torn down (see its doc comment),
/// the full shell reappears exactly on whichever tab the user had open
/// before, with no extra bookkeeping needed here for "where were they".
class SendWidgetScreen extends StatefulWidget {
  const SendWidgetScreen({super.key});

  @override
  State<SendWidgetScreen> createState() => _SendWidgetScreenState();
}

class _SendWidgetScreenState extends State<SendWidgetScreen> {
  static const _popupWidth = 400.0;
  static const _popupHeight = 560.0;

  bool _closing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _enterWidgetGeometry());
  }

  Future<void> _enterWidgetGeometry() async {
    try {
      await windowManager.ensureInitialized();
      // Set BEFORE resizing: the resize below is exactly the kind of
      // programmatic move _CloseHandler (desktop/tray.dart) must not mistake
      // for the user dragging/resizing their normal window.
      suppressWindowBoundsPersistence = true;
      await windowManager.setBounds(
        null,
        size: const Size(_popupWidth, _popupHeight),
        animate: true,
      );
      await windowManager.center();
      // A small utility popup that loses itself behind other windows would
      // defeat the point of a quick "send this file" action.
      await windowManager.setAlwaysOnTop(true);
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {
      // Best-effort — if window_manager can't do this for some reason, the
      // send flow below still works fine at whatever size the window
      // already is; it just won't have popped into the compact shape.
    }
  }

  /// Restores the window and hands control back to the full dashboard.
  /// Threaded through both the header's close button and
  /// [SendFlowView.onRequestClose] (the auto-close-on-success path), so
  /// there is exactly one place that can leave the window mid-transition.
  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    suppressWindowBoundsPersistence = false;
    try {
      // Fire-and-forget: do not await these native calls so that any window manager
      // stall or deadlock does not hang the Dart thread or prevent closing the widget.
      unawaited(windowManager.setAlwaysOnTop(false).catchError((_) {}));
      unawaited(DesktopTray.restoreNormalBounds().catchError((_) {}));
    } catch (_) {}
    if (mounted) {
      context.read<AppState>().exitSendWidgetMode();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        toolbarHeight: 46,
        title: Text('Send to device', style: theme.textTheme.titleSmall),
        actions: [
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => _close(),
          ),
        ],
      ),
      body: SendFlowView(compact: true, onRequestClose: () => _close()),
    );
  }
}
