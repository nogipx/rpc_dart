// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_compression/rpc_dart_compression.dart';
import 'package:test/test.dart';

void main() {
  const codec = RpcGzipCodec();

  final original = Uint8List.fromList(
    List.generate(2048, (i) => (i * 31 + 7) % 256),
  );

  group('B1 integrity checks', () {
    test('corrupted CRC bytes are rejected', () {
      final good = codec.compress(original);
      final bad = Uint8List.fromList(good);
      // gzip trailer = last 8 bytes: CRC32 (4) + ISIZE (4). Flip CRC bytes.
      bad[bad.length - 8] ^= 0xFF;
      bad[bad.length - 7] ^= 0xFF;

      Object? decoded;
      Object? thrown;
      try {
        decoded = codec.decompress(bad);
      } catch (e) {
        thrown = e;
      }

      expect(
        thrown,
        isNotNull,
        reason:
            'CRC-corrupted gzip must throw. Instead decoded '
            '${decoded is Uint8List ? '${decoded.length} bytes '
                      '(matches original: ${decoded.length == original.length && _eq(decoded, original)})' : decoded}. '
            'No integrity check -> CONFIRMED.',
      );
    });

    test('truncated payload is rejected', () {
      final good = codec.compress(original);
      // Drop the trailer + part of the deflate stream.
      final truncated = Uint8List.fromList(good.sublist(0, good.length - 12));

      Object? decoded;
      Object? thrown;
      try {
        decoded = codec.decompress(truncated);
      } catch (e) {
        thrown = e;
      }

      expect(
        thrown,
        isNotNull,
        reason:
            'Truncated gzip must throw. Instead decoded '
            '${decoded is Uint8List ? '${decoded.length} bytes' : decoded}. '
            'No length/CRC check -> CONFIRMED.',
      );
    });
  });
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
