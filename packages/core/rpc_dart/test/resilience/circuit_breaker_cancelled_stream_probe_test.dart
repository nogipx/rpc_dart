// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A half-open probe taken by interceptServerStream/interceptBidirectionalStream
// is released when the SOURCE terminates (onDone/onError) or, for a stream
// nobody listened, by the abandon timer. A consumer that listens and then
// cancels -- `stream.first`, `take(n)`, a disposed widget -- hits neither:
// onListen cancels the abandon timer, and a cancelled subscription never
// delivers onDone. The gate stayed pinned and every later call on that breaker
// was rejected with CircuitBreakerOpenException forever.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('CircuitBreaker cancelled half-open stream probe', () {
    late RpcCallerEndpoint endpoint;
    late RpcMiddlewareContext callContext;

    setUp(() {
      final (clientTransport, _) = RpcChannelTransport.memoryPair();
      endpoint = RpcCallerEndpoint(transport: clientTransport);
      callContext = RpcMiddlewareContext(
        endpoint: endpoint,
        serviceName: 'TestService',
        methodName: 'TestMethod',
        context: RpcContext.empty(),
      );
    });

    tearDown(() => endpoint.close());

    RpcCircuitBreakerInterceptor breaker() => RpcCircuitBreakerInterceptor(
      failureThreshold: 1,
      resetTimeout: const Duration(milliseconds: 20),
      // Far longer than the test: the abandon safety net must not be what
      // releases the gate here, or the witness would pass for the wrong reason.
      probeAbandonTimeout: const Duration(seconds: 30),
    );

    Future<void> tripToOpen(RpcCircuitBreakerInterceptor cb) async {
      await expectLater(
        cb.interceptUnary<String, String>(
          callContext,
          'req',
          (ctx, req) async => throw RpcException('trip'),
        ),
        throwsA(isA<RpcException>()),
      );
      expect(cb.state, CircuitBreakerState.open);
      // Let the reset window elapse so the next call is admitted as the probe.
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }

    /// A source that keeps producing, so only the consumer's cancel can end
    /// the subscription. Closed on teardown.
    StreamController<String> liveSource() {
      final source = StreamController<String>();
      final ticker = Timer.periodic(const Duration(milliseconds: 5), (t) {
        if (source.isClosed) {
          t.cancel();
          return;
        }
        source.add('tick');
      });
      addTearDown(() async {
        ticker.cancel();
        if (!source.isClosed) await source.close();
      });
      return source;
    }

    test('a cancelled server-stream probe releases the gate', () async {
      final cb = breaker();
      await tripToOpen(cb);

      final source = liveSource();
      final probe = await cb.interceptServerStream<String, String>(
        callContext,
        'req',
        (ctx, req) async => source.stream,
      );
      expect(cb.state, CircuitBreakerState.halfOpen);

      // The consumer takes one item and cancels.
      expect(await probe.first, 'tick');

      // The breaker must still be probing, not wedged shut.
      expect(cb.state, CircuitBreakerState.halfOpen);

      // The next call takes its turn as the probe and closes the circuit.
      final result = await cb.interceptUnary<String, String>(
        callContext,
        'req',
        (ctx, req) async => 'ok',
      );
      expect(result, 'ok');
      expect(cb.state, CircuitBreakerState.closed);
    });

    test('a cancelled bidirectional probe releases the gate', () async {
      final cb = breaker();
      await tripToOpen(cb);

      final source = liveSource();
      final probe = await cb.interceptBidirectionalStream<String, String>(
        callContext,
        const Stream<String>.empty(),
        (ctx, reqs) async => source.stream,
      );
      expect(cb.state, CircuitBreakerState.halfOpen);

      expect(await probe.first, 'tick');
      expect(cb.state, CircuitBreakerState.halfOpen);

      final result = await cb.interceptUnary<String, String>(
        callContext,
        'req',
        (ctx, req) async => 'ok',
      );
      expect(result, 'ok');
      expect(cb.state, CircuitBreakerState.closed);
    });

    // The guard: releasing on cancel must not swallow the outcomes that DO
    // decide the breaker's state. A probe drained to done still closes it.
    test('a drained probe still closes the breaker', () async {
      final cb = breaker();
      await tripToOpen(cb);

      final probe = await cb.interceptServerStream<String, String>(
        callContext,
        'req',
        (ctx, req) async => Stream<String>.fromIterable(['a', 'b']),
      );
      expect(await probe.toList(), ['a', 'b']);
      expect(cb.state, CircuitBreakerState.closed);
    });

    // The other half of the guard: a failing probe still reopens, even though
    // the consumer's cancel follows the error through the same onCancel hook.
    test('a failing probe still reopens the breaker', () async {
      final cb = breaker();
      await tripToOpen(cb);

      final probe = await cb.interceptServerStream<String, String>(
        callContext,
        'req',
        (ctx, req) async => Stream<String>.error(RpcException('probe failed')),
      );
      await expectLater(probe.first, throwsA(isA<RpcException>()));
      expect(cb.state, CircuitBreakerState.open);
    });
  });
}
