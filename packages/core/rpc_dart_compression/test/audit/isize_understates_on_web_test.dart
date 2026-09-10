// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// B-29. `RpcGzipCodec` pre-checks the gzip ISIZE trailer before allocating, and
// ISIZE is the size MOD 2^32 -- so a payload that inflates to k*2^32 + small
// declares `small` and clears the pre-check. `boundedInflate` is the fix, and on
// web it is `=> null`: package:archive materialises the whole output and cannot
// be halted, so the limit runs on `result.length`, AFTER the output exists.
//
// `isize_wrap_bomb_test.dart` proves the VM half and is `@TestOn('vm')`, because
// it builds a true 4 GiB wrap with dart:io's encoder. So the platform WITHOUT
// the defence is the platform that test cannot reach.
//
// This runs on BOTH, and forges the trailer instead of wrapping it: same defect
// class -- ISIZE understating the real output -- at a size any runtime can
// build. What it asserts is the CONTRACT, which must hold everywhere: a payload
// over the limit is refused, and refused without handing back its bytes.

import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:rpc_dart_compression/rpc_dart_compression.dart';
import 'package:test/test.dart';

/// 16 MiB, the codec's usual ceiling in these audits.
const int _limit = 16 * 1024 * 1024;

/// Real output well past [_limit], so the post-check must reject it.
const int _realOutput = 64 * 1024 * 1024;

/// Gzip of [_realOutput] zeros whose ISIZE trailer is overwritten to lie.
///
/// The last four bytes of a gzip member are ISIZE, little-endian. Rewriting
/// them is exactly what a 4 GiB wrap does arithmetically, without needing to
/// compress 4 GiB.
Uint8List _forgedIsize({int declares = 4096}) {
  final encoded = GZipEncoder().encodeBytes(Uint8List(_realOutput));
  final bytes = Uint8List.fromList(encoded);
  final n = bytes.length;
  bytes[n - 4] = declares & 0xff;
  bytes[n - 3] = (declares >> 8) & 0xff;
  bytes[n - 2] = (declares >> 16) & 0xff;
  bytes[n - 1] = (declares >> 24) & 0xff;
  return bytes;
}

void main() {
  test(
    'a payload whose ISIZE understates it is refused on every runtime',
    () {
      final bomb = _forgedIsize();

      // The pre-check must not be what saves us, or the test proves nothing about
      // the path after it.
      final n = bomb.length;
      final declared =
          bomb[n - 4] |
          (bomb[n - 3] << 8) |
          (bomb[n - 2] << 16) |
          (bomb[n - 1] << 24);
      expect(
        declared,
        lessThan(_limit),
        reason: 'the bomb must look harmless to a trailer-based pre-check',
      );

      final codec = RpcGzipCodec();
      final sw = Stopwatch()..start();
      expect(
        () => codec.decompress(bomb, maxOutputBytes: _limit),
        throwsA(isA<FormatException>()),
        reason: 'over the limit is over the limit, on the VM and on dart2js',
      );
      sw.stop();

      // Reported rather than asserted: the VM aborts mid-inflate and web cannot,
      // so a threshold here would pin the platform difference instead of the
      // contract. The number is what B-29 wanted measured.
      // ignore: avoid_print
      print(
        'isize-understated decompress refused in ${sw.elapsedMilliseconds} ms '
        '(declared $declared, real $_realOutput, limit $_limit)',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'GUARD: an honest payload inside the limit still round-trips',
    () {
      // Without this the witness would pass on a codec that refused everything.
      final codec = RpcGzipCodec();
      final data = Uint8List(1024 * 1024);
      final round = codec.decompress(
        codec.compress(data),
        maxOutputBytes: _limit,
      );
      expect(round.length, data.length);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
