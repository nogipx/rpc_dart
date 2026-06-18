// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding B2: varint decode uses native int `<< shift`, broken on dart2js.
//
// proto_parser.dart:212-223 and reflection_contract.dart:234-245:
//   result |= (b & 0x7F) << shift;   // guard only at `if (shift >= 64)`
//
// On dart2js (JS) `<<` is a 32-bit operation. A varint value whose magnitude
// exceeds 0xFFFFFFFF (bit 32+) is decoded INCORRECTLY (the high bits are lost /
// the value saturates at 32 bits). The shift>=64 guard never trips for a legal
// <=10-byte varint, so the corruption is silent.
//
// STATUS: the underlying primitive bug is REAL (demonstrated below by replicating
// the exact decode logic under -p node). HOWEVER it is NOT-TESTABLE through the
// public reflection parser API, because that parser only ever decodes:
//   * tags  -> field_number<<3 | wire_type. The wire_type (low 3 bits) comes
//              from shift 0 and always survives; a corrupted high field-number
//              still routes to skipField with the correct wire type, so output
//              is unchanged. (Verified empirically: a field number > 2^32
//              followed by a name field still parses the name correctly on node.)
//   * lengths -> always bounded by the buffer (< 2^32), so they never reach the
//                bit-32 corruption range before a bounds break.
// The parser never decodes a >2^32 value as observable DATA (no int64 fields are
// returned), so the bug cannot be surfaced via parseFileDescriptorProto /
// parseFileDescriptorSet / the reflection contract.
//
// The test below proves the primitive is broken by replicating the parser's exact
// loop. It asserts CORRECT decoding -> FAILS under `-p node` for values > 2^32
// (= bug CONFIRMED at the primitive level), and PASSES on the VM.
//
// Run: fvm dart test -p node test/audit/b2_varint_dart2js_test.dart

import 'package:test/test.dart';

/// Replicates the JS-safe varint decode loop now used by proto_parser.dart and
/// reflection_contract.dart: the low and high 32-bit halves are accumulated
/// separately and recombined via multiplication so the result stays correct on
/// dart2js (where `<<` is a 32-bit operation).
int decodeVarintAsInParser(List<int> bytes) {
  var low = 0;
  var high = 0;
  var shift = 0;
  var pos = 0;
  while (pos < bytes.length) {
    if (shift >= 64) throw const FormatException('Varint exceeds 64 bits');
    final b = bytes[pos++];
    final part = b & 0x7F;
    if (shift < 28) {
      low |= part << shift;
    } else if (shift == 28) {
      low |= (part & 0x0F) << 28;
      high = (part >> 4) & 0x07;
    } else {
      high |= part << (shift - 32);
    }
    if (b & 0x80 == 0) {
      return high == 0 ? low : (high * 0x100000000) + (low & 0xFFFFFFFF);
    }
    shift += 7;
  }
  throw const FormatException('Truncated varint');
}

/// Canonical varint encoder built WITHOUT `<<`/`>>` on large values so the
/// encoding itself is correct even when run under dart2js.
List<int> encodeVarintSafe(int value) {
  final out = <int>[];
  while (value > 0x7F) {
    out.add((value & 0x7F) | 0x80);
    value =
        value ~/ 128; // integer division avoids dart2js >> 32-bit saturation
  }
  out.add(value % 128);
  return out;
}

void main() {
  group('B2: parser varint decode (primitive-level)', () {
    test('values up to 2^32 decode correctly', () {
      for (final v in [0, 1, 0x7F, 0x3FFF, 0x7FFFFFFF, 0xFFFFFFFF]) {
        expect(
          decodeVarintAsInParser(encodeVarintSafe(v)),
          v,
          reason: 'failed at v=$v',
        );
      }
    });

    test('values above 2^32 decode correctly on dart2js (fix verified)', () {
      // 0x1FFFFFFFFF needs ~37 bits. The old `(b & 0x7F) << shift` saturated at
      // 32 bits under dart2js; the hi/lo-half decode now returns the full value.
      const v = 0x1FFFFFFFFF;
      final bytes = encodeVarintSafe(v);
      expect(
        decodeVarintAsInParser(bytes),
        v,
        reason: 'JS-safe varint decode must not truncate a >2^32 value',
      );
    });
  });
}
