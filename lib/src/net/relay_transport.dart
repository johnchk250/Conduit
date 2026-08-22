import 'dart:async';
import 'dart:typed_data';

/// Pluggable Relay Transport interface (SAFE_DURABLE_IMPROVEMENT_PLAN §D4).
///
/// Provides an extensible interface for future end-to-end encrypted relay or
/// rendezvous transport connections without altering existing local socket
/// and Bluetooth transport invariants.
abstract class RelayTransportClient {
  /// Whether the relay client is connected to the rendezvous/relay endpoint.
  bool get isConnected;

  /// Current relay transport status for diagnostics.
  String get status;

  /// Send an encrypted frame to a target [peerDeviceId] over the relay.
  Future<void> sendFrame(String peerDeviceId, Uint8List encryptedFrame);

  /// Stream of incoming encrypted frames received from remote peers via the relay.
  Stream<RelayIncomingFrame> get incomingFrames;

  /// Connect to the specified relay [serverEndpoint].
  Future<void> connect(String serverEndpoint);

  /// Disconnect and release relay transport resources.
  Future<void> disconnect();
}

/// An incoming encrypted frame delivered via relay transport.
class RelayIncomingFrame {
  const RelayIncomingFrame({
    required this.senderDeviceId,
    required this.payload,
    required this.receivedAt,
  });

  final String senderDeviceId;
  final Uint8List payload;
  final DateTime receivedAt;
}
