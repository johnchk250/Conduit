/// Conduit — wire protocol constants shared by both peers.
///
/// Every connection carries length-prefixed JSON envelopes of the shape:
///   { "t": <type>, ...payload }
/// where `t` is one of the [Msg] constants below.

class Msg {
  Msg._();

  // Handshake / pairing
  static const hello =
      'hello'; // {deviceId, name, platform, pubKey, listenPort, pairCode?}
  static const welcome =
      'welcome'; // {deviceId, name, platform, pubKey, listenPort}
  static const pairAccept = 'pair_accept'; // {deviceId} — pairing confirmed

  // Discovery handshake completion
  static const ready = 'ready'; // {deviceId}

  // ---- Folder sync (REDESIGN.md Phase 2) ---------------------------------
  //
  // Syncthing-BEP-shaped exchange. Index/IndexUpdate carry IndexEntry rows
  // (see lib/src/storage/index_db.dart); Request/Response carry block-level
  // data with terminal-error semantics (a single Response{error} drops the
  // file from the receiver's needs-queue — no retry storm, see Phase 3 spec
  // in REDESIGN.md which is implemented here as part of Phase 2's expanded
  // scope).
  //
  // All five carry `folderId` so a peer with multiple pairs can route to the
  // right IndexDb; `pairId` is kept too for diagnostic correlation.
  static const index =
      'index'; // {pairId, folderId, entries:[IndexEntry.json], fromSequence}
  static const indexUpdate =
      'index_update'; // same shape as index; delta past peer watermark
  static const indexRequest =
      'index_req'; // {pairId, fromSequence} — "send me everything past my watermark"
  static const request =
      'request'; // {pairId, folderId, name, offset, size, hash} — fetch one block
  static const response =
      'response'; // {pairId, folderId, name, offset, length, sha256, data<b64>} OR {..., error:<string>}

  // ---- Clipboard sync (Roadmap Phase 2) ----------------------------------
  //
  // Additive, non-sync: a peer pushes its current clipboard text. Deliberately
  // carries NO pairId (clipboard is device-wide, not per-folder) and NO msgId
  // (writing the clipboard is harmless to re-apply, and skipping the msgId
  // bypasses the dedup guard so a late re-delivery never blocks the genuine
  // current copy). Handled in a single appended branch of _handlePeerMessage —
  // it never touches indexDiff / upsertLocal / the needs-queue.
  static const clipboardPush = 'clipboard_push'; // {text<String>}

  // ---- Remote command (Roadmap Phase 4) ------------------------------------
  //
  // Phone → PC only. The phone sends a named command from the fixed allowlist;
  // the PC executes it (if the feature is enabled). Like clipboardPush this
  // carries no pairId (it is device-wide) and no msgId (commands are one-shot;
  // a duplicate delivery at worst triggers the same action twice, which is
  // acceptable). Handled in a single appended branch of _handlePeerMessage —
  // it never touches indexDiff / upsertLocal / the needs-queue.
  //
  // Allowlisted command names (enforced on the PC executor side):
  //   shutdown_10 … shutdown_60  — schedule shutdown in N minutes
  //   shutdown_cancel            — abort a pending timed shutdown
  //   sleep                      — suspend to RAM
  //   hibernate                  — suspend to disk
  //   media_play_pause           — toggle play/pause
  //   media_next                 — next track
  //   media_prev                 — previous track
  //   volume_up                  — raise system volume one step
  //   volume_down                — lower system volume one step
  //   volume_mute                — toggle mute
  static const runCommand = 'run_command'; // {name<String>}

  // ---- Ad-hoc file send (Roadmap Phase 3a) --------------------------------
  //
  // Sender announces a file; the receiver auto-fetches it block-by-block using
  // the same pull-based model as the V2 sync engine. No acceptance handshake —
  // the receiver starts pulling immediately on receipt of fileOffer.
  //
  // The `offerId` (UUID, sender-generated) is the sole correlation key across
  // all three message types. It is deliberately NOT a pairId — ad-hoc transfers
  // are routed through a separate AdHocFileSend handler and NEVER touch the
  // Index DB, indexDiff, or the needs-queue.
  //
  // Flow:
  //   sender → receiver : fileOffer      {offerId, name, size, sha256, blockHashes:[...]}
  //   receiver → sender : fileOfferBlock {offerId, name, offset, size, hash?}  (one per block)
  //   sender → receiver : fileOfferData  {offerId, name, offset, length, sha256, data<b64>}
  //                                  OR  {offerId, name, offset, error:<string>}  (terminal)
  static const fileOffer = 'file_offer'; // sender announces file metadata
  static const fileOfferBlock =
      'file_offer_block'; // receiver requests one block
  static const fileOfferData =
      'file_offer_data'; // sender responds with block (or error)
  static const fileOfferControl =
      'file_offer_control'; // {offerId, action: pause|resume|cancel}

  // Folder-pair contract negotiation. Establishes a SHARED pairId across two
  // devices so index/request messages can be matched. Without this, each device
  // generates its own random UUID and the engine can never route sync traffic.
  //
  // Flow:
  //   initiator → peer:   folderInvite {pairId, name, direction}
  //   peer → initiator:   folderAccept {pairId}            (after user picks local folder)
  // Both sides then persist a FolderPair with the SAME pairId.
  static const folderInvite = 'folder_invite'; // {pairId, name, direction}
  static const folderAccept = 'folder_accept'; // {pairId}

  // Control
  static const ack = 'ack'; // {of}
  static const error = 'error'; // {message}
  static const ping = 'ping';
  static const pong = 'pong';
  static const bye = 'bye';
}

/// Sync direction for a folder pair.
enum SyncDirection {
  twoWay, // mirror both ways
  receiveOnly, // pull from peer, never push local changes
  sendOnly; // push local changes, never pull from peer

  String get label => switch (this) {
        twoWay => 'Two-way',
        receiveOnly => 'Receive only (from peer)',
        sendOnly => 'Send only (to peer)',
      };
}

/// Per-folder-pair config. Identified by [id]; both peers must agree on it.
///
/// The [id] MUST be identical on both devices — it is the join key for every
/// sync message (index, request, response). It is created once (on the device
/// that initiates the folder pair) and replicated to the other device via the
/// [Msg.folderInvite] / [Msg.folderAccept] handshake. NEVER generate it
/// independently on each side.
class FolderPair {
  final String id;
  final String name;
  final String
      localPath; // absolute on Windows; tree-URI on Android (resolved via channel)
  final SyncDirection direction;

  /// Which peer device this pair is synced with. Null for a pair that has
  /// been created locally but not yet accepted by the peer (pending invite).
  final String? peerDeviceId;

  FolderPair({
    required this.id,
    required this.name,
    required this.localPath,
    required this.direction,
    this.peerDeviceId,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'localPath': localPath,
        'direction': direction.name,
        if (peerDeviceId != null) 'peerDeviceId': peerDeviceId,
      };

  factory FolderPair.fromJson(Map<String, dynamic> j) => FolderPair(
        id: j['id'] as String,
        name: j['name'] as String,
        localPath: j['localPath'] as String,
        direction: SyncDirection.values.byName(j['direction'] as String),
        peerDeviceId: j['peerDeviceId'] as String?,
      );

  FolderPair copyWith({
    String? name,
    String? localPath,
    SyncDirection? direction,
    String? peerDeviceId,
  }) =>
      FolderPair(
        id: id,
        name: name ?? this.name,
        localPath: localPath ?? this.localPath,
        direction: direction ?? this.direction,
        peerDeviceId: peerDeviceId ?? this.peerDeviceId,
      );
}
