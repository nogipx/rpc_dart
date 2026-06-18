// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_compression/rpc_dart_compression.dart';
import 'package:test/test.dart';

void main() {
  const codec = RpcGzipCodec();

  test('non-gzip bytes are rejected by decompress', () {
    // Definitely not gzip: wrong magic, random-looking content.
    final notGzip = Uint8List.fromList(
      List.generate(64, (i) => (i * 13 + 5) % 256),
    );

    Object? decoded;
    Object? thrown;
    try {
      decoded = codec.decompress(notGzip);
    } catch (e) {
      thrown = e;
    }

    expect(
      thrown,
      isNotNull,
      reason:
          'Non-gzip input must throw (invalid magic / signature). '
          'Instead returned '
          '${decoded is Uint8List ? '${decoded.length} bytes: $decoded' : decoded}. '
          'Silent accept on web -> CONFIRMED.',
    );
  });
}
