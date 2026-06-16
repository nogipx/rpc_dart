// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding 2: Circuit breaker is a no-op for STREAMING RPCs.
//
// circuit_breaker_interceptor.dart:108-110 (interceptServerStream) and
// 144-146 (interceptBidirectionalStream):
//
//   final stream = await next(call.context, request);
//   _onSuccess();            // <-- called as soon as the Stream object exists
//   return stream;
//
// next() returns the Stream synchronously (cold stream). Errors are emitted
// LATER, while the consumer listens. By then _onSuccess() has already run and
// reset the failure count. Errors that flow through the returned stream are
// never routed to _onFailure(), so the breaker never opens for server/bidi
// streaming RPCs, no matter how many stream errors occur.
//
// CONFIRMED if, after draining N failing streams (N >= failureThreshold), the
// breaker state is still NOT open.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('CircuitBreaker streaming failure accounting', () {
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

    test('opens after server-stream RPCs that emit errors', () async {
      final cb = RpcCircuitBreakerInterceptor(failureThreshold: 3);

      for (var i = 0; i < 5; i++) {
        final stream = await cb.interceptServerStream<String, String>(
          callContext,
          'req',
          // next() returns a cold stream that errors when listened to.
          (ctx, req) => Stream<String>.error(RpcException('stream failure')),
        );

        // Consume the stream; the error surfaces here.
        try {
          await stream.toList();
        } catch (_) {
          // expected error from the failing stream
        }
      }

      // Correct behavior: 5 failing streams (> threshold 3) must open the
      // breaker. If the breaker treats stream creation as instant success,
      // this assertion fails -> bug CONFIRMED.
      expect(
        cb.state,
        CircuitBreakerState.open,
        reason: 'breaker must count errors emitted by the returned stream; '
            'it currently calls _onSuccess() before any item is produced',
      );
      expect(cb.failureCount, greaterThanOrEqualTo(3));
    });

    test('opens after bidi-stream RPCs that emit errors', () async {
      final cb = RpcCircuitBreakerInterceptor(failureThreshold: 3);

      for (var i = 0; i < 5; i++) {
        final stream = await cb.interceptBidirectionalStream<String, String>(
          callContext,
          const Stream<String>.empty(),
          (ctx, reqs) => Stream<String>.error(RpcException('bidi failure')),
        );
        try {
          await stream.toList();
        } catch (_) {
          // expected
        }
      }

      expect(
        cb.state,
        CircuitBreakerState.open,
        reason: 'bidi stream errors must be counted as failures',
      );
    });
  });
}
