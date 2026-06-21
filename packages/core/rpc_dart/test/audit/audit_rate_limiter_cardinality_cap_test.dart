// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Regression guard (audit R2): the per-key dynamic counter maps are bounded by
// maxTrackedKeys with LRU eviction, so an attacker-controlled keyExtractor
// cannot grow them without limit (memory-exhaustion DoS).
//
// Fix: _getDynamic evicts the least-recently-used key when the cap is reached.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  test('R2: dynamic key map is capped with LRU eviction', () async {
    const fixedNow = 1000000;
    final limiter = RpcRateLimiter(
      perMethod: {
        'S.M': RateLimit.slidingWindow(max: 1, window: const Duration(minutes: 1)),
      },
      keyExtractor: (c) => c.context.getValue<String>('userId'),
      nowMicros: () => fixedNow,
      maxTrackedKeys: 1000, // small cap so eviction is observable
    );
    addTearDown(limiter.dispose);

    final (clientTransport, _) = RpcChannelTransport.memoryPair();
    final endpoint = RpcCallerEndpoint(transport: clientTransport);

    Future<void> hit(String key) {
      final c = RpcMiddlewareContext(
        endpoint: endpoint,
        serviceName: 'S',
        methodName: 'M',
        context: RpcContext.empty().withValue('userId', key),
      );
      return limiter.interceptUnary<String, String>(c, 'req', (ctx, r) async => 'ok');
    }

    // user-0 is the oldest. Then 1999 more distinct keys (total 2000 > cap 1000).
    await hit('user-0');
    for (var i = 1; i < 2000; i++) {
      await hit('user-$i');
    }

    // user-0 was evicted (LRU) once the cap was exceeded, so its limit-1 counter
    // is gone: re-hitting it gets a FRESH counter and is allowed (no throw).
    await hit('user-0'); // must NOT throw -> proves eviction happened

    // A recent key is still tracked, so its limit is still enforced.
    await expectLater(
      hit('user-1999'),
      throwsA(isA<RpcRateLimitException>()),
      reason: 'recently-used keys remain tracked and rate-limited',
    );
  });
}
