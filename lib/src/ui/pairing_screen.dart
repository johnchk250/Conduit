import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_state.dart';
import '../core/config_store.dart';
import '../net/discovery.dart';
import 'glass.dart';

/// Human-friendly explanation for a pairing/socket failure. Detects the
/// common "firewall / device unreachable" case from the exception and returns
/// an actionable message (with the firewall command for the PC), instead of
/// surfacing a raw stack trace.
String _explainPairingError(Object e) {
  final msg = e.toString();
  final isUnreachable = e is SocketException ||
      msg.contains('timed out') ||
      msg.contains('Connection refused') ||
      msg.contains('Connection timed out');
  if (isUnreachable) {
    return 'Could not reach the other device. This is almost always a '
        'firewall. On the PC, run this once (as admin):\n\n'
        'netsh advfirewall firewall add rule name="Conduit" dir=in '
        'action=allow protocol=TCP localport=41828\n\n'
        'Also make sure both devices are on the same Wi-Fi.';
  }
  if (msg.contains('pairing required')) {
    return 'Pairing rejected: wrong or expired code. Generate a fresh code on '
        'the other device and try again.';
  }
  return 'Pairing failed: $e';
}

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  int _segment = 0; // 0 = discovered/paired, 1 = manual connect

  @override
  Widget build(BuildContext ctx) {
    // Shell matches _OverviewPage's pattern — see THINKING.md. The header
    // (title + segmented control) doesn't scroll; each segment's own
    // content below is independently scrollable, same as the TabBarView it
    // replaces.
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const GlassPageTitle('Devices'),
                  _GlassSegmentedControl(
                    segments: const ['On this network', 'Manual connect'],
                    icons: const [Icons.wifi_tethering, Icons.qr_code],
                    selectedIndex: _segment,
                    onChanged: (i) => setState(() => _segment = i),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _segment == 0
                  ? const _DiscoveredList()
                  : const _ManualConnect(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Two-segment glass pill switcher, replacing [TabBar]/[TabBarView] on this
/// screen — no reference example exists for a segmented control (the HTML
/// mockup is single-screen), so this reuses [GlassNavBar]/[GlassNavRail]'s
/// exact active-item recipe (violet gradient fill + white-alpha border)
/// rather than inventing a new accent treatment. See THINKING.md.
class _GlassSegmentedControl extends StatelessWidget {
  const _GlassSegmentedControl({
    required this.segments,
    required this.icons,
    required this.selectedIndex,
    required this.onChanged,
  });

  final List<String> segments;
  final List<IconData> icons;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = GlassColors.of(context);
    return GlassPanel(
      padding: const EdgeInsets.all(4),
      borderRadius: 16,
      child: Row(
        children: [
          for (var i = 0; i < segments.length; i++)
            Expanded(
              child: InkWell(
                onTap: () => onChanged(i),
                borderRadius: BorderRadius.circular(12),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: i == selectedIndex
                        ? LinearGradient(
                            begin: const Alignment(-0.3, -1),
                            end: const Alignment(0.3, 1),
                            colors: [
                              c.violet.withValues(alpha: 0.28),
                              c.violet.withValues(alpha: 0.14),
                            ],
                          )
                        : null,
                    border: i == selectedIndex
                        ? Border.all(color: Colors.white.withValues(alpha: 0.12))
                        : null,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        icons[i],
                        size: 16,
                        color: i == selectedIndex
                            ? Colors.white
                            : c.textTertiary,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          segments[i],
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.manrope(
                            textStyle: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: i == selectedIndex
                                  ? c.textPrimary
                                  : c.textTertiary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DiscoveredList extends StatelessWidget {
  const _DiscoveredList();

  @override
  Widget build(BuildContext ctx) {
    final state = ctx.watch<AppState>();
    final discovered = state.discoveredPeers;
    final paired = state.pairedPeers;
    final unpairedDiscovered = discovered
        .where((d) => !paired.any((p) => p.deviceId == d.deviceId))
        .toList(growable: false);

    final c = GlassColors.of(ctx);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 110),
      children: [
        GlassSectionLabel('Paired devices (${paired.length})'),
        if (paired.isEmpty)
          GlassPanel(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Icon(Icons.devices_other, size: 44, color: c.textTertiary),
                const SizedBox(height: 12),
                Text(
                  'No paired devices yet',
                  style: GoogleFonts.manrope(
                    textStyle: TextStyle(
                      color: c.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 14.5,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Use a QR code or pair with a device discovered on this '
                  'network.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    textStyle: TextStyle(color: c.textSecondary, fontSize: 12),
                  ),
                ),
              ],
            ),
          )
        else
          for (final peer in paired) ...[
            _PairedPeerTile(
              peer: peer,
              connected: state.isPeerConnected(peer.deviceId),
              discovered: discovered.any((d) => d.deviceId == peer.deviceId),
              onReconnect: () => _reconnect(ctx, state, peer),
              onDisconnect: () => _confirmDisconnect(ctx, state, peer),
              onUnpair: () => _confirmUnpair(ctx, state, peer),
            ),
            const SizedBox(height: 10),
          ],
        const SizedBox(height: 22),
        GlassSectionLabel(
          unpairedDiscovered.isEmpty
              ? 'Searching for new devices…'
              : 'New devices on this network (${unpairedDiscovered.length})',
        ),
        if (unpairedDiscovered.isEmpty)
          GlassPanel(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Icon(Icons.wifi_find, size: 44, color: c.textTertiary),
                const SizedBox(height: 12),
                Text(
                  'Looking for devices...',
                  style: GoogleFonts.manrope(
                    textStyle: TextStyle(
                      color: c.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 14.5,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Both devices must be on the same Wi-Fi. If auto-discovery '
                  'is blocked on this network, use the Manual connect tab.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    textStyle: TextStyle(color: c.textSecondary, fontSize: 12),
                  ),
                ),
              ],
            ),
          )
        else
          for (final p in unpairedDiscovered) ...[
            GlassListTile(
              leadingIcon:
                  p.platform == 'android' ? Icons.phone_android : Icons.computer,
              accentColor: c.blue,
              title: p.name,
              subtitle:
                  '${p.platform[0].toUpperCase()}${p.platform.substring(1)} · ${p.address.address}',
              subtitleMono: true,
              trailing: GlassButton(
                icon: Icons.handshake_outlined,
                label: 'Pair',
                accentColor: c.violet,
                style: GlassButtonStyle.primary,
                compact: true,
                onTap: () => _connect(ctx, state, p, false),
              ),
            ),
            const SizedBox(height: 10),
          ],
      ],
    );
  }

  Future<void> _reconnect(
      BuildContext ctx, AppState state, PairedPeer peer) async {
    try {
      await state.reconnectPeer(peer);
    } catch (e) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text(_explainPairingError(e))),
        );
      }
    }
  }

  Future<void> _confirmDisconnect(
      BuildContext ctx, AppState state, PairedPeer peer) async {
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: Text('Disconnect from ${peer.name}?'),
        content: const Text(
            'This stops syncing with that device until you reconnect. Your files and pairing are kept.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('Cancel')),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await state.disconnectPeer(peer.deviceId);
    }
  }

  Future<void> _confirmUnpair(
      BuildContext ctx, AppState state, PairedPeer peer) async {
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: Text('Unpair ${peer.name}?'),
        content: const Text(
            'This removes the saved pairing from this device. Folder pairs and files are not deleted, but you will need to pair again before syncing.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('Unpair'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await state.unpairPeer(peer.deviceId);
    }
  }

  Future<void> _connect(BuildContext ctx, AppState state, DiscoveredPeer peer,
      bool paired) async {
    if (paired) {
      try {
        await state.pairWithPeer(peer, '');
      } catch (e) {
        if (ctx.mounted) {
          ScaffoldMessenger.of(ctx).showSnackBar(
            SnackBar(content: Text(_explainPairingError(e))),
          );
        }
      }
      return;
    }
    final code = await _askPairCode(ctx, peer);
    if (code == null) return;
    try {
      await state.pairWithPeer(peer, code);
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text('Paired with ${peer.name}')),
        );
      }
    } catch (e) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text(_explainPairingError(e))),
        );
      }
    }
  }

  Future<String?> _askPairCode(BuildContext ctx, DiscoveredPeer peer) async {
    final ctl = TextEditingController();
    return showDialog<String>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: Text('Pair with ${peer.name}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'On ${peer.name}, open Conduit -> Devices -> "Pair manually", then enter the 6-digit code shown there.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: ctl,
              keyboardType: TextInputType.number,
              maxLength: 6,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Pairing code',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, null),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, ctl.text.trim()),
            child: const Text('Pair'),
          ),
        ],
      ),
    );
  }
}

class _PairedPeerTile extends StatelessWidget {
  const _PairedPeerTile({
    required this.peer,
    required this.connected,
    required this.discovered,
    required this.onReconnect,
    required this.onDisconnect,
    required this.onUnpair,
  });

  final PairedPeer peer;
  final bool connected;
  final bool discovered;
  final VoidCallback onReconnect;
  final VoidCallback onDisconnect;
  final VoidCallback onUnpair;

  @override
  Widget build(BuildContext context) {
    final c = GlassColors.of(context);
    final platform = peer.platform.isEmpty
        ? 'Device'
        : '${peer.platform[0].toUpperCase()}${peer.platform.substring(1)}';
    final status = connected
        ? 'Connected'
        : discovered
            ? 'Seen on network'
            : 'Offline';
    return GlassListTile(
      leadingIcon:
          peer.platform == 'android' ? Icons.phone_android : Icons.computer,
      accentColor: connected ? c.mint : c.textSecondary,
      title: peer.name,
      subtitle: '$platform · $status',
      subtitleDotColor: connected ? c.mint : c.textTertiary,
      subtitleLive: connected,
      // PopupMenuButton is an overlay/menu surface, same standard-Material
      // carve-out glass.dart's class doc gives dialogs/SnackBars/
      // BottomSheets — only its trigger icon is restyled to blend in.
      trailing: PopupMenuButton<String>(
        icon: Icon(Icons.more_vert, color: c.textTertiary, size: 20),
        onSelected: (value) {
          switch (value) {
            case 'reconnect':
              onReconnect();
              break;
            case 'disconnect':
              onDisconnect();
              break;
            case 'unpair':
              onUnpair();
              break;
          }
        },
        itemBuilder: (context) => [
          if (!connected)
            const PopupMenuItem(
              value: 'reconnect',
              child: ListTile(
                leading: Icon(Icons.link),
                title: Text('Reconnect'),
              ),
            ),
          if (connected)
            const PopupMenuItem(
              value: 'disconnect',
              child: ListTile(
                leading: Icon(Icons.link_off),
                title: Text('Disconnect'),
              ),
            ),
            const PopupMenuItem(
              value: 'unpair',
              child: ListTile(
                leading: Icon(Icons.delete_outline),
                title: Text('Unpair'),
              ),
            ),
          ],
        ),
      );
  }
}

class _ManualConnect extends StatelessWidget {
  const _ManualConnect();

  @override
  Widget build(BuildContext ctx) {
    final state = ctx.watch<AppState>();
    final c = GlassColors.of(ctx);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 110),
      children: [
        Text(
          'Show this QR on the other device',
          textAlign: TextAlign.center,
          style: GoogleFonts.manrope(
            textStyle: TextStyle(
              color: c.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 15.5,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Scan this QR code from the other device to connect automatically.',
          style: GoogleFonts.inter(
            textStyle: TextStyle(color: c.textSecondary, fontSize: 13),
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Center(
          child: FutureBuilder<String>(
            future: state.beginQrPairing(),
            builder: (ctx, snap) {
              if (snap.connectionState != ConnectionState.done ||
                  !snap.hasData) {
                return CircularProgressIndicator(color: c.violet);
              }
              // Kept a real solid-white container (not a glass panel) —
              // a QR code needs real black-on-white contrast to scan
              // reliably, so this is a deliberate exception to the glass
              // surface recipe rather than an oversight.
              return Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: QrImageView(
                  data: snap.data!,
                  version: QrVersions.auto,
                  size: 220,
                  backgroundColor: Colors.white,
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 28),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GlassButton(
              icon: Icons.qr_code_scanner,
              label: 'Scan code on this device',
              accentColor: c.violet,
              style: GlassButtonStyle.primary,
              onTap: () => _scan(ctx, state),
            ),
            const SizedBox(height: 8),
            GlassButton(
              icon: Icons.pin,
              label: 'Pair manually (no camera)',
              accentColor: c.textSecondary,
              style: GlassButtonStyle.outline,
              onTap: () => _generateCode(ctx, state),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _generateCode(BuildContext ctx, AppState state) async {
    // Arm a single-use code on the server side so an incoming first-time
    // hello carrying it will be accepted, and show it to the user to type
    // in on the other device. (Previously this just fabricated a code for
    // display without arming anything — so pairing could never succeed.)
    final code = state.generatePairingCode();
    await showDialog<void>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: const Text('Pairing code'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter this code on the other device within 2 minutes:'),
            const SizedBox(height: 16),
            Text(code,
                style: const TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace')),
          ],
        ),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(dctx), child: const Text('Done')),
        ],
      ),
    );
  }

  Future<void> _scan(BuildContext ctx, AppState state) async {
    final token = await Navigator.of(ctx).push<String>(
      MaterialPageRoute(builder: (sctx) => const _ScanScreen()),
    );
    if (token == null) return;

    // Decode the token and prefer any pairing code embedded in it, so the
    // user doesn't have to type anything. Only fall back to manual entry if
    // the QR is from an older build that doesn't carry a code (back-compat).
    final decoded = Discovery.decodeConnectTokenFull(token);
    if (decoded == null) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(
              content: Text('That QR is not a Conduit connect code.')),
        );
      }
      return;
    }
    if (!ctx.mounted) return;
    final code = decoded.pairCode ?? await _askForCode(ctx);
    if (code == null) return;
    try {
      await state.connectViaToken(token, code);
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text('Paired with ${decoded.peer.name}')),
        );
      }
    } catch (e) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text(_explainPairingError(e))),
        );
      }
    }
  }

  Future<String?> _askForCode(BuildContext ctx) async {
    final ctl = TextEditingController();
    return showDialog<String>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: const Text('Enter pairing code'),
        content: TextField(
          controller: ctl,
          keyboardType: TextInputType.number,
          maxLength: 6,
          autofocus: true,
          decoration: const InputDecoration(labelText: '6-digit code'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, null),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dctx, ctl.text.trim()),
              child: const Text('Connect')),
        ],
      ),
    );
  }
}

/// Dedicated QR-scan route with an explicit, correctly-managed
/// [MobileScannerController].
///
/// The previous version used a bare `MobileScanner(onDetect: ...)` with no
/// controller and called `Navigator.pop()` directly from inside `onDetect`.
/// That has two known failure modes on Android (mobile_scanner 5.x):
///   1. `onDetect` can fire multiple times in quick succession for the same
///      frame batch before the first `pop()` takes effect, re-entering the
///      handler and attempting to pop an already-popping route.
///   2. Popping the route tears down the widget (and its implicit internal
///      controller) while the camera's native surface/texture is still
///      mid-frame. On some devices this leaves the Flutter SurfaceTexture in
///      a stuck/blank state for the route that becomes visible underneath —
///      which is consistent with the "mobile screen goes blank" symptom.
///
/// Fix: own the controller explicitly, stop it (and ignore further
/// detections) the instant a valid code is found, *before* popping, and
/// dispose it deterministically in [dispose].
class _ScanScreen extends StatefulWidget {
  const _ScanScreen();

  @override
  State<_ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<_ScanScreen> {
  late final MobileScannerController _controller;
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled) {
      return; // ignore re-entrant detections from the same/next frame
    }
    String? token;
    for (final barcode in capture.barcodes) {
      if (barcode.rawValue != null) {
        token = barcode.rawValue;
        break;
      }
    }
    if (token == null) return;
    _handled = true;
    // Stop the camera and let the native side settle for a frame *before*
    // popping, instead of popping mid-callback.
    try {
      await _controller.stop();
    } catch (_) {
      // Best-effort — still proceed to pop even if stop() itself failed.
    }
    if (!mounted) return;
    Navigator.of(context).pop(token);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR')),
      body: MobileScanner(controller: _controller, onDetect: _onDetect),
    );
  }
}
