// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// DECODE GUARD: special_cbor.dart now has a single reader (_FastCborReader)
// behind both decode (readMap, top-level map) and decodeUnsafe (readValue, any
// top-level value), plus two writers (the static _encode behind encodeUnsafe,
// and _FastCborWriter behind encode). This corpus-based test pins decoding
// correctness and writer agreement so future drift fails loudly.
//
// For every corpus value (always wrapped in a top-level map, since production
// only ever encodes maps) it asserts:
//   * encode/encodeUnsafe round-trips: decode(encode(x)) == x
//   * decodeUnsafe == decode for the same bytes (the two entry points agree)
//   * fast-encode == slow-encode (byte-identical writers)
// Hand-crafted CBOR (indefinite lengths, tags, half/single floats, extended
// simple values, undefined) is decoded and checked against expected values.
//
// Run VM:   fvm dart test test/serializers/cbor_parity_test.dart
// Run node: fvm dart test -p node test/serializers/cbor_parity_test.dart

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Normalizes a decoded structure so `Map<String,dynamic>` and
/// `Map<dynamic, dynamic>` from the two readers compare equal, and byte lists
/// compare by value.
dynamic _normalize(dynamic value) {
  if (value is Map) {
    final out = <String, dynamic>{};
    for (final entry in value.entries) {
      out[entry.key.toString()] = _normalize(entry.value);
    }
    return out;
  }
  if (value is List) {
    return value.map(_normalize).toList();
  }
  return value;
}

void main() {
  // Corpus of values exercised through the encode/decode pipelines. Each is
  // placed under key "v" in a top-level map.
  final corpus = <String, dynamic>{
    'zero': 0,
    'one': 1,
    'twentyThree': 23,
    'twentyFour': 24,
    'uint8 max': 255,
    'uint16 max': 65535,
    'uint16+1': 65536,
    'uint32 max': 4294967295,
    'uint32+1': 4294967296, // > 2^32, 8-byte form
    'big within 2^53': 5000000000,
    'pow2_52': 4503599627370496, // 2^52
    'neg one': -1,
    'neg 24': -24,
    'neg 25': -25,
    'neg 256': -256,
    'neg 257': -257,
    'neg uint32': -4294967296, // < -2^32, 8-byte negative form
    'double pi': 3.14159,
    'double tiny': 1.0e-300,
    'double huge': 1.0e300,
    'double neg zero': -0.0,
    'double nan': double.nan,
    'double inf': double.infinity,
    'double neg inf': double.negativeInfinity,
    'bool true': true,
    'bool false': false,
    'null': null,
    'empty string': '',
    'ascii': 'hello',
    'unicode': 'привет ☺ \u{1F600}',
    'empty bytes': Uint8List(0),
    'bytes': Uint8List.fromList([0, 1, 2, 255, 128]),
    'empty list': <dynamic>[],
    'list mixed': [1, 'a', true, null, 3.5, -7],
    'empty map': <String, dynamic>{},
    'nested': {
      'a': [
        1,
        {
          'b': [2, 3]
        }
      ],
      'c': {'d': 'e'}
    },
    'deep': _buildDeep(20),
  };

  group('CBOR round-trip + writer parity (corpus)', () {
    corpus.forEach((name, value) {
      test('round-trip + writer parity: $name', () {
        final original = {'v': value};

        // slow-encode -> both decode entry points (now one reader).
        final slowBytes = CborCodec.encodeUnsafe(original);
        final mapDecoded = _normalize(CborCodec.decode(slowBytes));
        final unsafeDecoded = _normalize(CborCodec.decodeUnsafe(slowBytes));

        // decode (readMap) and decodeUnsafe (readValue) share a reader and MUST
        // agree, always and on every platform.
        _expectEqual(mapDecoded, unsafeDecoded,
            reason: 'decode != decodeUnsafe for $name');

        // Round-trip to original. On dart2js (-p node) there is a single JS
        // number type, so an integral-valued double (e.g. 1e300, Infinity,
        // -0.0 once it loses its sign) is indistinguishable from an int at
        // runtime and gets encoded via the integer path. That is a platform
        // limitation, not an encode/decode divergence, so skip the strict
        // original check for those values.
        if (!_lossyOnThisPlatform(value)) {
          _expectEqual(mapDecoded, _normalize(original),
              reason: 'decode != original for $name');
        }

        // fast-encode must be byte-identical to slow-encode.
        final fastBytes = CborCodec.encode(original);
        expect(fastBytes, equals(slowBytes),
            reason: 'fast-encode bytes != slow-encode bytes for $name');

        // And fast bytes must decode back to the same value.
        _expectEqual(_normalize(CborCodec.decode(fastBytes)), unsafeDecoded,
            reason: 'fast-encode -> decode != decodeUnsafe for $name');
      });
    });
  });

  group('CBOR hand-crafted decode (expected values)', () {
    // Decodes a hand-crafted byte sequence and checks it against the expected
    // value, through both decode (readMap) and decodeUnsafe (readValue) so the
    // two entry points stay in agreement on exotic inputs.
    void decodesTo(String name, List<int> raw, dynamic expected) {
      test(name, () {
        final bytes = Uint8List.fromList(raw);
        final norm = _normalize(expected);
        final viaMap = _normalize(CborCodec.decode(bytes));
        final viaUnsafe = _normalize(CborCodec.decodeUnsafe(bytes));
        _expectEqual(viaMap, norm, reason: 'decode mismatch on $name');
        _expectEqual(viaUnsafe, norm, reason: 'decodeUnsafe mismatch on $name');
      });
    }

    // { "a": tag(0) 1234, "u": undefined } -> tag skipped, undefined -> null
    decodesTo('tag + undefined', [
      0xa2,
      0x61, 0x61, // "a"
      0xc0, 0x19, 0x04, 0xd2, // tag(0) 1234
      0x61, 0x75, // "u"
      0xf7, // undefined
    ], {
      'a': 1234,
      'u': null
    });

    // { "f": half-float 1.5 (0x3e00) }
    decodesTo('half float', [
      0xa1,
      0x61, 0x66, // "f"
      0xf9, 0x3e, 0x00, // half 1.5
    ], {
      'f': 1.5
    });

    // { "f": single float 1.5 (0x3fc00000) }
    decodesTo('single float', [
      0xa1,
      0x61, 0x66, // "f"
      0xfa, 0x3f, 0xc0, 0x00, 0x00, // single 1.5
    ], {
      'f': 1.5
    });

    // { "f": half NaN (0x7e00) }
    decodesTo('half NaN', [
      0xa1,
      0x61,
      0x66,
      0xf9,
      0x7e,
      0x00,
    ], {
      'f': double.nan
    });

    // { "f": half +Infinity (0x7c00) }
    decodesTo('half Infinity', [
      0xa1,
      0x61,
      0x66,
      0xf9,
      0x7c,
      0x00,
    ], {
      'f': double.infinity
    });

    // { "f": half subnormal smallest (0x0001) = 2^-24 }
    decodesTo('half subnormal', [
      0xa1,
      0x61,
      0x66,
      0xf9,
      0x00,
      0x01,
    ], {
      'f': 5.960464477539063e-8
    });

    // { "s": extended simple value 200 (0xf8 0xc8) -> 200 }
    decodesTo('extended simple value', [
      0xa1,
      0x61, 0x73, // "s"
      0xf8, 0xc8,
    ], {
      's': 200
    });

    // { "l": indefinite array [1, 2, 3] }
    decodesTo('indefinite array', [
      0xa1,
      0x61, 0x6c, // "l"
      0x9f, 0x01, 0x02, 0x03, 0xff,
    ], {
      'l': [1, 2, 3]
    });

    // { "m": indefinite map { "x": 1 } }
    decodesTo('indefinite map', [
      0xa1,
      0x61, 0x6d, // "m"
      0xbf, 0x61, 0x78, 0x01, 0xff,
    ], {
      'm': {'x': 1}
    });

    // indefinite top-level map { "k": "v" }
    decodesTo('indefinite top-level map', [
      0xbf,
      0x61, 0x6b, // "k"
      0x61, 0x76, // "v"
      0xff,
    ], {
      'k': 'v'
    });

    // { "s": indefinite text string "hello" = "he"+"llo" }
    decodesTo('indefinite text string', [
      0xa1,
      0x61, 0x73, // "s"
      0x7f,
      0x62, 0x68, 0x65, // "he"
      0x63, 0x6c, 0x6c, 0x6f, // "llo"
      0xff,
    ], {
      's': 'hello'
    });

    // { "b": indefinite byte string 0x0102 + 0x03 -> 0x010203 }
    decodesTo('indefinite byte string', [
      0xa1,
      0x61, 0x62, // "b"
      0x5f,
      0x42, 0x01, 0x02,
      0x41, 0x03,
      0xff,
    ], {
      'b': Uint8List.fromList([1, 2, 3])
    });

    // { "n": [tag(2) 42, undefined] } -> tag skipped, undefined -> null
    decodesTo('nested tag in array', [
      0xa1,
      0x61, 0x6e, // "n"
      0x82, 0xc2, 0x18, 0x2a, 0xf7, // [tag(2) 42, undefined]
    ], {
      'n': [42, null]
    });
  });

  group('CBOR recursion-depth guard (untrusted input)', () {
    // 0x81 = definite-length array with one element. A chain of these encodes
    // an arbitrarily deep nesting that would overflow the native stack.
    Uint8List nestedArrays(int depth) {
      final bytes = Uint8List(depth + 1);
      for (var i = 0; i < depth; i++) {
        bytes[i] = 0x81; // array(1)
      }
      bytes[depth] = 0x00; // innermost value: 0
      return bytes;
    }

    // 0xa1 0x61 0x6e = map(1) with key "n"; value is the next nested map.
    Uint8List nestedMaps(int depth) {
      final builder = BytesBuilder();
      for (var i = 0; i < depth; i++) {
        builder.add([0xa1, 0x61, 0x6e]); // map(1), "n"
      }
      builder.addByte(0x00); // innermost value
      return builder.toBytes();
    }

    test('rejects deeply-nested arrays with FormatException', () {
      // Shallow nesting still decodes fine.
      expect(CborCodec.decodeUnsafe(nestedArrays(10)), isA<List>());
      // A pathological depth throws instead of crashing the isolate.
      expect(
        () => CborCodec.decodeUnsafe(nestedArrays(5000)),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('nesting too deep'),
        )),
      );
    });

    test('rejects deeply-nested maps with FormatException', () {
      expect(CborCodec.decode(nestedMaps(10)), isA<Map>());
      expect(
        () => CborCodec.decode(nestedMaps(5000)),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('nesting too deep'),
        )),
      );
    });

    test('rejects deeply-nested tags with FormatException', () {
      // 0xc2 = tag(2). A long tag chain also recurses through _readValueFast.
      final builder = BytesBuilder();
      for (var i = 0; i < 5000; i++) {
        builder.addByte(0xc2);
      }
      builder.addByte(0x00);
      expect(
        () => CborCodec.decodeUnsafe(builder.toBytes()),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

/// Returns true if [value] is a double that this platform cannot tell apart
/// from an int (dart2js collapses integral doubles into the single JS number
/// type, so they round-trip as ints rather than preserving the double type).
bool _lossyOnThisPlatform(dynamic value) {
  // On the VM `1.0 is int` is false; on dart2js it is true. We only skip when
  // a declared-double value reports as int at runtime.
  return value is double && (value as Object) is int;
}

/// Builds a value nested [depth] levels deep to exercise recursion.
dynamic _buildDeep(int depth) {
  dynamic node = 'leaf';
  for (int i = 0; i < depth; i++) {
    node = {'child': node, 'i': i};
  }
  return node;
}

/// Asserts equality treating NaN == NaN and -0.0 == -0.0 specially.
void _expectEqual(dynamic a, dynamic b, {required String reason}) {
  expect(_deepEquals(a, b), isTrue, reason: '$reason\n  a=$a\n  b=$b');
}

bool _deepEquals(dynamic a, dynamic b) {
  if (a is double && b is double) {
    if (a.isNaN && b.isNaN) return true;
    if (a == 0.0 && b == 0.0) {
      return a.isNegative == b.isNegative;
    }
    return a == b;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!_deepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
