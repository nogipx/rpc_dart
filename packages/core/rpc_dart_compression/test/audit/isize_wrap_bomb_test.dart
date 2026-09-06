// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The size guard used to fire AFTER the damage.
//
// gzip's ISIZE trailer is the uncompressed size MOD 2^32, so a payload that
// inflates to k*2^32 + small declares "small" and slips past a pre-check that
// trusts it. `package:archive` then materialises the whole output before the
// post-check can look at it -- and it cannot be interrupted, because both of
// its paths buffer internally (the VM one through a
// `ChunkedConversionSink.withCallback` that only fires at close, the web one
// through `Inflate.stream(input).getBytes()`).
//
// Measured with 4.0 MiB of compressed zeros declaring ISIZE 4096, against a
// 16 MiB limit:
//
//   before : RSS +1873 MiB, 17488 ms, then FormatException
//   after  : RSS   +23.9 MiB,     8 ms
//
// ~470x amplification per wire byte, reachable by anyone who can send a
// gzip-encoded message to a peer that registered this codec.
//
// VM only: the fix is `dart:io`'s converter, which can be stopped mid-stream.
// On web no incremental inflater exists and the whole-buffer path remains --
// documented in bounded_inflate_stub.dart, not silently assumed away.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rpc_dart_compression/rpc_dart_compression.dart';
import 'package:test/test.dart';

/// Builds gzip whose ISIZE trailer wraps: real output is 4 GiB + [tail].
Uint8List _wrappingBomb({int tail = 4096}) {
  const chunk = 1 << 20;
  final zeros = Uint8List(chunk);
  final collected = BytesBuilder(copy: false);
  final sink = ByteConversionSink.withCallback(collected.add);
  final conv = gzip.encoder.startChunkedConversion(sink);
  for (var i = 0; i < (1 << 32) ~/ chunk; i++) {
    conv.add(zeros);
  }
  conv.add(Uint8List(tail));
  conv.close();
  return collected.toBytes();
}

void main() {
  test(
    'a payload whose ISIZE wraps is refused without inflating it',
    () async {
      final bomb = _wrappingBomb();

      // The pre-check cannot catch this one: ISIZE says 4096.
      final n = bomb.length;
      final declared =
          bomb[n - 4] |
          (bomb[n - 3] << 8) |
          (bomb[n - 2] << 16) |
          (bomb[n - 1] << 24);
      expect(
        declared,
        lessThan(16 * 1024 * 1024),
        reason: 'the bomb must look harmless to a trailer-based pre-check',
      );

      final codec = RpcGzipCodec();
      final before = ProcessInfo.currentRss;
      final sw = Stopwatch()..start();

      expect(
        () => codec.decompress(bomb, maxOutputBytes: 16 * 1024 * 1024),
        throwsA(isA<FormatException>()),
      );

      sw.stop();
      final grewMiB = (ProcessInfo.currentRss - before) / 1024 / 1024;

      // Bounded assertions, so a fixed threshold is sound: contention can only
      // make this slower, never make it allocate less.
      expect(
        grewMiB,
        lessThan(400),
        reason:
            'inflating ran to completion: RSS grew '
            '${grewMiB.toStringAsFixed(1)} MiB for a 16 MiB limit',
      );
      expect(
        sw.elapsedMilliseconds,
        lessThan(5000),
        reason: 'took ${sw.elapsedMilliseconds} ms, i.e. it inflated 4 GiB',
      );
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test('GUARD: an honest payload within the limit still round-trips', () {
    final codec = RpcGzipCodec();
    final payload = Uint8List.fromList(List<int>.filled(64 * 1024, 7));
    final compressed = codec.compress(payload);

    final out = codec.decompress(compressed, maxOutputBytes: 16 * 1024 * 1024);
    expect(out, equals(payload));
  });

  test('GUARD: an honest payload OVER the limit is still refused', () {
    final codec = RpcGzipCodec();
    final payload = Uint8List.fromList(List<int>.filled(256 * 1024, 3));
    final compressed = codec.compress(payload);

    expect(
      () => codec.decompress(compressed, maxOutputBytes: 1024),
      throwsA(isA<FormatException>()),
    );
  });
}
