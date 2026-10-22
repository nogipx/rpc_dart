// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// VM-only: the colliding-key construction reproduces the VM's String.hashCode
// (an unseeded 30-bit one-at-a-time hash). dart2js hashes strings differently,
// so these keys would not collide there. The cap itself is platform-agnostic.
@TestOn('vm')
library;

// A peer can precompute keys that share one String.hashCode -- the VM's hash
// is an unseeded one-at-a-time hash -- and Dart's Map compares a new key
// against every resident key of equal hashCode. Many such keys in one map
// turn a decode within the item budget into O(n^2) work, before any
// interceptor runs. The decoder caps how many keys of one hashCode a map may
// carry and refuses the rest with a FormatException (RESOURCE_EXHAUSTED at the
// endpoint).

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

// The VM's String.hashCode, confirmed against the real value below: a 30-bit
// one-at-a-time hash. We build interchangeable equal-length blocks per slot so
// every assembled key shares one hashCode.
int _stateAfter(int h, String block) {
  for (final c in block.codeUnits) {
    h = (h + c) & 0xFFFFFFFF;
    h = (h + (h << 10)) & 0xFFFFFFFF;
    h ^= h >> 6;
  }
  return h;
}

List<String> _pairFrom(int start, int salt) {
  final seen = <int, String>{};
  const len = 6;
  final buf = List<int>.filled(len, 97);
  var counter = salt * 1000003;
  while (true) {
    var n = counter++;
    for (var i = 0; i < len; i++) {
      buf[i] = 97 + (n % 26);
      n ~/= 26;
    }
    final s = String.fromCharCodes(buf);
    final st = _stateAfter(start, s);
    final prev = seen[st];
    if (prev != null && prev != s) return [prev, s];
    seen[st] = s;
  }
}

/// [count] distinct strings that all share one `String.hashCode`.
List<String> _collidingKeys(int count) {
  final slots = (count - 1).bitLength < 1 ? 1 : (count - 1).bitLength;
  final pairs = <List<String>>[];
  var state = 0;
  for (var b = 0; b < slots; b++) {
    final p = _pairFrom(state, b);
    pairs.add(p);
    state = _stateAfter(state, p[0]);
  }
  return [
    for (var i = 0; i < count; i++)
      [
        for (var b = 0; b < slots; b++)
          (i >> b) & 1 == 0 ? pairs[b][0] : pairs[b][1],
      ].join(),
  ];
}

Uint8List _encodeKeys(List<String> keys) =>
    RpcCborCodec.encode({for (final k in keys) k: 0});

void main() {
  group('a map of keys sharing one hashCode is refused', () {
    test('the construction really collides (guards against a hash change)', () {
      // If the VM's String.hashCode ever changes, this fails loudly rather
      // than letting the rest of the file pass on keys that no longer collide.
      final keys = _collidingKeys(100);
      expect(keys.toSet(), hasLength(100), reason: 'keys must be distinct');
      expect(
        keys.map((k) => k.hashCode).toSet(),
        hasLength(1),
        reason: 'all keys must share one hashCode',
      );
    });

    test('a map past the cap is refused, and cheaply', () {
      // The cap fires on the 17th key of one hashCode, so a map of any larger
      // size refuses after reading those few keys -- it never builds the
      // quadratic chain. 2000 keys is well past the cap and builds fast.
      final bytes = _encodeKeys(_collidingKeys(2000));
      final sw = Stopwatch()..start();
      expect(
        () => RpcCborCodec.decode(bytes),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('keys of one hashCode'),
          ),
        ),
      );
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(200));
    });

    test('16 keys of one hashCode are allowed, the 17th is not', () {
      // Small maps skip the tracking, so add distinct filler to put the map
      // past the tracking threshold and exercise the per-hashCode cap itself.
      final colliding = _collidingKeys(17);
      final filler = List.generate(80, (i) => 'filler_$i');
      expect(
        RpcCborCodec.decode(_encodeKeys([...colliding.take(16), ...filler])),
        hasLength(96),
      );
      expect(
        () => RpcCborCodec.decode(_encodeKeys([...colliding, ...filler])),
        throwsA(isA<FormatException>()),
      );
    });

    test('GUARD a large map of distinct keys still decodes', () {
      final keys = List.generate(5000, (i) => 'field_$i');
      final decoded = RpcCborCodec.decode(_encodeKeys(keys));
      expect(decoded, hasLength(5000));
    });

    test('GUARD an ordinary small map round-trips', () {
      const value = {
        'a': 1,
        'b': 'two',
        'c': true,
        'nested': {'x': 10},
      };
      expect(RpcCborCodec.decode(RpcCborCodec.encode(value)), value);
    });
  });
}
