import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:conduit/src/sync/cdc.dart';

void main() {
  group('FastCdc', () {
    test('chunk empty buffer returns empty list', () {
      const cdc = FastCdc();
      final chunks = cdc.chunk(Uint8List(0));
      expect(chunks, isEmpty);
    });

    test('chunk small buffer returns single chunk with full coverage', () {
      const cdc = FastCdc();
      final data = Uint8List.fromList(List.generate(1000, (i) => i % 256));
      final chunks = cdc.chunk(data);
      expect(chunks.length, 1);
      expect(chunks.first.offset, 0);
      expect(chunks.first.length, 1000);
      expect(chunks.first.end, 1000);
      expect(chunks.first.sha256, isNotEmpty);
    });

    test('chunk large buffer ensures 100% contiguous coverage without gaps',
        () {
      const cdc = FastCdc(
        minSize: 4 * 1024,
        avgSize: 16 * 1024,
        maxSize: 64 * 1024,
      );
      final rng = Random(42);
      final data = Uint8List(256 * 1024);
      for (var i = 0; i < data.length; i++) {
        data[i] = rng.nextInt(256);
      }

      final chunks = cdc.chunk(data);
      expect(chunks, isNotEmpty);

      var covered = 0;
      for (final chunk in chunks) {
        expect(chunk.offset, covered);
        covered += chunk.length;
      }
      expect(covered, data.length);
    });

    test(
        'one byte insertion at beginning preserves subsequent downstream chunks',
        () {
      const cdc = FastCdc(
        minSize: 4 * 1024,
        avgSize: 16 * 1024,
        maxSize: 64 * 1024,
      );
      final rng = Random(12345);
      final original = Uint8List(512 * 1024);
      for (var i = 0; i < original.length; i++) {
        original[i] = rng.nextInt(256);
      }

      final originalChunks = cdc.chunk(original);
      expect(originalChunks.length, greaterThan(2));

      // Insert 1 byte at offset 0
      final modified = Uint8List(original.length + 1);
      modified[0] = 0xFF;
      modified.setRange(1, modified.length, original);

      final modifiedChunks = cdc.chunk(modified);

      // Verify that after boundary resynchronization, downstream chunk hashes match
      final originalHashes = originalChunks.map((c) => c.sha256).toSet();
      final modifiedHashes = modifiedChunks.map((c) => c.sha256).toSet();
      final common = originalHashes.intersection(modifiedHashes);

      expect(common.length, greaterThan(0),
          reason:
              'CDC should resynchronize and reuse downstream chunks despite byte shift at offset 0');
    });

    test('ChunkDescriptor serialization round-trip', () {
      const desc = ChunkDescriptor(
        offset: 1024,
        length: 2048,
        sha256: 'deadbeef1234',
      );
      final json = desc.toJson();
      final restored = ChunkDescriptor.fromJson(json);
      expect(restored, desc);
      expect(restored.offset, 1024);
      expect(restored.length, 2048);
      expect(restored.sha256, 'deadbeef1234');
    });
  });
}
