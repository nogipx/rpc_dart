// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Feature #2: in halfOpen, only ONE probe may be admitted. Concurrent probes
// must be rejected (CircuitBreakerOpenException) until the in-flight probe
// resolves to success (close) or failure (reopen).

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('CircuitBreaker single-probe half-open', () {
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

    test('admits exactly one concurrent probe in halfOpen', () async {
      final cb = RpcCircuitBreakerInterceptor(
        failureThreshold: 1,
        resetTimeout: const Duration(milliseconds: 30),
      );

      await trip(cb);
      expect(cb.state, CircuitBreakerState.open);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // First call transitions to halfOpen and is admitted as the single probe.
      // We keep it pending via an uncompleted completer so we can launch a
      // second concurrent call while the probe is still in flight.
      final probeGate = Completer<String>();
      final probe = cb.interceptUnary<String, String>(
        callContext,
        'req',
        (ctx, req) => probeGate.future,
      );

      expect(cb.state, CircuitBreakerState.halfOpen);

      // Second concurrent call must be rejected while the probe is in flight.
      await expectLater(
        cb.interceptUnary<String, String>(
          callContext,
          'req',
          (ctx, req) async => 'should-not-run',
        ),
        throwsA(isA<CircuitBreakerOpenException>()),
      );

      // Resolve the probe successfully -> circuit closes.
      probeGate.complete('ok');
      expect(await probe, 'ok');
      expect(cb.state, CircuitBreakerState.closed);
    });

    test('probe failure releases the gate and reopens', () async {
      final cb = RpcCircuitBreakerInterceptor(
        failureThreshold: 1,
        resetTimeout: const Duration(milliseconds: 30),
      );

      await trip(cb);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Admitted probe fails -> reopen.
      try {
        await cb.interceptUnary<String, String>(
          callContext,
          'req',
          (ctx, req) async => throw RpcException('probe fail'),
        );
      } on RpcException {
        // expected
      }
      expect(cb.state, CircuitBreakerState.open);

      // After another reset window, a fresh probe is admitted again.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final result = await cb.interceptUnary<String, String>(
        callContext,
        'req',
        (ctx, req) async => 'recovered',
      );
      expect(result, 'recovered');
      expect(cb.state, CircuitBreakerState.closed);
    });
  });
}
