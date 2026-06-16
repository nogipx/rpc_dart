// SPDX-License-Identifier: MIT
//
// AUDIT B2: the WEB decode path silently accepts malformed / non-gzip input,
// returning garbage or empty with NO exception (archive 4.x web GZipDecoder
// has its signature checks commented out / behaves differently from the VM
// inflate path). gzip_codec.dart:34.
//
// This test is platform-aware. Feed clearly non-gzip bytes (no 0x1f 0x8b
// magic) to decompress and assert it THROWS.
//   - On the VM the native/inflate path generally rejects it.
//   - On the web (run with `-p node` or `-p chrome`) it does NOT throw
//     -> CONFIRMED. Compare the two runs.

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
      reason: 'Non-gzip input must throw (invalid magic / signature). '
          'Instead returned '
          '${decoded is Uint8List ? '${decoded.length} bytes: $decoded' : decoded}. '
          'Silent accept on web -> CONFIRMED.',
    );
  });
}
