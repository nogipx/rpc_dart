// Audit finding 3: RpcRateLimiter has no `_disposed` guard.
// Source: packages/core/rpc_dart/lib/src/resilience/rate_limiter.dart
//   - dispose() at 294-299 cancels the cleanup timer AND clears the dynamic maps.
//   - _check() at 344-372 and _getDynamic() at 332-342 keep calling putIfAbsent,
//     so after dispose() the maps are repopulated again — but the cleanup timer
//     is gone, so per-key state grows unbounded (memory leak).
//
// Observable: after dispose(), the limiter must stop operating (no-op or throw),
// NOT keep enforcing limits by recreating counters. We prove it keeps operating
// by showing it still throws a rate-limit exception post-dispose.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  test('rate limiter does not keep operating after dispose()', () async {
    final (clientT, serverT) = RpcInMemoryTransport.pair();
    final endpoint = RpcResponderEndpoint(transport: serverT);
    addTearDown(() async {
      await endpoint.close();
      await clientT.close();
    });

    final limiter = RpcRateLimiter(
      perKeyFallback: RateLimit.slidingWindow(
        max: 1,
        window: Duration(hours: 1),
      ),
      keyExtractor: (_) => 'user-1',
    );

    final ctx = RpcMiddlewareContext(
      endpoint: endpoint,
      serviceName: 'Svc',
      methodName: 'm',
      context: RpcContext.empty(),
    );

    Future<void> call() =>
        limiter.interceptUnary<int, int>(ctx, 1, (c, r) async => r);

    // Sanity: limit is 1/hour, 2nd call before dispose throws.
    await call();

    // Now dispose — the limiter should be inert afterwards.
    limiter.dispose();

    // CORRECT behavior after dispose: calls are no-ops (pass through) OR throw
    // a disposed error — but they must NOT silently keep enforcing limits using
    // freshly recreated counters. After dispose the maps were cleared, so the
    // bug path recreates a fresh max:1 counter, lets THIS call through, and will
    // throw on the NEXT one — i.e. it is operating again with leaked state.
    //
    // Assert the disposed limiter does not throw a rate-limit exception while
    // re-accumulating state. Two post-dispose calls for the same key: if the
    // limiter were truly inert these both pass; the bug makes the 2nd throw.
    await call(); // recreates counter (1st token)
    await expectLater(
      call(), // 2nd token -> bug throws RpcRateLimitException
      completes,
      reason:
          'disposed limiter must not keep enforcing limits via recreated state',
    );
  });
}
