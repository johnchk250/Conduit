import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/src/core/config_store.dart';

void main() {
  test('ConfigStore.forTest accepts folder pair config', () async {
    final tmp = await Directory.systemTemp.createTemp('conduit_config_test_');
    try {
      final cfg = ConfigStore.forTest(File('${tmp.path}/config.json'), {
        'folderPairs': [
          {
            'id': 'pair-1',
            'name': 'Docs',
            'localPath': r'C:\Docs',
            'direction': 'twoWay',
          },
        ],
      });
      expect(cfg.folderPairs, hasLength(1));
      expect(cfg.folderPairs.first.id, 'pair-1');
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('peer endpoint history keeps and promotes reconnect routes', () async {
    final tmp = await Directory.systemTemp.createTemp('conduit_routes_test_');
    try {
      final cfg = ConfigStore.forTest(File('${tmp.path}/config.json'), {
        'peerEndpoints': {
          'peer-1': {
            'address': '192.168.1.20',
            'port': 41828,
            'updatedAt': '2026-01-01T00:00:00.000Z',
          },
        },
      });

      expect(cfg.peerEndpointCandidates('peer-1'), hasLength(1));
      await cfg.rememberPeerEndpoint(
        deviceId: 'peer-1',
        address: '192.168.1.21',
        port: 41828,
        );
      await cfg.rememberPeerEndpoint(
        deviceId: 'peer-1',
        address: '192.168.1.20',
        port: 41828,
        );

      final routes = cfg.peerEndpointCandidates('peer-1');
      expect(routes, hasLength(2));
      expect(routes.first['address'], '192.168.1.20');
      expect(routes.last['address'], '192.168.1.21');
      expect(routes.first['lastSuccessfulAt'], isA<String>());
      expect(routes.last['lastSuccessfulAt'], isA<String>());
    } finally {
      await tmp.delete(recursive: true);
    }
  });
}
