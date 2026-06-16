// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Feature #4: the production decode() path (_FastCborReader) must decode the
// same subset as the slow _CborReader. It previously lacked a tag case and an
// undefined case. This test hand-crafts CBOR bytes containing a tagged value
// and a CBOR `undefined`, then asserts the fast path (CborCodec.decode) matches
// the slow path (CborCodec.decodeUnsafe).
//
// Run VM:   fvm dart test test/serializers/cbor_fast_tag_undefined_parity_test.dart
// Run node: fvm dart test -p node test/serializers/cbor_fast_tag_undefined_parity_test.dart

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('CBOR fast reader tag/undefined parity', () {
    // Builds a top-level map with two entries:
    //   "tagged" -> tag(0) 1234           (major type 6, tag 0, value 1234)
    //   "undef"  -> undefined             (major type 7, simple value 23)
    //
    // Bytes:
    //   a2                          map(2)
    //   66 7461 6767 6564           text(6) "tagged"
    //   c0                          tag(0)
    //   19 04d2                     unsigned 1234
    //   65 756e 6465 66             text(5) "undef"
    //   f7                          simple(23) undefined
    final bytes = Uint8List.fromList([
      0xa2,
      0x66, 0x74, 0x61, 0x67, 0x67, 0x65, 0x64, // "tagged"
      0xc0, // tag 0
      0x19, 0x04, 0xd2, // 1234
      0x65, 0x75, 0x6e, 0x64, 0x65, 0x66, // "undef"
      0xf7, // undefined
    ]);

    test('fast decode handles tag and undefined', () {
      final fast = CborCodec.decode(bytes);
      expect(fast['tagged'], 1234, reason: 'tag must be skipped, value read');
      expect(fast['undef'], isNull, reason: 'undefined maps to null');
    });

    test('fast decode matches slow decode (parity)', () {
      final fast = CborCodec.decode(bytes);
      final slow = CborCodec.decodeUnsafe(bytes);

      expect(slow, isA<Map>());
      final slowMap = (slow as Map).map((k, v) => MapEntry(k.toString(), v));
      expect(fast, equals(slowMap));
    });

    test('tag inside a nested array decodes via fast path', () {
      // { "list": [ tag(2) 42, undefined ] }
      //   a1                       map(1)
      //   64 6c697374              text(4) "list"
      //   82                       array(2)
      //   c2 18 2a                 tag(2) unsigned(0x2a = 42)
      //   f7                       undefined
      final nested = Uint8List.fromList([
        0xa1,
        0x64, 0x6c, 0x69, 0x73, 0x74, // "list"
        0x82,
        0xc2, 0x18, 0x2a,
        0xf7,
      ]);
      final fast = CborCodec.decode(nested);
      expect(fast['list'], [42, null]);
    });
  });
}
