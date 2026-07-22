import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'typography.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../core/config_store.dart';
import 'glass.dart';

/// The ad-hoc "send a file to a paired device" flow (Roadmap Phase 3d),
/// factored out of the old `SendPanel` so it can be shared by two hosts:
///
///   - [SendPanel]: the full-shell "Send" tab (desktop NavigationRail /
///     mobile bottom nav destination). Uses `compact: false`.
///   - `SendWidgetScreen` (Roadmap Phase 4): the small KDE-Connect-style
///     popup a Windows "Send to Conduit" opens instead of the full app.
///     Uses `compact: true`.
///
/// All the actual send logic (file queueing, peer selection/auto-select,
/// the block-pull progress callback) lives here exactly once; [compact] only
/// changes layout — spacing, whether the device row gets a labelled card,
/// and whether finishing a send asks the host to close via
/// [onRequestClose] instead of resetting in place.
class SendFlowView extends StatefulWidget {
  const SendFlowView({
    super.key,
    this.compact = false,
    this.onRequestClose,
    this.hideTitle = false,
    this.initialPeerId,
  });

  /// True for the small send-widget popup; false for the full "Send" tab.
  final bool compact;

  /// Called when a compact-mode send finishes successfully (after a brief
  /// confirmation) or the user taps the compact "Close" button. Ignored in
  /// full mode, which just resets in place instead of trying to close
  /// anything — there's no popup to close.
  final VoidCallback? onRequestClose;

  /// If true, suppresses rendering the default 'Send' page title inside the layout.
  final bool hideTitle;

  final String? initialPeerId;

  @override
  State<SendFlowView> createState() => _SendFlowViewState();
}

enum _SendPhase { idle, sending, done, error }

class _SendFlowViewState extends State<SendFlowView> {
  PairedPeer? _selectedPeer;

  @override
  void initState() {
    super.initState();
    if (widget.initialPeerId != null) {
      final state = context.read<AppState>();
      for (final p in state.config.pairedPeers) {
        if (p.deviceId == widget.initialPeerId) {
          _selectedPeer = p;
          break;
        }
      }
    }
  }

  _SendPhase _phase = _SendPhase.idle;

  // Files loaded from the OS share/send mechanism (Phase 3d). These come in
  // pre-resolved (name + bytes/path/URI) from AppState._onIncomingSharedFiles.
  List<PendingSharedFile>? _sharedFiles;
  // Files manually picked inside the app (original flow).
  List<_PickedFile>? _pickedFiles;
  bool _autoStartSharedFiles = false;
  bool _autoStartScheduled = false;

  // Drag-and-drop state — true while the user is hovering dragged items over
  // this widget's drop target area.
  bool _isDragging = false;

  // Which paired-but-offline device (if any) is currently being reconnected
  // via a chip tap, so that one chip alone shows a spinner.
  String? _reconnectingPeerId;

  // ── Current-transfer progress (drives the sending-state ring/labels) ────
  String? _currentFileName;
  double _currentProgress = 0.0;
  int _currentSentBytes = 0;
  int _currentTotalBytes = 0;
  int _currentIndex = 0;
  int _totalInBatch = 0;
  String? _resultMessage;
  String? _activePeerId;
  bool _transferPaused = false;
  bool _cancelRequested = false;

  // Lightweight speed estimate from successive onProgress samples of the
  // *current* file only (reset per-file — different files may hit different
  // effective throughput, and mixing them would just make the number lie).
  DateTime? _speedLastTime;
  int _speedLastBytes = 0;
  double? _speedBytesPerSec; // exponential moving average

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Phase 3d: if the OS dropped files into the app via the share sheet or
    // "Send to" menu, snapshot them here so the very first build already has
    // them.
    //
    // Bug fix: this used to also call state.clearPendingSharedFiles() right
    // here, synchronously. didChangeDependencies runs while this widget is
    // being *mounted*, and for both hosts of SendFlowView that mount happens
    // *inside* an ancestor's own build() — DashboardScreen.build() either
    // returns SendWidgetScreen directly, or switches SendPanel in via
    // setState(() => _index = 3). clearPendingSharedFiles() calls
    // notifyListeners(), and notifying the very ChangeNotifier an ancestor is
    // currently watching, from mid-build, is the classic Flutter
    // "setState()/markNeedsBuild() called during build" hazard — depending on
    // timing that either throws (the send UI fails to render at all) or the
    // resulting rebuild gets dropped (the UI opens but nothing reacts, so the
    // send never starts). That matched the reported "erratic ... doesn't
    // open, or opens but send doesn't start" symptom exactly, and since this
    // is the widget's *first* mount it's the common path, not an edge case.
    //
    // Fix: keep the synchronous local-field snapshot (so the first build()
    // already has the files — no visible delay), but defer the actual
    // AppState mutation to a post-frame callback, once this build/mount pass
    // is over. Same safe pattern already used below in build() for files
    // arriving while the widget is already mounted.
    final state = context.read<AppState>();
    final pending = state.pendingSharedFiles;
    if (pending != null && pending.isNotEmpty) {
      _sharedFiles = pending;
      _pickedFiles = null;
      _autoStartSharedFiles = state.pendingSharedFilesAutoStart;
      _autoStartScheduled = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          state.clearPendingSharedFiles();
        }
      });
    }
  }

  // Returns the currently active file list (shared or manually picked).
  bool get _hasFiles =>
      (_sharedFiles?.isNotEmpty ?? false) ||
      (_pickedFiles?.isNotEmpty ?? false);

  int get _fileCount =>
      (_sharedFiles?.length ?? 0) + (_pickedFiles?.length ?? 0);

  List<String> get _fileNames {
    final out = <String>[];
    if (_sharedFiles != null) out.addAll(_sharedFiles!.map((f) => f.name));
    // Use displayName (short label for folder-expanded files) when available.
    if (_pickedFiles != null) {
      out.addAll(_pickedFiles!.map((f) => f.displayName ?? f.name));
    }
    return out;
  }

  Future<void> _pickAndQueueFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        withData:
            false, // Polish / large-file fix: don't load entire file in memory
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return;

      final picked = <_PickedFile>[];
      for (final f in result.files) {
        if (f.path != null) {
          picked.add(_PickedFile(name: f.name, path: f.path, size: f.size));
        } else if (f.bytes != null) {
          picked.add(_PickedFile(name: f.name, bytes: f.bytes, size: f.size));
        }
      }
      if (picked.isEmpty) return;

      setState(() {
        _sharedFiles = null;
        _pickedFiles = picked;
        _autoStartSharedFiles = false;
        _autoStartScheduled = false;
        _phase = _SendPhase.idle;
        _resultMessage = null;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error reading file: $e')),
        );
      }
    }
  }

  // ── Drag-and-drop ────────────────────────────────────────────────────────

  /// Called when the user drops items (files and/or folders) onto the target.
  /// Folders are expanded recursively; relative paths within each dropped
  /// folder are preserved in the file name so the receiver gets the directory
  /// tree intact (e.g. "MyFolder/sub/photo.jpg").
  Future<void> _onDropItems(DropDoneDetails details) async {
    final picked = <_PickedFile>[];
    var enumerated = 0;

    for (final xfile in details.files) {
      final fsPath = xfile.path;
      final entity = await FileSystemEntity.type(fsPath, followLinks: false);

      if (entity == FileSystemEntityType.directory) {
        // Recursively walk the folder and collect all files, preserving their
        // path relative to the parent directory (not the folder itself, so the
        // folder name is included as the first component).
        final dir = Directory(fsPath);
        final folderName = p.basename(fsPath);
        await for (final sub in dir.list(recursive: true, followLinks: false)) {
          if (sub is File) {
            // Build a relative path from the parent of the dropped folder.
            final rel = p.relative(sub.path, from: p.dirname(fsPath));
            // Normalise Windows back-slashes to forward-slashes for the wire.
            final relNorm = rel.replaceAll(r'\', '/');
            final size = await sub.length();
            picked.add(_PickedFile(
              name: relNorm,
              displayName: '$folderName/…/${p.basename(sub.path)}',
              path: sub.path,
              size: size,
            ));
            enumerated++;
            if (enumerated % 100 == 0) {
              await Future<void>.delayed(Duration.zero);
            }
          }
        }
      } else if (entity == FileSystemEntityType.file) {
        final file = File(fsPath);
        final size = await file.length();
        picked.add(_PickedFile(
          name: p.basename(fsPath),
          path: fsPath,
          size: size,
        ));
      }
      // Symlinks and other entity types are silently skipped.
    }

    if (picked.isEmpty) return;
    if (!mounted) return;

    setState(() {
      _sharedFiles = null;
      _pickedFiles = (_pickedFiles ?? [])..addAll(picked);
      _autoStartSharedFiles = false;
      _autoStartScheduled = false;
      _phase = _SendPhase.idle;
      _resultMessage = null;
      _isDragging = false;
    });
  }

  void _resetSpeedTracking() {
    _speedLastTime = null;
    _speedLastBytes = 0;
    _speedBytesPerSec = null;
  }

  // Called from inside the onProgress callback (already wrapped in setState
  // by the caller) — this just updates the plain tracking fields it reads.
  void _sampleSpeed(int sentBytes) {
    final now = DateTime.now();
    final lastTime = _speedLastTime;
    if (lastTime == null) {
      _speedLastTime = now;
      _speedLastBytes = sentBytes;
      return;
    }
    final dtSeconds = now.difference(lastTime).inMicroseconds / 1000000.0;
    if (dtSeconds < 0.05) return; // samples too close together — noisy
    final deltaBytes = sentBytes - _speedLastBytes;
    _speedLastTime = now;
    _speedLastBytes = sentBytes;
    if (deltaBytes < 0) return;
    final instantaneous = deltaBytes / dtSeconds;
    final prev = _speedBytesPerSec;
    // Smooth so the readout doesn't jump around block-to-block.
    _speedBytesPerSec =
        prev == null ? instantaneous : (prev * 0.7 + instantaneous * 0.3);
  }

  String? get _speedLabel {
    final s = _speedBytesPerSec;
    if (s == null || s <= 0) return null;
    final mbps = s / (1024 * 1024);
    if (mbps >= 1) return '${mbps.toStringAsFixed(1)} MB/s';
    return '${(s / 1024).toStringAsFixed(0)} KB/s';
  }

  String? _etaLabel(int sentBytes, int totalBytes) {
    final s = _speedBytesPerSec;
    if (s == null || s <= 0) return null;
    final remaining = totalBytes - sentBytes;
    if (remaining <= 0) return null;
    final secs = remaining / s;
    if (secs < 1) return 'almost done';
    if (secs < 60) return '${secs.round()}s left';
    return '${(secs / 60).round()}m left';
  }

  String _formatBytesProgress(int sent, int total) {
    String fmt(int bytes) {
      final mb = bytes / (1024 * 1024);
      if (mb >= 1) return '${mb.toStringAsFixed(1)} MB';
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }

    return '${fmt(sent)} / ${fmt(total)}';
  }

  Future<void> _onPeerTapped(
      PairedPeer peer, bool connected, AppState state) async {
    if (connected) {
      setState(() => _selectedPeer = peer);
      return;
    }
    if (_reconnectingPeerId != null) return; // one reconnect at a time
    setState(() => _reconnectingPeerId = peer.deviceId);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await state.reconnectPeer(peer);
      if (mounted) setState(() => _selectedPeer = peer);
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Reconnect failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _reconnectingPeerId = null);
    }
  }

  Future<void> _sendFiles(AppState state) async {
    if (_selectedPeer == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a device first.')),
      );
      return;
    }
    if (!_hasFiles) return;

    final targetPeer = _selectedPeer!;
    final queue = <_QueuedFile>[
      for (final f in (_sharedFiles ?? const <PendingSharedFile>[]))
        _QueuedFile.shared(f),
      for (final f in (_pickedFiles ?? const <_PickedFile>[]))
        _QueuedFile.picked(f),
    ];

    setState(() {
      _phase = _SendPhase.sending;
      _autoStartSharedFiles = false;
      _totalInBatch = queue.length;
      _currentIndex = 0;
      _currentFileName = null;
      _currentProgress = 0.0;
      _currentSentBytes = 0;
      _currentTotalBytes = 0;
      _activePeerId = targetPeer.deviceId;
      _transferPaused = false;
      _cancelRequested = false;
    });

    var sent = 0;
    var failed = 0;

    for (final f in queue) {
      if (!mounted) return;
      _currentIndex++;
      _resetSpeedTracking();
      setState(() {
        _currentFileName = f.name;
        _currentProgress = 0.0;
        _currentSentBytes = 0;
        _currentTotalBytes = f.size;
      });

      final ok = await state.sendAdHocFile(
        peerId: targetPeer.deviceId,
        fileName: f.name,
        fileBytes: f.bytes,
        safUri: f.safUri,
        filePath: f.filePath,
        fileSize: f.size,
        onProgress: (sentBytes, totalBytes) {
          if (!mounted) return;
          _sampleSpeed(sentBytes);
          setState(() {
            _currentProgress = totalBytes > 0 ? sentBytes / totalBytes : 0.0;
            _currentSentBytes = sentBytes;
            _currentTotalBytes = totalBytes;
          });
        },
      );
      if (_cancelRequested) {
        failed++;
        break;
      }
      ok ? sent++ : failed++;
    }

    if (!mounted) return;

    final peerName = targetPeer.name;
    final resultMsg = _cancelRequested
        ? 'Transfer cancelled'
        : failed == 0
            ? 'Sent $sent file${sent == 1 ? '' : 's'} to $peerName'
            : sent == 0
                ? (state.lastTransferBlockReason ??
                    "Couldn't send to $peerName")
                : 'Sent $sent, failed $failed';

    setState(() {
      _phase =
          failed == 0 && !_cancelRequested ? _SendPhase.done : _SendPhase.error;
      _resultMessage = resultMsg;
      _sharedFiles = null;
      _pickedFiles = null;
      _autoStartSharedFiles = false;
      _autoStartScheduled = false;
      _activePeerId = null;
      _transferPaused = false;
    });

    // Compact mode only, and only on a clean sweep: let the confirmation
    // show briefly, then ask the host to close and hand the window back.
    // A partial/total failure stays open so the user can see what happened.
    if (widget.compact && failed == 0) {
      Future.delayed(const Duration(milliseconds: 1400), () {
        if (mounted && _phase == _SendPhase.done) {
          widget.onRequestClose?.call();
        }
      });
    }
  }

  void _pauseActiveTransfer(AppState state) {
    final peerId = _activePeerId;
    if (peerId == null) return;
    if (state.pauseAdHocTransfer(peerId)) {
      setState(() => _transferPaused = true);
    }
  }

  void _resumeActiveTransfer(AppState state) {
    final peerId = _activePeerId;
    if (peerId == null) return;
    if (state.resumeAdHocTransfer(peerId)) {
      setState(() => _transferPaused = false);
    }
  }

  void _cancelActiveTransfer(AppState state) {
    final peerId = _activePeerId;
    if (peerId == null || _cancelRequested) return;
    state.cancelAdHocTransfer(peerId);
    setState(() {
      _cancelRequested = true;
      _transferPaused = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final connectedPeers = state.connectedPeers;

    // Phase 3d: pick up newly-arrived shared files on rebuild (covers files
    // arriving while this widget is already mounted — didChangeDependencies
    // only ever fires once for that). Skipped mid-send so a share that lands
    // while a previous batch is still going can't clobber that batch out
    // from under it; it's picked up on the very next build once we're idle.
    // The `!identical` check skips the list didChangeDependencies already
    // snapshotted this same frame (its AppState clear is merely deferred to
    // a post-frame callback now, not yet applied) — without it this would
    // harmlessly double-schedule a pickup for the exact same data.
    final newPending = state.pendingSharedFiles;
    if (newPending != null &&
        newPending.isNotEmpty &&
        !identical(newPending, _sharedFiles) &&
        _phase != _SendPhase.sending) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _sharedFiles = newPending;
            _pickedFiles = null;
            _phase = _SendPhase.idle;
            _resultMessage = null;
            _autoStartSharedFiles = state.pendingSharedFilesAutoStart;
            _autoStartScheduled = false;
          });
          state.clearPendingSharedFiles();
        }
      });
    }

    // Auto-select the first connected peer if nothing is selected, or if the
    // previously-selected peer disconnected — this is what makes "connected
    // device auto-selected" true the instant the widget opens.
    if (_selectedPeer == null && connectedPeers.isNotEmpty) {
      _selectedPeer = connectedPeers.first;
    } else if (_selectedPeer != null &&
        !connectedPeers.any((p) => p.deviceId == _selectedPeer!.deviceId)) {
      _selectedPeer = connectedPeers.isNotEmpty ? connectedPeers.first : null;
    }

    final c = GlassColors.of(context);
    final fromShare = _sharedFiles != null && _sharedFiles!.isNotEmpty;
    final anyConnected = connectedPeers.isNotEmpty;

    if (fromShare &&
        _autoStartSharedFiles &&
        !_autoStartScheduled &&
        _phase == _SendPhase.idle &&
        _selectedPeer != null &&
        connectedPeers.any((p) => p.deviceId == _selectedPeer!.deviceId)) {
      _autoStartScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _phase == _SendPhase.idle && _hasFiles) {
          _sendFiles(context.read<AppState>());
        }
      });
    }

    return widget.compact
        ? _buildCompactLayout(context, c, state, fromShare, anyConnected)
        : _buildFullLayout(context, c, state, fromShare, anyConnected);
  }

  // ── Layouts ───────────────────────────────────────────────────────────────

  Widget _buildCompactLayout(BuildContext context, GlassColors c,
      AppState state, bool fromShare, bool anyConnected) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (fromShare && _phase == _SendPhase.idle) ...[
            _buildSharedBanner(context, c, compact: true),
            const SizedBox(height: 12),
          ],
          const GlassSectionLabel('SEND TO'),
          const SizedBox(height: 4),
          _buildDeviceRow(context, c, state),
          const SizedBox(height: 16),
          _buildMainContent(context, c, state, anyConnected),
        ],
      ),
    );
  }

  Widget _buildFullLayout(BuildContext context, GlassColors c, AppState state,
      bool fromShare, bool anyConnected) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 32),
          children: [
            if (!widget.hideTitle) const GlassPageTitle('Send'),
            if (fromShare && _phase == _SendPhase.idle) ...[
              _buildSharedBanner(context, c, compact: false),
              const SizedBox(height: 16),
            ],
            const GlassSectionLabel('SEND TO'),
            GlassPanel(
              padding: const EdgeInsets.all(12),
              child: _buildDeviceRow(context, c, state),
            ),
            const SizedBox(height: 20),
            _buildMainContent(context, c, state, anyConnected),
          ],
        ),
      ),
    );
  }

  // ── Device row ────────────────────────────────────────────────────────────

  Widget _buildDeviceRow(BuildContext context, GlassColors c, AppState state) {
    final peers = state.pairedPeers;
    if (peers.isEmpty) {
      return _buildNoPeersEmptyState(context, c);
    }
    final connectedIds = state.connectedPeers.map((p) => p.deviceId).toSet();
    return SizedBox(
      height: 92,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        itemCount: peers.length,
        itemBuilder: (context, i) {
          final peer = peers[i];
          final connected = connectedIds.contains(peer.deviceId);
          return _DeviceChip(
            peer: peer,
            selected: _selectedPeer?.deviceId == peer.deviceId,
            connected: connected,
            reconnecting: _reconnectingPeerId == peer.deviceId,
            onTap: _phase == _SendPhase.sending
                ? null
                : () => _onPeerTapped(peer, connected, state),
          );
        },
      ),
    );
  }

  Widget _buildNoPeersEmptyState(BuildContext context, GlassColors c) {
    return GlassPanel(
      padding: const EdgeInsets.all(14),
      ringColor: c.danger,
      child: Row(
        children: [
          Icon(Icons.link_off_rounded, color: c.danger, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'No paired devices yet. Pair a device first, then come back '
              'here to send.',
              style: AppTypography.inter(
                textStyle: TextStyle(color: c.danger, fontSize: 12.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Shared-files banner (Phase 3d) ──────────────────────────────────────

  Widget _buildSharedBanner(BuildContext context, GlassColors c,
      {required bool compact}) {
    return GlassPanel(
      ringColor: c.violet,
      padding: EdgeInsets.symmetric(
          horizontal: compact ? 14 : 20, vertical: compact ? 10 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.share_rounded,
                  size: compact ? 16 : 20, color: c.violet),
              const SizedBox(width: 8),
              Text(
                'Ready to send',
                style: AppTypography.manrope(
                  textStyle: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: c.violet,
                    fontSize: compact ? 14 : 16,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 8 : 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final f in (_sharedFiles ?? const <PendingSharedFile>[]))
                GlassChip(
                  label: f.name,
                  icon: Icons.insert_drive_file_rounded,
                  accentColor: c.textSecondary,
                  onTap: () => setState(() {
                    _sharedFiles = List.of(_sharedFiles!)..remove(f);
                  }),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Main content states ──────────────────────────────────────────────────

  Widget _buildMainContent(
      BuildContext context, GlassColors c, AppState state, bool anyConnected) {
    switch (_phase) {
      case _SendPhase.sending:
        return _buildSendingState(context, c);
      case _SendPhase.done:
      case _SendPhase.error:
        return _buildResultState(context, c);
      case _SendPhase.idle:
        return _hasFiles
            ? _buildReadyState(context, c, state, anyConnected)
            : _buildPickState(context, c, anyConnected);
    }
  }

  Widget _buildPickState(
      BuildContext context, GlassColors c, bool anyConnected) {
    final accent =
        _isDragging ? c.violet : (anyConnected ? c.violet : c.textTertiary);
    return DropTarget(
      onDragEntered: (_) => setState(() => _isDragging = true),
      onDragExited: (_) => setState(() => _isDragging = false),
      onDragDone: anyConnected ? _onDropItems : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: _isDragging
                ? c.violet.withValues(alpha: 0.8)
                : Colors.transparent,
            width: 2,
          ),
          color: _isDragging
              ? c.violet.withValues(alpha: 0.07)
              : Colors.transparent,
        ),
        child: InkWell(
          onTap: anyConnected ? _pickAndQueueFiles : null,
          borderRadius: BorderRadius.circular(18),
          child: GlassPanel(
            padding: EdgeInsets.all(widget.compact ? 20 : 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: widget.compact ? 60 : 92,
                  height: widget.compact ? 60 : 92,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        accent.withValues(alpha: _isDragging ? 0.35 : 0.2),
                        accent.withValues(alpha: 0.05),
                      ],
                    ),
                    border: Border.all(
                        color:
                            accent.withValues(alpha: _isDragging ? 0.7 : 0.3)),
                  ),
                  child: Icon(
                    _isDragging
                        ? Icons.move_to_inbox_rounded
                        : Icons.upload_file_rounded,
                    size: widget.compact ? 28 : 44,
                    color: accent,
                  ),
                ),
                SizedBox(height: widget.compact ? 14 : 24),
                Text(
                  _isDragging ? 'Drop to add files' : 'Click to choose files',
                  style: AppTypography.manrope(
                    textStyle: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: anyConnected ? c.textPrimary : c.textTertiary,
                      fontSize: widget.compact ? 15 : 17,
                    ),
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text(
                  anyConnected
                      ? 'Drag files or folders here — or share from any app.'
                      : 'Connect a device first, then pick a file to send.',
                  style: AppTypography.inter(
                    textStyle:
                        TextStyle(color: c.textSecondary, fontSize: 12.5),
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReadyState(
      BuildContext context, GlassColors c, AppState state, bool anyConnected) {
    final names = _fileNames;
    return DropTarget(
      onDragEntered: (_) => setState(() => _isDragging = true),
      onDragExited: (_) => setState(() => _isDragging = false),
      onDragDone: anyConnected ? _onDropItems : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: _isDragging
                ? c.violet.withValues(alpha: 0.8)
                : Colors.transparent,
            width: 2,
          ),
          color: _isDragging
              ? c.violet.withValues(alpha: 0.07)
              : Colors.transparent,
        ),
        child: GlassPanel(
          padding: EdgeInsets.all(widget.compact ? 16 : 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: widget.compact ? 64 : 80,
                height: widget.compact ? 64 : 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      c.violet.withValues(alpha: _isDragging ? 0.35 : 0.2),
                      c.violet.withValues(alpha: 0.05),
                    ],
                  ),
                  border: Border.all(
                      color:
                          c.violet.withValues(alpha: _isDragging ? 0.7 : 0.3)),
                ),
                child: Icon(
                  _isDragging
                      ? Icons.move_to_inbox_rounded
                      : Icons.insert_drive_file_rounded,
                  size: widget.compact ? 30 : 40,
                  color: c.violet,
                ),
              ),
              SizedBox(height: widget.compact ? 12 : 20),
              Text(
                _isDragging
                    ? 'Drop to add more'
                    : '$_fileCount file${_fileCount == 1 ? '' : 's'} ready',
                style: AppTypography.manrope(
                  textStyle: TextStyle(
                    color: c.textPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 16.5,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _isDragging
                    ? 'Files & folders will be added to the queue'
                    : names.take(4).join(', ') +
                        (names.length > 4 ? ', +${names.length - 4} more' : ''),
                style: AppTypography.inter(
                  textStyle: TextStyle(color: c.textSecondary, fontSize: 12.5),
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              SizedBox(height: widget.compact ? 16 : 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GlassButton(
                    icon: Icons.add_rounded,
                    label: 'Add',
                    accentColor: c.violet,
                    style: GlassButtonStyle.outline,
                    enabled: anyConnected,
                    onTap: _pickAndQueueFiles,
                    compact: true,
                  ),
                  const SizedBox(width: 10),
                  GlassButton(
                    icon: Icons.send_rounded,
                    label: _selectedPeer != null
                        ? 'Send to ${_selectedPeer!.name}'
                        : 'Send',
                    accentColor: c.violet,
                    style: GlassButtonStyle.primary,
                    enabled: anyConnected && _selectedPeer != null,
                    onTap: () => _sendFiles(state),
                    compact: true,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSendingState(BuildContext context, GlassColors c) {
    final speed = _speedLabel;
    final eta = _etaLabel(_currentSentBytes, _currentTotalBytes);
    return GlassPanel(
      padding: EdgeInsets.all(widget.compact ? 20 : 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _TransferRing(progress: _currentProgress, color: c.violet),
          SizedBox(height: widget.compact ? 14 : 22),
          Text(
            _currentFileName ?? 'Sending…',
            style: AppTypography.manrope(
              textStyle: TextStyle(
                color: c.textPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 14.5,
              ),
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (_totalInBatch > 1) ...[
            const SizedBox(height: 2),
            Text(
              'File $_currentIndex of $_totalInBatch',
              style: TextStyle(color: c.textSecondary, fontSize: 12),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            children: [
              Text(
                _formatBytesProgress(_currentSentBytes, _currentTotalBytes),
                style: TextStyle(color: c.textSecondary, fontSize: 12),
              ),
              if (speed != null)
                Text(speed,
                    style: TextStyle(color: c.textSecondary, fontSize: 12)),
              if (eta != null && !_transferPaused && !_cancelRequested)
                Text(eta,
                    style: TextStyle(color: c.textSecondary, fontSize: 12)),
              if (_transferPaused)
                Text('Paused',
                    style: TextStyle(
                      color: c.violet,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    )),
              if (_cancelRequested)
                Text('Cancelling...',
                    style: TextStyle(
                      color: c.danger,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    )),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              GlassButton(
                icon: _transferPaused
                    ? Icons.play_arrow_rounded
                    : Icons.pause_rounded,
                label: _transferPaused ? 'Resume' : 'Pause',
                accentColor: c.violet,
                style: GlassButtonStyle.outline,
                enabled: !_cancelRequested,
                onTap: () {
                  final state = context.read<AppState>();
                  _transferPaused
                      ? _resumeActiveTransfer(state)
                      : _pauseActiveTransfer(state);
                },
                compact: true,
              ),
              const SizedBox(width: 10),
              GlassButton(
                icon: Icons.close_rounded,
                label: 'Cancel',
                accentColor: c.danger,
                style: GlassButtonStyle.outline,
                enabled: !_cancelRequested,
                onTap: () => _cancelActiveTransfer(context.read<AppState>()),
                compact: true,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildResultState(BuildContext context, GlassColors c) {
    final isSuccess = _phase == _SendPhase.done;
    final color = isSuccess ? c.mint : c.danger;
    return GlassPanel(
      padding: EdgeInsets.all(widget.compact ? 20 : 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [
                color.withValues(alpha: 0.22),
                color.withValues(alpha: 0.05),
              ]),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Icon(
              isSuccess ? Icons.check_rounded : Icons.error_outline,
              size: 38,
              color: color,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            _resultMessage ?? (isSuccess ? 'Sent!' : 'Send failed'),
            style: AppTypography.manrope(
              textStyle: TextStyle(
                color: c.textPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!isSuccess) ...[
                GlassButton(
                  icon: Icons.refresh_rounded,
                  label: 'Try again',
                  accentColor: c.violet,
                  style: GlassButtonStyle.outline,
                  onTap: () => setState(() {
                    _phase = _SendPhase.idle;
                    _resultMessage = null;
                  }),
                  compact: true,
                ),
                const SizedBox(width: 12),
              ],
              GlassButton(
                icon: widget.compact ? Icons.close_rounded : Icons.add_rounded,
                label: widget.compact ? 'Close' : 'Send more',
                accentColor: c.violet,
                style: GlassButtonStyle.primary,
                onTap: () {
                  setState(() {
                    _phase = _SendPhase.idle;
                    _resultMessage = null;
                    _sharedFiles = null;
                    _pickedFiles = null;
                  });
                  if (widget.compact) widget.onRequestClose?.call();
                },
                compact: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Normalizes the two file sources (OS share-sheet vs. manual file_picker
/// selection) into one shape so the send loop in [_SendFlowViewState] only
/// has to exist once instead of being duplicated per source.
class _QueuedFile {
  final String name;
  final List<int>? bytes;
  final String? safUri;
  final String? filePath;
  final int size;

  const _QueuedFile._({
    required this.name,
    this.bytes,
    this.safUri,
    this.filePath,
    required this.size,
  });

  factory _QueuedFile.shared(PendingSharedFile f) => _QueuedFile._(
        name: f.name,
        bytes: f.bytes,
        safUri: f.safUri,
        filePath: f.filePath,
        size: f.size,
      );

  factory _QueuedFile.picked(_PickedFile f) => _QueuedFile._(
        name: f.name,
        bytes: f.bytes,
        filePath: f.path,
        size: f.size,
      );
}

// A file loaded by the in-app file picker or drag-and-drop (not from the OS
// share sheet).
//
// [name] is the on-wire / receiver-visible name. For files inside a dragged
// folder this includes the folder-relative path, e.g. "Photos/2024/pic.jpg".
// [displayName] is an optional short label shown in the UI instead of [name]
// when [name] is a long relative path.
class _PickedFile {
  final String name;
  final String? displayName;
  final List<int>? bytes;
  final String? path;
  final int size;

  const _PickedFile({
    required this.name,
    this.displayName,
    this.bytes,
    this.path,
    required this.size,
  });
}

/// One tappable device avatar in the horizontal "send to" row: a platform
/// icon, a small connected/offline dot, and the device name. Tapping a
/// connected device selects it; tapping an offline one reconnects it
/// (folding what used to be a separate row of "Reconnect X" buttons into the
/// same chips used to pick the destination).
class _DeviceChip extends StatelessWidget {
  const _DeviceChip({
    required this.peer,
    required this.selected,
    required this.connected,
    required this.reconnecting,
    required this.onTap,
  });

  final PairedPeer peer;
  final bool selected;
  final bool connected;
  final bool reconnecting;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = GlassColors.of(context);
    final icon = peer.platform == 'windows'
        ? Icons.computer_rounded
        : Icons.phone_android_rounded;

    final Color ringColor = selected ? c.violet : Colors.transparent;
    final Color avatarColor = !connected
        ? c.textTertiary.withValues(alpha: 0.1)
        : selected
            ? c.violet.withValues(alpha: 0.25)
            : c.textTertiary.withValues(alpha: 0.15);
    final Color iconColor = !connected
        ? c.textTertiary
        : selected
            ? c.violet
            : c.textSecondary;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 56,
              height: 56,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: avatarColor,
                      border: Border.all(color: ringColor, width: 2.5),
                    ),
                    child: reconnecting
                        ? Padding(
                            padding: const EdgeInsets.all(16),
                            child: CircularProgressIndicator(
                                strokeWidth: 2.5, color: iconColor),
                          )
                        : Icon(icon, size: 26, color: iconColor),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: connected ? c.mint : c.textTertiary,
                        border: Border.all(color: c.bgMid, width: 2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: 72,
              child: Text(
                peer.name,
                style: AppTypography.manrope(
                  textStyle: TextStyle(
                    fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                    color: connected ? c.textPrimary : c.textTertiary,
                    fontSize: 11,
                  ),
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The circular transfer indicator shown while a file is sending: an
/// animated progress ring (smoothly tweening between progress updates
/// instead of jumping) with an arrow glyph at its center.
class _TransferRing extends StatelessWidget {
  const _TransferRing({required this.progress, required this.color});

  /// 0.0–1.0. Expected to already be in range — the source computation
  /// (`sentBytes / totalBytes`, both from the wire) can't exceed it.
  final double progress;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = GlassColors.of(context);
    return SizedBox(
      width: 108,
      height: 108,
      child: Stack(
        alignment: Alignment.center,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: progress),
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
            builder: (context, value, _) => SizedBox.expand(
              child: CircularProgressIndicator(
                value: value,
                strokeWidth: 7,
                backgroundColor: c.textTertiary.withValues(alpha: 0.15),
                color: color,
              ),
            ),
          ),
          Icon(Icons.arrow_upward_rounded, size: 34, color: color),
        ],
      ),
    );
  }
}
