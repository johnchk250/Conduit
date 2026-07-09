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
}
