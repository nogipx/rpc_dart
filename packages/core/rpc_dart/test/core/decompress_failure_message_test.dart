// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The parser's decompress `catch` rewrapped EVERY throw as
//
//   Decompressed gRPC payload exceeds the configured limit (max: N)
//
// A decompressor throws for the bomb it was asked to stop AND for input that is
// malformed, truncated, or not compressed at all -- `rpc_dart_compression`'s
// gzip codec raises FormatException with a different message for each. The
// catch cannot tell them apart, so it named one:
//
//   input                       message
//   a bomb (valid gzip header)  ...exceeds the configured limit (max: N)
//   corrupt / not gzip at all   ...exceeds the configured limit (max: N)
//
// The second is a peer being told to send LESS for a frame that is simply
// broken, which cannot help. Stating the fact and leaving both causes open is
// honest; naming one is not.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

List<int> _be32(int v) => [
  (v >> 24) & 0xff,
  (v >> 16) & 0xff,
  (v >> 8) & 0xff,
  v & 0xff,
];

/// One compressed gRPC frame carrying [body].
Uint8List _compressedFrame(List<int> body) => Uint8List.fromList([
  1, // compressed flag
  ..._be32(body.length),
  ...body,
]);

/// Runs [parser] over one compressed frame and returns the error text.
String _failureText(RpcMessageParser parser, List<int> body) {
  try {
    parser(_compressedFrame(body)).toList();
    return 'no error at all';
  } catch (e) {
    return e.toString();
  }
}

void main() {
  group('a decompression failure names what is actually known', () {
    // Behaves like the real gzip codec: distinct messages per cause.
    Uint8List codec(Uint8List payload, {int? maxOutputBytes}) {
      if (payload.length >= 2 && payload[0] == 0x1f && payload[1] == 0x8b) {
        throw const FormatException(
          'Invalid gzip data: declared size 99999999 exceeds limit 16777216',
        );
      }
      throw const FormatException('Invalid gzip data: not in gzip format');
    }

    // WITNESS: corrupt input must not be reported as an over-limit payload.
    test('corrupt input is not reported as exceeding a limit', () {
      final text = _failureText(RpcMessageParser(decompressor: codec), [
        0x00,
        0x8b,
        1,
        2,
        3,
        4,
        5,
        6,
      ]);

      expect(text, contains('could not be decompressed'));
      expect(
        text,
        isNot(contains('exceeds the configured limit')),
        reason:
            'the peer is told to send less for a frame that is simply broken',
      );
    });

    // GUARD: the limit must still be NAMED. It is one of the two causes and the
    // only one the peer can act on, so dropping it would trade one missing fact
    // for another.
    test('GUARD: the configured limit is still reported', () {
      final text = _failureText(
        RpcMessageParser(decompressor: codec, maxMessageLength: 4096),
        [0x1f, 0x8b, 1, 2, 3, 4, 5, 6],
      );

      expect(text, contains('4096'));
      expect(text, contains('could not be decompressed'));
    });

    // GUARD: a decompressor that IGNORES the hint and returns oversized output
    // still gets the precise message, because there the parser DOES know.
    test('GUARD: oversized output still reports the exact size', () {
      Uint8List oversized(Uint8List payload, {int? maxOutputBytes}) =>
          Uint8List(5000);

      final text = _failureText(
        RpcMessageParser(decompressor: oversized, maxMessageLength: 4096),
        [0x1f, 0x8b, 1, 2, 3],
      );

      expect(text, contains('too large'));
      expect(text, contains('5000'));
    });

    // GUARD: a decompressor that works is untouched.
    test('GUARD: a successful decompression still parses', () {
      Uint8List fine(Uint8List payload, {int? maxOutputBytes}) =>
          Uint8List.fromList([7, 7, 7]);

      final messages = RpcMessageParser(decompressor: fine)(
        _compressedFrame([0x1f, 0x8b, 1]),
      ).toList();

      expect(messages, hasLength(1));
      expect(messages.single, [7, 7, 7]);
    });
  });
}
