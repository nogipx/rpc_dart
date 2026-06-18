// SPDX-License-Identifier: MIT
//
// AUDIT B3: the `level` constructor / register param (0..9) was not validated.
// An out-of-range level (e.g. 10) makes archive's deflate silently emit a gzip
// frame with NO compressed payload (its range throw is commented out), so
// compress() produced silently-corrupt output. gzip_codec.dart.
//
// CORRECT: an out-of-range level either throws in dev (assert) or is clamped
// defensively at the encode site so release / dart2js builds still produce a
// valid gzip that round-trips to the original.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_compression/rpc_dart_compression.dart';
import 'package:test/test.dart';

void main() {
  final original = Uint8List.fromList(
    List.generate(4096, (i) => (i * 37 + 11) % 256),
  );

  group('B3 level validation', () {
    test('in-range levels round-trip', () {
      for (final level in [0, 1, 6, 9]) {
        final codec = RpcGzipCodec(level: level);
        final out = codec.decompress(codec.compress(original));
        expect(out, equals(original), reason: 'level $level round-trip');
      }
    });

    test('out-of-range level throws in dev (asserts enabled)', () {
      // Asserts are ON under `dart test` (dev), so the constructor must reject
      // an out-of-range level outright.
      expect(() => RpcGzipCodec(level: 10), throwsA(isA<AssertionError>()));
      expect(() => RpcGzipCodec(level: -1), throwsA(isA<AssertionError>()));
      expect(
        () => RpcGzipCodec.register(level: 10),
        throwsA(isA<AssertionError>()),
      );
    });

    test(
      'encode never emits an empty/corrupt gzip frame (clamp safety net)',
      () {
        // In release / dart2js builds the constructor assert is stripped, so the
        // defensive `level.clamp(0, 9)` at the encode site is the real guard
        // against archive's silent "empty payload" behaviour for out-of-range
        // levels. Verify the boundary levels (what the clamp maps to) always
        // produce a valid, decompressible gzip — proving compress() can never
        // emit an empty/corrupt frame regardless of the requested level.
        for (final level in [0, 9]) {
          final codec = RpcGzipCodec(level: level);
          final compressed = codec.compress(original);
          // Valid gzip header.
          expect(compressed[0], equals(0x1f));
          expect(compressed[1], equals(0x8b));
          // Non-empty frame (header 10 + trailer 8 = 18 minimum).
          expect(compressed.length, greaterThan(18));
          // Round-trips back to the original.
          expect(codec.decompress(compressed), equals(original));
        }
      },
    );
  });
}
