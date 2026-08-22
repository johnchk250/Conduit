import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';

/// Descriptor for a content-defined or variable-sized chunk (SAFE_DURABLE_IMPROVEMENT_PLAN §D2).
///
/// Encapsulates chunk boundaries and payload hash without altering existing
/// fixed 1 MiB block transfer structures.
class ChunkDescriptor {
  const ChunkDescriptor({
    required this.offset,
    required this.length,
    required this.sha256,
  });

  final int offset;
  final int length;
  final String sha256;

  int get end => offset + length;

  Map<String, dynamic> toJson() => {
        'offset': offset,
        'length': length,
        'sha256': sha256,
      };

  factory ChunkDescriptor.fromJson(Map<String, dynamic> json) {
    return ChunkDescriptor(
      offset: json['offset'] as int,
      length: json['length'] as int,
      sha256: json['sha256'] as String,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChunkDescriptor &&
          runtimeType == other.runtimeType &&
          offset == other.offset &&
          length == other.length &&
          sha256 == other.sha256;

  @override
  int get hashCode => Object.hash(offset, length, sha256);

  @override
  String toString() => 'ChunkDescriptor($offset..+$length, sha: $sha256)';
}

/// Content-Defined Chunking (FastCDC with Gear Hashing).
class FastCdc {
  const FastCdc({
    this.minSize = 256 * 1024, // 256 KiB
    this.avgSize = 1024 * 1024, // 1 MiB
    this.maxSize = 4 * 1024 * 1024, // 4 MiB
  });

  final int minSize;
  final int avgSize;
  final int maxSize;

  static const List<int> _gearTable = [
    0x00000000,
    0x1d0c5a3f,
    0x3a18b47e,
    0x2714ee41,
    0x743168fc,
    0x693d32c3,
    0x4e29dc82,
    0x532586bd,
    0xe862d1f8,
    0xf56e8bc7,
    0xd27a6586,
    0xcf763fb9,
    0x9c53b904,
    0x815fe33b,
    0xa64b0d7a,
    0xbb475745,
    0xd0c5a3f1,
    0xcdc9f9ce,
    0xeadd178f,
    0xf7d14db0,
    0xa4f4cb0d,
    0xb9f89132,
    0x9eec7f73,
    0x83e0254c,
    0x38a77209,
    0x25ab2836,
    0x02bf7677,
    0x1fb32c48,
    0x4c961af5,
    0x519a40ca,
    0x768ea28b,
    0x6b82f8b4,
    0xa18b47e3,
    0xbc871ddc,
    0x9b93f39d,
    0x869fa9a2,
    0xd5ba2f1f,
    0xc8b67520,
    0xefa29b61,
    0xf2aecd5e,
    0x49e9961b,
    0x54e5cc24,
    0x73f12265,
    0x6efd785a,
    0x3dd8feef,
    0x20d4a4d0,
    0x07c04a91,
    0x1ac810ae,
    0x714ee412,
    0x6c42be2d,
    0x4b56506c,
    0x565a0a53,
    0x057f8ce2,
    0x1873d6dd,
    0x3f67389c,
    0x226b62a3,
    0x992c35ea,
    0x84206fd5,
    0xa3348194,
    0xbe38dbab,
    0xed1d5d16,
    0xf0110729,
    0xd705e968,
    0xca09b357,
    0x43168fc7,
    0x5e1ad5f8,
    0x790e3bb9,
    0x64026186,
    0x3727e73b,
    0x2a2bbd04,
    0x0d3f5345,
    0x1033097a,
    0xab745e3f,
    0xb6780400,
    0x916ce241,
    0x8c60b87e,
    0xdf4536c3,
    0xc2496cfc,
    0xe55d82bd,
    0xf851d882,
    0x93d32c36,
    0x8edf7609,
    0xa9cb9848,
    0xb4c7c277,
    0xe7e244ca,
    0xfaee1ef5,
    0xddfaeed4,
    0xc0f6b4eb,
    0x7bb1fdce,
    0x66bd07f1,
    0x41a949b0,
    0x5ca5138f,
    0x0f809532,
    0x128ccf0d,
    0x3598214c,
    0x28947b73,
    0xe29dc824,
    0xff91921b,
    0xd8857c5a,
    0xc5892665,
    0x96ace0d8,
    0x8ba0bae7,
    0xacb454a6,
    0xb1b80e99,
    0x0aff19dc,
    0x17f343e3,
    0x30e7ad82,
    0x2debf7bd,
    0x7ece7120,
    0x63c22b1f,
    0x44d6c55e,
    0x59da9f61,
    0x32586bd5,
    0x2f5431ea,
    0x0840dfab,
    0x154c8594,
    0x46690329,
    0x5b655916,
    0x7c71b757,
    0x617de168,
    0xda3aab2d,
    0xc736f112,
    0xe0221f53,
    0xfd2e456c,
    0xae0bc3d1,
    0xb30799ee,
    0x941377af,
    0x891f2d90,
  ];

  /// Split byte buffer into content-defined chunk descriptors.
  List<ChunkDescriptor> chunk(Uint8List data) {
    if (data.isEmpty) return const [];
    final descriptors = <ChunkDescriptor>[];
    var bits = 0;
    var temp = avgSize;
    while (temp > 1) {
      temp >>= 1;
      bits++;
    }
    final mask = bits > 0 ? (1 << bits) - 1 : 0xFFFFF;
    final totalLen = data.length;
    var chunkStart = 0;

    while (chunkStart < totalLen) {
      final remaining = totalLen - chunkStart;
      if (remaining <= minSize) {
        // Last small chunk
        final chunkBytes = data.sublist(chunkStart);
        final digest = sha256.convert(chunkBytes);
        descriptors.add(ChunkDescriptor(
          offset: chunkStart,
          length: remaining,
          sha256: hex.encode(digest.bytes),
        ));
        break;
      }

      var fingerprint = 0;
      var pos = chunkStart + minSize;
      final maxPos = (chunkStart + maxSize).clamp(0, totalLen);

      while (pos < maxPos) {
        final byteVal = data[pos];
        fingerprint =
            ((fingerprint << 1) + _gearTable[byteVal & 0x1F]) & 0xFFFFFFFF;
        if ((fingerprint & mask) == 0) {
          pos++;
          break;
        }
        pos++;
      }

      final chunkLen = pos - chunkStart;
      final chunkBytes = data.sublist(chunkStart, chunkStart + chunkLen);
      final digest = sha256.convert(chunkBytes);
      descriptors.add(ChunkDescriptor(
        offset: chunkStart,
        length: chunkLen,
        sha256: hex.encode(digest.bytes),
      ));
      chunkStart = pos;
    }

    return descriptors;
  }
}
