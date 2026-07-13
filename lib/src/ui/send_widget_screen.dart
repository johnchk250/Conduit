import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../app_state.dart';
import '../desktop/tray.dart';
import 'glass.dart';
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

  // Bug fix: claimed synchronously in initState (see tray.dart's
  // sendWidgetEpoch doc comment) so this session can tell whether it's still
  // the current one before applying each step of its open/close geometry
  // sequence — guards against racing a previous session's still-in-flight
  // close, or a newer session that supersedes this one mid-open.
  late final int _epoch;

  @override
  void initState() {
    super.initState();
    _epoch = beginSendWidgetEpoch();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _enterWidgetGeometry());
  }

  Future<void> _enterWidgetGeometry() async {
    try {
      await windowManager.ensureInitialized();
      if (!isCurrentSendWidgetEpoch(_epoch)) return;
      // Set BEFORE resizing: the resize below is exactly the kind of
      // programmatic move _CloseHandler (desktop/tray.dart) must not mistake
      // for the user dragging/resizing their normal window.
      suppressWindowBoundsPersistence = true;
      await windowManager.setBounds(
        null,
        size: const Size(_popupWidth, _popupHeight),
        animate: true,
      );
      if (!isCurrentSendWidgetEpoch(_epoch)) return;
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
    // Only touch the shared suppression flag / fire the restore if no newer
    // send-widget session has already taken over the window (see
    // tray.dart's sendWidgetEpoch doc comment) — otherwise this stale close
    // would stomp the new session's compact geometry/always-on-top state
    // right after it was set, which is exactly what made the send widget
    // intermittently seem to "not open" when a new send arrived while a
    // previous one was still closing.
    if (isCurrentSendWidgetEpoch(_epoch)) {
      suppressWindowBoundsPersistence = false;
      try {
        // Fire-and-forget: do not await these native calls so that any window
        // manager stall or deadlock does not hang the Dart thread or prevent
        // closing the widget. Each step re-checks the epoch first/last since
        // a newer session can start at any point during these awaits.
        unawaited(() async {
          if (!isCurrentSendWidgetEpoch(_epoch)) return;
          await windowManager.setAlwaysOnTop(false).catchError((_) {});
          if (!isCurrentSendWidgetEpoch(_epoch)) return;
          await DesktopTray.restoreNormalBounds().catchError((_) {});
        }());
      } catch (_) {}
    }
    if (mounted) {
      context.read<AppState>().exitSendWidgetMode();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = GlassColors.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        toolbarHeight: 46,
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          'Send to device',
          style: GoogleFonts.manrope(
            textStyle: TextStyle(
              color: c.textPrimary,
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close_rounded),
            color: c.textPrimary,
            onPressed: () => _close(),
          ),
        ],
      ),
      body: SendFlowView(compact: true, onRequestClose: () => _close()),
    );
  }
}
