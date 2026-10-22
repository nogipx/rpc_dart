// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// VM-only: the colliding-key construction reproduces the VM's String.hashCode;
// dart2js hashes differently, so these keys would not collide there. The salt
// in the store is platform-agnostic.
@TestOn('vm')
library;

// The per-key store keys by a SALTED hash of the attacker-controlled userKey,
// so a flood of keys that share one String.hashCode no longer makes every
// lookup walk a long chain (round 888 measured 222x before the salt). These
// guard the new _KeyedLruStore's correctness: colliding keys must still get
// independent limits, and LRU eviction must still hold across them.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

const _userId = RpcContextKey<String>('userId');

// Two distinct strings that share one String.hashCode (the VM's unseeded OAAT
// hash). Found by the per-slot state-collision construction.
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

void main() {
  late RpcCallerEndpoint endpoint;
  setUp(() {
    final (clientTransport, _) = RpcChannelTransport.memoryPair();
    endpoint = RpcCallerEndpoint(transport: clientTransport);
  });

  Future<void> hit(RpcRateLimiter limiter, String key) {
    final c = RpcCallInfo(
      endpoint: endpoint,
      serviceName: 'S',
      methodName: 'M',
      context: RpcContext.empty().withValue(_userId, key),
      direction: RpcCallDirection.incoming,
    );
    return limiter.interceptUnary<String, String>(
      c,
      'req',
      (ctx, r) async => 'ok',
    );
  }

  test('keys that share a hashCode get independent limits', () async {
    final keys = _collidingKeys(4);
    expect(
      keys.map((k) => k.hashCode).toSet(),
      hasLength(1),
      reason: 'the construction must collide, or the test is vacuous',
    );
    final limiter = RpcRateLimiter(
      perKeyFallback: RateLimit.slidingWindow(
        max: 1,
        window: const Duration(minutes: 1),
      ),
      keyExtractor: (c) => c.context.getValue(_userId),
      clock: () => DateTime.fromMicrosecondsSinceEpoch(1000000),
    );
    addTearDown(limiter.dispose);

    // Each colliding key spends its single allowance, independently.
    for (final k in keys) {
      await hit(limiter, k);
    }
    // Every one is now at its own limit -- not merged into a shared counter.
    for (final k in keys) {
      await expectLater(
        hit(limiter, k),
        throwsA(isA<RpcRateLimitException>()),
        reason: 'key $k must keep its own counter',
      );
    }
  });

  test('LRU eviction holds across colliding keys', () async {
    final keys = _collidingKeys(2000); // all share one hashCode
    final limiter = RpcRateLimiter(
      perKeyFallback: RateLimit.slidingWindow(
        max: 1,
        window: const Duration(minutes: 1),
      ),
      keyExtractor: (c) => c.context.getValue(_userId),
      clock: () => DateTime.fromMicrosecondsSinceEpoch(1000000),
      maxTrackedKeys: 1000, // smaller than the key set, so eviction happens
    );
    addTearDown(limiter.dispose);

    final oldest = keys.first;
    await hit(limiter, oldest);
    for (var i = 1; i < 2000; i++) {
      await hit(limiter, keys[i]);
    }
    // oldest was evicted (LRU), so re-hitting gets a fresh counter: allowed.
    await hit(limiter, oldest); // must NOT throw
    // A recent key is still tracked and at its limit.
    await expectLater(
      hit(limiter, keys[1999]),
      throwsA(isA<RpcRateLimitException>()),
    );
  });
}
