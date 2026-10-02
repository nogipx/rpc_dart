// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// compressIfSmaller compresses and keeps the smaller result, so a payload gzip
// cannot shrink paid for a compress that was thrown away. A gzip member is
// never shorter than 20 bytes, whatever the codec, so a payload no longer than
// that is sent plain without compressing it.

@TestOn('vm')
library;

import 'dart:io' show gzip;
import 'dart:math';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// gzip, counting how often it is asked to compress.
final class _CountingGzip implements RpcCompressionCodec {
  int compressed = 0;

  @override
  Uint8List compress(Uint8List data) {
    compressed++;
    return Uint8List.fromList(gzip.encode(data));
  }

  @override
  Uint8List decompress(Uint8List data, {int? maxOutputBytes}) =>
      Uint8List.fromList(gzip.decode(data));
}

void main() {
  late _CountingGzip codec;

  setUp(() {
    codec = _CountingGzip();
    RpcGrpcCompression.register('gzip', codec);
  });

  tearDown(() => RpcGrpcCompression.unregister('gzip'));

  test('a payload no longer than gzip\'s floor is not compressed', () {
    final result = RpcGrpcCompression.compressIfSmaller(
      Uint8List(20),
      encoding: 'GZIP',
    );
    expect(result.$2, isFalse);
    expect(codec.compressed, 0);
  });

  test('CONTROL: one byte longer is compressed and compared', () {
    RpcGrpcCompression.compressIfSmaller(Uint8List(21), encoding: 'gzip');
    expect(codec.compressed, 1);
  });

  test('GUARD: the floor never changes what is sent', () {
    // Against compressing every payload and keeping the smaller, for every
    // length up to past the floor and both kinds of content.
    final rnd = Random(7);
    for (var n = 0; n <= 40; n++) {
      for (final data in [
        Uint8List(n),
        Uint8List.fromList(List.generate(n, (_) => rnd.nextInt(256))),
      ]) {
        final full = gzip.encode(data);
        final expected = full.length < data.length;
        final (bytes, compressed) = RpcGrpcCompression.compressIfSmaller(
          data,
          encoding: 'gzip',
        );
        expect(compressed, expected, reason: 'length $n');
        if (!compressed) expect(bytes, data, reason: 'length $n');
      }
    }
  });
}
