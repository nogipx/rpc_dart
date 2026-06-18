// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding 1: CBOR 8-byte integer READ broken on dart2js.
//
// special_cbor.dart:420-426 (_readUnsignedInt) and 722-737
// (_readUnsignedIntFast) decode an 8-byte CBOR integer with
//   result = (result << 8) | _readByte();
// On dart2js the `<<` / `|` operators are 32-BIT JS bitwise ops. Any value that
// needs more than 32 bits (i.e. anything encoded in the 8-byte form, which the
// encoder uses for value > 0xFFFFFFFF) is truncated to 32 bits on read. The
// encode side (special_cbor.dart) uses JS-safe writes, so the asymmetry means:
// encode keeps the value, decode mangles it.
//
// The test values below are all EXACTLY representable as JS doubles so dart2js
// will compile them, yet each forces the 8-byte CBOR read path. This isolates
// the 32-bit-shift bug rather than the 2^53 mantissa limit.
//
// Run VM:   fvm dart test test/audit/audit_cbor_uint64_test.dart   -> passes
// Run node: fvm dart test -p node test/audit/audit_cbor_uint64_test.dart
// CONFIRMED if the node run FAILS while the VM run passes.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group(
    'CBOR 8-byte int roundtrip (run with -p node to expose dart2js bug)',
    () {
      test('2^32 + 1 survives encode/decode roundtrip', () {
        // 4294967297 = 0x1_0000_0001. > 0xFFFFFFFF => encoder uses the 8-byte
        // form. Exactly representable in JS. The 32-bit `<<` on read drops the
        // high bit, yielding 1 on dart2js.
        const value = 4294967297;
        final encoded = CborCodec.encode({'v': value});
        final decoded = CborCodec.decode(encoded);

        expect(
          decoded['v'],
          equals(value),
          reason:
              'decoded ${decoded['v']} != $value; dart2js (result << 8)|byte '
              'is a 32-bit op and truncates 8-byte ints',
        );
      });

      test('0xFF_0000_0000 survives roundtrip', () {
        const value = 0xFF00000000; // 1095216660480, fits JS double exactly
        final encoded = CborCodec.encode({'v': value});
        final decoded = CborCodec.decode(encoded);
        expect(
          decoded['v'],
          equals(value),
          reason: 'high bytes lost via 32-bit shift on dart2js',
        );
      });

      test('5_000_000_000 survives roundtrip', () {
        const value = 5000000000; // > 2^32, well within 2^53
        final encoded = CborCodec.encode({'v': value});
        final decoded = CborCodec.decode(encoded);
        expect(decoded['v'], equals(value));
      });
    },
  );
}
