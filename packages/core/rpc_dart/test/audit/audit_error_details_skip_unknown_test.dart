// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding (core audit, round 2): the hand-rolled protobuf decoders in
// error_details.dart handled only wire types 0 (varint) and 2 (length-
// delimited) and `break`-ed on anything else, abandoning the rest of the
// buffer. Protobuf's forward-compatibility rule requires unknown fields to be
// SKIPPED, not treated as fatal: a peer (or a future revision of
// google.rpc.Status) that places a fixed-width field before `details` would
// otherwise silently drop the entire details list.
//
// Fix: _skipField advances past unknown varint/64-bit/length-delimited/32-bit
// fields so subsequent known fields are still decoded.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('decodeRpcStatus skips unknown fields', () {
    test('a 64-bit (wire type 1) unknown field before the rest is skipped', () {
      final valid = encodeRpcStatus(5, 'oops', [
        RpcRetryInfo(const Duration(seconds: 2)),
      ]);

      // Prepend an unknown field 4 with wire type 1 (64-bit fixed): tag byte
      // (4 << 3) | 1 = 0x21, followed by 8 payload bytes. The old decoder would
      // break here and lose the code, message, and details that follow.
      final hostile = Uint8List.fromList([
        0x21,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        ...valid,
      ]);

      final decoded = decodeRpcStatus(hostile);

      expect(
        decoded.code,
        5,
        reason: 'code after an unknown field must survive',
      );
      expect(decoded.message, 'oops');
      expect(
        decoded.details,
        hasLength(1),
        reason: 'details after an unknown field must not be dropped',
      );
      expect(decoded.details.first, isA<RpcRetryInfo>());
    });

    test('a 32-bit (wire type 5) unknown field is skipped', () {
      final valid = encodeRpcStatus(7, 'boom', const []);
      // Unknown field 6, wire type 5: tag (6 << 3) | 5 = 0x35, 4 payload bytes.
      final hostile = Uint8List.fromList([
        0x35,
        0xDE,
        0xAD,
        0xBE,
        0xEF,
        ...valid,
      ]);

      final decoded = decodeRpcStatus(hostile);
      expect(decoded.code, 7);
      expect(decoded.message, 'boom');
    });
  });
}
