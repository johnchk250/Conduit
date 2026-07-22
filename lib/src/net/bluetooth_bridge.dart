import 'dart:io';

import 'package:flutter/services.dart';

import 'transport.dart';

class BluetoothDeviceEndpoint {
  const BluetoothDeviceEndpoint({required this.id, required this.name});

  final String id;
  final String name;
}

class IncomingTransport {
  const IncomingTransport(this.transport, {this.endpointId});

  final ConnectionTransport transport;
  final String? endpointId;
}

/// Native Bluetooth Classic RFCOMM adapter.
///
/// Native code exposes each RFCOMM connection as a loopback TCP socket. This
/// keeps Conduit's authenticated framing and handshake shared between LAN and
/// Bluetooth. Loopback bytes never leave the device.
class BluetoothBridge {
  BluetoothBridge({required this.onDevice, required this.onStatus});

  static const _channel = MethodChannel('conduit/bluetooth');

  final void Function(BluetoothDeviceEndpoint endpoint) onDevice;
  final void Function(String status) onStatus;
  final Map<int, String> _incomingEndpoints = <int, String>{};

  bool _started = false;
  bool get isStarted => _started;
  bool get isSupported => Platform.isAndroid || Platform.isWindows;

  Future<void> start({required int dartListenPort}) async {
    if (!isSupported || _started) return;
    _channel.setMethodCallHandler(_handleNativeCall);
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('start', {
        'dartPort': dartListenPort,
      });
      _started = result?['started'] == true;
      onStatus((result?['status'] as String?) ??
          (_started ? 'Bluetooth ready' : 'Bluetooth unavailable'));
    } on MissingPluginException {
      onStatus('Bluetooth is unavailable in this build');
    } on PlatformException catch (e) {
      onStatus(e.message ?? 'Bluetooth could not start');
    }
  }

  Future<void> requestPermissions() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('requestPermissions');
    }
  }

  Future<void> stop() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
    _started = false;
    _incomingEndpoints.clear();
    onStatus('Bluetooth disabled');
  }

  /// Run one explicit nearby-device refresh without restarting the RFCOMM
  /// listener or any active bridge.
  Future<void> refreshDiscovery() async {
    if (!isSupported || !_started || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('refreshDiscovery');
    } catch (_) {}
  }

  Future<int> connect(String endpointId) async {
    final port = await _channel.invokeMethod<int>(
      'connect',
      {'endpointId': endpointId},
    );
    if (port == null || port <= 0) {
      throw const SocketException('Bluetooth proxy did not return a port');
    }
    return port;
  }

  IncomingTransport resolveIncoming(int remotePort) {
    final endpoint = _incomingEndpoints.remove(remotePort);
    if (endpoint == null) {
      return const IncomingTransport(ConnectionTransport.lan);
    }
    return IncomingTransport(
      ConnectionTransport.bluetooth,
      endpointId: endpoint,
    );
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    final args = call.arguments;
    final map = args is Map ? Map<dynamic, dynamic>.from(args) : const {};
    switch (call.method) {
      case 'deviceFound':
        final id = map['id']?.toString();
        if (id != null && id.isNotEmpty) {
          onDevice(BluetoothDeviceEndpoint(
            id: id,
            name: map['name']?.toString() ?? 'Bluetooth device',
          ));
        }
        break;
      case 'incomingProxy':
        final sourcePort = (map['sourcePort'] as num?)?.toInt();
        final id = map['id']?.toString();
        if (sourcePort != null && id != null) {
          _incomingEndpoints[sourcePort] = id;
        }
        break;
      case 'status':
        onStatus(map['message']?.toString() ?? 'Bluetooth status changed');
        break;
    }
  }
}
