// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT
//
// BUG 3 regression: the built-in dart:io gzip decompressor is bounded so a
// decompression bomb is rejected before its full expansion is materialized.
// Uses dart:io gzip to build the bomb, so this suite is VM-only.
@TestOn('vm')
library;

import 'dart:io' show gzip;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('BUG 3: gzip decompression is bounded against bombs', () {
    test('a tiny gzip expanding past the limit is rejected', () {
      // 4 MiB of zeros compresses to a few KiB but expands hugely.
      final bomb = Uint8List.fromList(gzip.encode(Uint8List(4 * 1024 * 1024)));
      expect(bomb.length, lessThan(64 * 1024));

      expect(
        () => RpcGrpcCompression.decompress(
          bomb,
          encoding: RpcGrpcCompression.gzip,
          maxOutputBytes: 64 * 1024,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('legitimate small payload within the limit decompresses', () {
      final original = Uint8List.fromList(
        List<int>.generate(2048, (i) => i & 0xFF),
      );
      final compressed = Uint8List.fromList(gzip.encode(original));
      final out = RpcGrpcCompression.decompress(
        compressed,
        encoding: RpcGrpcCompression.gzip,
        maxOutputBytes: 64 * 1024,
      );
      expect(out, equals(original));
    });

    test('unbounded decompress (no limit) still works for normal payloads', () {
      final original = Uint8List.fromList([9, 8, 7, 6, 5]);
      final compressed = Uint8List.fromList(gzip.encode(original));
      final out = RpcGrpcCompression.decompress(
        compressed,
        encoding: RpcGrpcCompression.gzip,
      );
      expect(out, equals(original));
    });
  });
}
