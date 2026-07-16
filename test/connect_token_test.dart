import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/src/net/discovery.dart';

void main() {
  test('Bluetooth-only connect token is accepted without a LAN address', () {
    final decoded = Discovery.decodeConnectTokenFull(jsonEncode({
      'v': 1,
      'type': 'conduit-connect',
      'deviceId': 'phone-id',
      'name': 'Phone',
      'platform': 'android',
      'pubKey': 'public-key',
      'host': '',
      'hosts': <String>[],
      'port': 0,
      'bluetooth': true,
      'pairCode': '123456',
    }));

    expect(decoded, isNotNull);
    expect(decoded!.hosts, isEmpty);
    expect(decoded.bluetoothAvailable, isTrue);
    expect(decoded.pairCode, '123456');
  });

  test('connect token without any advertised transport is rejected', () {
    final decoded = Discovery.decodeConnectTokenFull(jsonEncode({
      'v': 1,
      'type': 'conduit-connect',
      'deviceId': 'phone-id',
      'name': 'Phone',
      'platform': 'android',
      'pubKey': 'public-key',
      'host': '',
      'hosts': <String>[],
      'port': 0,
    }));

    expect(decoded, isNull);
  });
}
