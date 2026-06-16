// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// PARITY GUARD: special_cbor.dart contains two readers (the reference
// _CborReader behind decodeUnsafe, and the fast _FastCborReader behind decode)
// plus two writers (the slow _encode behind encodeUnsafe, and _FastCborWriter
// behind encode). They have silently diverged before. This corpus-based test
// pins their behaviour together so future drift fails loudly.
//
// For every corpus value (always wrapped in a top-level map, since production
// only ever encodes maps) it asserts:
//   * slow-encode -> fast-decode == slow-decode == original (round-trip)
//   * fast-encode == slow-encode (byte-identical writers)
// Hand-crafted CBOR (indefinite lengths, tags, half/single floats, extended
// simple values, undefined) is decoded by both readers and compared directly.
//
// Run VM:   fvm dart test test/serializers/cbor_parity_test.dart
// Run node: fvm dart test -p node test/serializers/cbor_parity_test.dart

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Normalizes a decoded structure so Map<String,dynamic> and Map<dynamic,
/// dynamic> from the two readers compare equal, and byte lists compare by value.
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

  group('CBOR reader/writer parity (corpus)', () {
    corpus.forEach((name, value) {
      test('round-trip + writer parity: $name', () {
        final original = {'v': value};

        // slow-encode -> both decoders.
        final slowBytes = CborCodec.encodeUnsafe(original);
        final fastDecoded = _normalize(CborCodec.decode(slowBytes));
        final slowDecoded = _normalize(CborCodec.decodeUnsafe(slowBytes));

        // The load-bearing guarantee: the two readers MUST agree, always and
        // on every platform.
        _expectEqual(fastDecoded, slowDecoded,
            reason: 'fast-decode != slow-decode for $name');

        // Round-trip to original. On dart2js (-p node) there is a single JS
        // number type, so an integral-valued double (e.g. 1e300, Infinity,
        // -0.0 once it loses its sign) is indistinguishable from an int at
        // runtime and gets encoded via the integer path. That is a platform
        // limitation, not a reader/writer divergence, so skip the strict
        // original check for those values; fast==slow above still holds.
        if (!_lossyOnThisPlatform(value)) {
          _expectEqual(fastDecoded, _normalize(original),
              reason: 'fast-decode != original for $name');
        }

        // fast-encode must be byte-identical to slow-encode.
        final fastBytes = CborCodec.encode(original);
        expect(fastBytes, equals(slowBytes),
            reason: 'fast-encode bytes != slow-encode bytes for $name');

        // And fast bytes must decode the same through both readers too.
        _expectEqual(_normalize(CborCodec.decode(fastBytes)), slowDecoded,
            reason: 'fast-encode -> fast-decode != slow-decode for $name');
      });
    });
  });

  group('CBOR hand-crafted reader parity (slow vs fast)', () {
    void parity(String name, List<int> raw) {
      test(name, () {
        final bytes = Uint8List.fromList(raw);
        final fast = _normalize(CborCodec.decode(bytes));
        final slow = _normalize(CborCodec.decodeUnsafe(bytes));
        _expectEqual(fast, slow, reason: 'reader divergence on $name');
      });
    }

    // { "a": tag(0) 1234, "u": undefined }
    parity('tag + undefined', [
      0xa2,
      0x61, 0x61, // "a"
      0xc0, 0x19, 0x04, 0xd2, // tag(0) 1234
      0x61, 0x75, // "u"
      0xf7, // undefined
    ]);

    // { "f": half-float 1.5 (0x3e00) }
    parity('half float', [
      0xa1,
      0x61, 0x66, // "f"
      0xf9, 0x3e, 0x00, // half 1.5
    ]);

    // { "f": single float 1.5 (0x3fc00000) }
    parity('single float', [
      0xa1,
      0x61, 0x66, // "f"
      0xfa, 0x3f, 0xc0, 0x00, 0x00, // single 1.5
    ]);

    // { "f": half NaN (0x7e00) }
    parity('half NaN', [
      0xa1,
      0x61,
      0x66,
      0xf9,
      0x7e,
      0x00,
    ]);

    // { "f": half +Infinity (0x7c00) }
    parity('half Infinity', [
      0xa1,
      0x61,
      0x66,
      0xf9,
      0x7c,
      0x00,
    ]);

    // { "f": half subnormal smallest (0x0001) }
    parity('half subnormal', [
      0xa1,
      0x61,
      0x66,
      0xf9,
      0x00,
      0x01,
    ]);

    // { "s": extended simple value 200 (0xf8 0xc8) }
    parity('extended simple value', [
      0xa1,
      0x61, 0x73, // "s"
      0xf8, 0xc8,
    ]);

    // { "l": indefinite array [1, 2, 3] }
    parity('indefinite array', [
      0xa1,
      0x61, 0x6c, // "l"
      0x9f, 0x01, 0x02, 0x03, 0xff,
    ]);

    // { "m": indefinite map { "x": 1 } }
    parity('indefinite map', [
      0xa1,
      0x61, 0x6d, // "m"
      0xbf, 0x61, 0x78, 0x01, 0xff,
    ]);

    // indefinite top-level map { "k": "v" }
    parity('indefinite top-level map', [
      0xbf,
      0x61, 0x6b, // "k"
      0x61, 0x76, // "v"
      0xff,
    ]);

    // { "s": indefinite text string "hello" = "he"+"llo" }
    parity('indefinite text string', [
      0xa1,
      0x61, 0x73, // "s"
      0x7f,
      0x62, 0x68, 0x65, // "he"
      0x63, 0x6c, 0x6c, 0x6f, // "llo"
      0xff,
    ]);

    // { "b": indefinite byte string 0x0102 + 0x03 }
    parity('indefinite byte string', [
      0xa1,
      0x61, 0x62, // "b"
      0x5f,
      0x42, 0x01, 0x02,
      0x41, 0x03,
      0xff,
    ]);

    // { "n": tag(2) bignum-like bytes treated as skipped tag }
    parity('nested tag in array', [
      0xa1,
      0x61, 0x6e, // "n"
      0x82, 0xc2, 0x18, 0x2a, 0xf7, // [tag(2) 42, undefined]
    ]);
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
