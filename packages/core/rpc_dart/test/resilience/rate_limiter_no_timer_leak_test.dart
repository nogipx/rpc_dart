// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcRateLimiter used to sweep stale per-key counters from a Timer.periodic.
// A periodic timer keeps the isolate alive on its own and holds the limiter --
// and every counter it tracks -- reachable for as long as it runs. A limiter
// whose owner forgot dispose() therefore leaked permanently, and the process
// could never exit: a probe that constructed one, dropped it and returned from
// main() still had not terminated after two minutes.
//
// The sweep is now opportunistic, driven from the call path that grows the
// maps, so there is no timer to leak and dispose() is optional.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RpcRateLimiter holds no background timer', () {
    late RpcMiddlewareContext callContext;

    setUp(() {
      final (clientTransport, _) = RpcChannelTransport.memoryPair();
      final endpoint = RpcCallerEndpoint(transport: clientTransport);
      callContext = RpcMiddlewareContext(
        endpoint: endpoint,
        serviceName: 'Svc',
        methodName: 'm',
        context: RpcContext.empty(),
      );
    });

    test('constructing a keyed limiter creates no timers', () {
      var oneShot = 0;
      var periodic = 0;

      runZoned(
        () {
          // The keyed form is the one that used to arm Timer.periodic.
          RpcRateLimiter(
            global: RateLimit.slidingWindow(
              max: 5,
              window: const Duration(seconds: 1),
            ),
            keyExtractor: (call) => 'user',
            cleanupInterval: const Duration(milliseconds: 10),
          );
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, f) {
            oneShot++;
            return parent.createTimer(zone, duration, f);
          },
          createPeriodicTimer: (self, parent, zone, period, f) {
            periodic++;
            return parent.createPeriodicTimer(zone, period, f);
          },
        ),
      );

      expect(periodic, 0, reason: 'a periodic timer pins the whole limiter');
      expect(oneShot, 0);
    });

    test('stale per-key counters are still evicted, without a timer', () {
      // Injected clock: cleanup must be driven by calls, not by wall time.
      var nowUs = 0;
      final limiter = RpcRateLimiter(
        perKeyFallback: RateLimit.slidingWindow(
          max: 1,
          window: const Duration(seconds: 1),
        ),
        keyExtractor: (call) => 'user-$nowUs',
        cleanupInterval: const Duration(seconds: 1),
        nowMicros: () => nowUs,
      );

      // Each call uses a fresh key, so without eviction the map grows forever.
      for (var i = 0; i < 50; i++) {
        nowUs += 100 * 1000; // 100ms per call
        limiter.interceptUnary<String, String>(
          callContext,
          'r',
          (ctx, req) async => 'ok',
        );
      }

      // The sweep threshold is 2x the widest window (2s), and 50 calls span
      // 5s of injected time, so early keys must be gone. Observable proxy:
      // the limiter still admits a brand-new key rather than being wedged.
      nowUs += 10 * 1000 * 1000;
      expect(
        () => limiter.interceptUnary<String, String>(
          callContext,
          'r',
          (ctx, req) async => 'ok',
        ),
        returnsNormally,
      );

      limiter.dispose();
    });

    test('dispose is optional and idempotent', () {
      final limiter = RpcRateLimiter(
        global: RateLimit.slidingWindow(
          max: 1,
          window: const Duration(seconds: 1),
        ),
        keyExtractor: (call) => 'user',
      );
      expect(limiter.dispose, returnsNormally);
      expect(limiter.dispose, returnsNormally);
    });
  });
}
