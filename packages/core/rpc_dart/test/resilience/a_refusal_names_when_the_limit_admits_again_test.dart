// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// The pushback a rate-limit refusal carries is the time until the limiter
/// admits again: a caller that waits exactly that long is let in.
void main() {
  late RpcCallInfo call;
  var nowUs = 0;

  setUp(() {
    nowUs = 0;
    final (client, _) = RpcChannelTransport.memoryPair();
    final endpoint = RpcCallerEndpoint(transport: client);
    addTearDown(endpoint.close);
    call = RpcCallInfo(
      endpoint: endpoint,
      serviceName: 'S',
      methodName: 'M',
      context: RpcContext.empty(),
      direction: RpcCallDirection.incoming,
    );
  });

  /// Null when admitted, else the delay the refusal asks for.
  Future<Duration?> attempt(RpcRateLimiter limiter) async {
    try {
      await limiter.interceptUnary<int, int>(call, 0, (c, r) async => 0);
      return null;
    } on RpcRateLimitException catch (e) {
      return e.details.whereType<RpcRetryInfo>().single.retryDelay;
    }
  }

  for (final (name, limit) in [
    (
      'sliding window',
      RateLimit.slidingWindow(max: 2, window: const Duration(seconds: 1)),
    ),
    (
      'token bucket',
      RateLimit.tokenBucket(max: 2, window: const Duration(seconds: 1)),
    ),
  ]) {
    test('$name: waiting the pushback is enough', () async {
      final limiter = RpcRateLimiter(global: limit, nowMicros: () => nowUs);
      addTearDown(limiter.dispose);

      expect(await attempt(limiter), isNull);
      expect(await attempt(limiter), isNull);
      final wait = await attempt(limiter);
      expect(wait, isNotNull);

      nowUs += wait!.inMicroseconds;
      expect(await attempt(limiter), isNull);
    });
  }

  test(
    'sliding window: the pushback decays with the previous window',
    () async {
      final limiter = RpcRateLimiter(
        global: RateLimit.slidingWindow(
          max: 2,
          window: const Duration(seconds: 1),
        ),
        nowMicros: () => nowUs,
      );
      addTearDown(limiter.dispose);
      await attempt(limiter);
      await attempt(limiter);

      nowUs = 1500000;
      expect(await attempt(limiter), isNull);
      final wait = await attempt(limiter);
      expect(wait, isNotNull);
      expect(wait, lessThan(const Duration(milliseconds: 1)));

      nowUs += wait!.inMicroseconds;
      expect(await attempt(limiter), isNull);
    },
  );
}
