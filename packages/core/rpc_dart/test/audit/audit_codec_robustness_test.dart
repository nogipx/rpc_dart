// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit findings (core audit, round 2):
//
// 1. special_cbor.dart: _readStringFast read the first byte with a raw
//    `_bytes[_offset++]`, so a truncated map (a declared entry whose key bytes
//    are missing) threw an uncaught RangeError instead of the FormatException
//    that callers catch to reject malformed frames.
//
// 2. special_cbor.dart: an 8-byte CBOR unsigned integer was returned without a
//    range check. A uint64 >= 2^63 wraps negative on the VM's signed 64-bit int
//    and loses precision past 2^53 on dart2js, silently corrupting the value.
//
// 3. protocol.dart: RpcMessageFrame.parseHeader reassembled the 32-bit length
//    with `byte << 24 | ...`, a signed 32-bit shift on dart2js, so a length
//    whose top byte has the high bit set wrapped negative. (VM ints are 64-bit,
//    so this regression only fails under dart2js / `melos run test:web`.)

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('CborCodec malformed-input error contract', () {
    test(
      'truncated map (declared entry, missing key) throws FormatException',
      () {
        // 0xA1 = map with 1 entry; no key/value bytes follow.
        expect(
          () => CborCodec.decode(Uint8List.fromList([0xa1])),
          throwsA(isA<FormatException>()),
          reason:
              'a truncated key read must surface FormatException, not '
              'an uncaught RangeError',
        );
      },
    );

    test('8-byte unsigned integer above 2^53 is rejected, not corrupted', () {
      // major type 0 (unsigned) + additional info 27 (eight-byte) + 2^63.
      final bytes = Uint8List.fromList([
        0x1b,
        0x80,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
      ]);
      expect(
        () => CborCodec.decodeUnsafe(bytes),
        throwsA(isA<FormatException>()),
        reason:
            'a uint64 that cannot be represented exactly on both the VM '
            'and dart2js must throw rather than decode to a wrapped/inexact '
            'number',
      );
    });

    test('uint64 at the maximum (0xFFFF...FF) is rejected', () {
      final bytes = Uint8List.fromList([
        0x1b,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
      ]);
      expect(
        () => CborCodec.decodeUnsafe(bytes),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('gRPC frame length is read as unsigned', () {
    test('a length with the high bit set decodes to a large positive int', () {
      // flag=0 (no compression), length = 0x80000000 (2_147_483_648),
      // big-endian in bytes 1..4.
      final header = Uint8List.fromList([0x00, 0x80, 0x00, 0x00, 0x00]);
      final parsed = RpcMessageFrame.parseHeader(header);

      expect(
        parsed.messageLength,
        2147483648,
        reason:
            'a 32-bit length must be unsigned; a signed shift would wrap '
            'this negative on dart2js',
      );
      expect(parsed.messageLength, greaterThan(0));
    });
  });
}
