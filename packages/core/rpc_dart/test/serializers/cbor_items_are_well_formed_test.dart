// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Three edges where the codec parted from RFC 8949: bytes after the one data
// item, simple values with no meaning here, and the sign of zero from dart2js.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

Uint8List _hex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

void main() {
  group('one data item, nothing after it', () {
    test('two maps glued together are refused', () {
      // {"a": 1} {"b": 2}
      expect(
        () => CborCodec.decode(_hex('a1616101a1616202')),
        throwsFormatException,
      );
    });

    test('a valid item followed by garbage is refused', () {
      expect(() => CborCodec.decodeUnsafe(_hex('0001')), throwsFormatException);
    });

    test('GUARD a single item still decodes', () {
      expect(CborCodec.decode(_hex('a1616101')), {'a': 1});
    });

    test('GUARD a truncated item is still refused', () {
      expect(() => CborCodec.decode(_hex('a16161')), throwsFormatException);
    });
  });

  group('simple values with no meaning here are refused', () {
    test('an unassigned simple value is not an int', () {
      // {"v": simple(16)}
      expect(() => CborCodec.decode(_hex('a16176f0')), throwsFormatException);
    });

    test('the two-byte form of a small simple value is not well-formed', () {
      // {"v": f8 18} -- RFC 8949 3.3
      expect(() => CborCodec.decode(_hex('a16176f818')), throwsFormatException);
    });

    test('GUARD false, true and null still decode', () {
      expect(CborCodec.decode(_hex('a3616ff46174f5616ef6')), {
        'o': false,
        't': true,
        'n': null,
      });
    });
  });

  test('-0.0 keeps its sign', () {
    final back = RpcDouble.codec.deserialize(
      RpcDouble.codec.serialize(const RpcDouble(-0.0)),
    );
    expect(back.value.isNegative, isTrue, reason: 'sent as 0');
  });

  test('GUARD 0 is still an integer zero', () {
    expect(CborCodec.encode({'v': 0}), _hex('a1617600'));
  });
}
