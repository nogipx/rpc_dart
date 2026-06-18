// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding: circuit breaker stuck half-open on an abandoned stream probe.
//
// For interceptServerStream/interceptBidirectionalStream, _checkState admits a
// half-open probe by setting _probeInFlight = true. Previously that flag was
// cleared only by the wrapped stream's handleError/handleDone, which run ONLY
// when the RETURNED stream is listened. If the caller obtains the wrapped
// stream but never listens (abandons it), _probeInFlight stayed true forever
// and the breaker rejected every subsequent call in half-open.
//
// FIX: the source is subscribed to eagerly inside _wrapStream, so the probe
// gate is released on source termination regardless of whether the returned
// stream is consumed (plus a safety timer for sources that never complete).
//
// CONFIRMED-FIXED if, after admitting a probe whose wrapped stream is never
// listened and whose source completes, a subsequent call is admitted (not
// rejected forever).

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('CircuitBreaker abandoned half-open stream probe', () {
    late RpcMiddlewareContext callContext;

    setUp(() {
      final (clientTransport, _) = RpcChannelTransport.memoryPair();
      final endpoint = RpcCallerEndpoint(transport: clientTransport);
      callContext = RpcMiddlewareContext(
        endpoint: endpoint,
        serviceName: 'TestService',
        methodName: 'TestMethod',
        context: RpcContext.empty(),
      );
    });

    Future<void> tripToOpen(RpcCircuitBreakerInterceptor cb) async {
      try {
        await cb.interceptUnary<String, String>(
          callContext,
          'req',
          (ctx, req) async => throw RpcException('fail'),
        );
      } on RpcException {
        // expected
      }
    }

    test('releases probe when an abandoned stream source completes', () async {
      final cb = RpcCircuitBreakerInterceptor(
        failureThreshold: 1,
        resetTimeout: const Duration(milliseconds: 20),
      );

      await tripToOpen(cb);
      expect(cb.state, CircuitBreakerState.open);

      // Wait for the reset window so the next call transitions to half-open.
      await Future<void>.delayed(const Duration(milliseconds: 40));

      // Source completes cleanly but the returned stream is NEVER listened.
      final source = StreamController<String>();
      final probeStream = await cb.interceptServerStream<String, String>(
        callContext,
        'req',
        (ctx, req) async => source.stream,
      );
      // Intentionally do NOT listen `probeStream` (abandoned by the caller).
      expect(probeStream, isA<Stream<String>>());
      expect(cb.state, CircuitBreakerState.halfOpen);

      // Complete the source. With the fix, eager subscription observes the done
      // event and releases the probe gate even though nobody listened.
      source.add('x');
      await source.close();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Probe resolved successfully -> circuit should be closed and admit work.
      expect(
        cb.state,
        CircuitBreakerState.closed,
        reason: 'abandoned probe must be released on source completion',
      );

      // A subsequent unary call must be admitted (not rejected forever).
      final result = await cb.interceptUnary<String, String>(
        callContext,
        'req',
        (ctx, req) async => 'ok',
      );
      expect(result, 'ok');
      expect(cb.state, CircuitBreakerState.closed);
    });

    test('counts failures from an abandoned failing stream probe', () async {
      final cb = RpcCircuitBreakerInterceptor(
        failureThreshold: 1,
        resetTimeout: const Duration(milliseconds: 20),
      );

      await tripToOpen(cb);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      // Abandoned probe whose source errors -> must reopen the breaker.
      final probeStream = await cb.interceptServerStream<String, String>(
        callContext,
        'req',
        (ctx, req) => Stream<String>.error(RpcException('probe failure')),
      );
      // Do not listen.
      expect(cb.state, CircuitBreakerState.halfOpen);

      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(
        cb.state,
        CircuitBreakerState.open,
        reason:
            'abandoned failing probe must be counted and reopen the breaker',
      );

      // Avoid an unawaited-stream lint by referencing it.
      expect(probeStream, isA<Stream<String>>());
    });

    test(
      'safety timer releases probe when abandoned source never completes',
      () async {
        final cb = RpcCircuitBreakerInterceptor(
          failureThreshold: 1,
          resetTimeout: const Duration(milliseconds: 20),
          probeAbandonTimeout: const Duration(milliseconds: 30),
        );

        await tripToOpen(cb);
        await Future<void>.delayed(const Duration(milliseconds: 40));

        // Source never completes and the returned stream is never listened.
        final source = StreamController<String>();
        addTearDown(source.close);
        final probeStream = await cb.interceptServerStream<String, String>(
          callContext,
          'req',
          (ctx, req) async => source.stream,
        );
        expect(cb.state, CircuitBreakerState.halfOpen);

        // After the abandon timeout, the gate is force-released.
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(
          cb.state,
          CircuitBreakerState.closed,
          reason: 'abandon safety timer must release a wedged half-open probe',
        );

        expect(probeStream, isA<Stream<String>>());
      },
    );
  });
}
