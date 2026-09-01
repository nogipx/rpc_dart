// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// _checkState() admits exactly one half-open probe by setting
// _probeInFlight = true, and the gate is cleared by _onSuccess (probe worked,
// close) or _onFailure (probe failed, reopen). But _onFailure returned early
// for outcomes it does not count -- a cancellation, or anything the caller's
// failureOn predicate rejects -- without clearing the gate. If such an outcome
// belonged to the admitted probe, the breaker stayed halfOpen with the gate
// pinned, so every later call was rejected with CircuitBreakerOpenException
// forever and only a manual reset() could clear it. Cancelled calls are
// ordinary (deadline, caller navigated away), so this wedged live clients.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('CircuitBreaker inconclusive half-open probe', () {
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

    Future<void> trip(RpcCircuitBreakerInterceptor cb) async {
      await expectLater(
        cb.interceptUnary<String, String>(
          callContext,
          'req',
          (ctx, req) async => throw RpcException('fail'),
        ),
        throwsA(isA<RpcException>()),
      );
      expect(cb.state, CircuitBreakerState.open);
    }

    test('a cancelled probe releases the gate for the next call', () async {
      final cb = RpcCircuitBreakerInterceptor(
        failureThreshold: 1,
        resetTimeout: const Duration(milliseconds: 10),
      );
      await trip(cb);
      await Future<void>.delayed(const Duration(milliseconds: 25));

      // This call is admitted as the probe, then cancelled: inconclusive.
      await expectLater(
        cb.interceptUnary<String, String>(
          callContext,
          'req',
          (ctx, req) async => throw const RpcCancelledException('cancelled'),
        ),
        throwsA(isA<RpcCancelledException>()),
      );

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

    test('a failureOn-rejected probe releases the gate too', () async {
      final cb = RpcCircuitBreakerInterceptor(
        failureThreshold: 1,
        resetTimeout: const Duration(milliseconds: 10),
        // Only transport-ish errors count; app errors are ignored.
        failureOn: (e) => e is RpcException && e.message == 'fail',
      );
      await trip(cb);
      await Future<void>.delayed(const Duration(milliseconds: 25));

      await expectLater(
        cb.interceptUnary<String, String>(
          callContext,
          'req',
          (ctx, req) async => throw RpcException('ignored-by-predicate'),
        ),
        throwsA(isA<RpcException>()),
      );

      expect(cb.state, CircuitBreakerState.halfOpen);

      final result = await cb.interceptUnary<String, String>(
        callContext,
        'req',
        (ctx, req) async => 'ok',
      );
      expect(result, 'ok');
      expect(cb.state, CircuitBreakerState.closed);
    });
  });
}
