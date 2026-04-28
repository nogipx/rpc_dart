// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RpcCircuitBreakerInterceptor', () {
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

    test('starts in closed state', () {
      final cb = RpcCircuitBreakerInterceptor();
      expect(cb.state, CircuitBreakerState.closed);
      expect(cb.failureCount, 0);
    });

    test('passes through on success', () async {
      final cb = RpcCircuitBreakerInterceptor();

      final result = await cb.interceptUnary<String, String>(
        callContext,
        'req',
        (ctx, req) async => 'ok',
      );

      expect(result, 'ok');
      expect(cb.state, CircuitBreakerState.closed);
    });

    test('opens after failureThreshold consecutive failures', () async {
      final cb = RpcCircuitBreakerInterceptor(failureThreshold: 3);

      for (var i = 0; i < 3; i++) {
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

      expect(cb.state, CircuitBreakerState.open);
      expect(cb.failureCount, 3);
    });

    test('rejects calls immediately when open', () async {
      final cb = RpcCircuitBreakerInterceptor(
        failureThreshold: 1,
        resetTimeout: Duration(seconds: 60),
      );

      // Trip the breaker.
      try {
        await cb.interceptUnary<String, String>(
          callContext,
          'req',
          (ctx, req) async => throw RpcException('fail'),
        );
      } on RpcException {
        // expected
      }

      expect(cb.state, CircuitBreakerState.open);

      // Next call should fail immediately.
      try {
        await cb.interceptUnary<String, String>(
          callContext,
          'req',
          (ctx, req) async => 'should not reach',
        );
        fail('Should have thrown CircuitBreakerOpenException');
      } on CircuitBreakerOpenException catch (e) {
        expect(e.retryAfter, isNotNull);
      }
    });

    test('transitions to half-open after resetTimeout', () async {
      final cb = RpcCircuitBreakerInterceptor(
        failureThreshold: 1,
        resetTimeout: Duration(milliseconds: 50),
      );

      // Trip it.
      try {
        await cb.interceptUnary<String, String>(
          callContext,
          'req',
          (ctx, req) async => throw RpcException('fail'),
        );
      } on RpcException {
        // expected
      }
      expect(cb.state, CircuitBreakerState.open);

      // Wait for reset timeout.
      await Future.delayed(Duration(milliseconds: 80));

      // Next call should go through (half-open probe).
      final result = await cb.interceptUnary<String, String>(
        callContext,
        'req',
        (ctx, req) async => 'recovered',
      );

      expect(result, 'recovered');
      expect(cb.state, CircuitBreakerState.closed);
    });

    test('half-open probe failure reopens circuit', () async {
      final cb = RpcCircuitBreakerInterceptor(
        failureThreshold: 1,
        resetTimeout: Duration(milliseconds: 50),
      );

      // Trip it.
      try {
        await cb.interceptUnary<String, String>(
          callContext,
          'req',
          (ctx, req) async => throw RpcException('fail'),
        );
      } on RpcException {
        // expected
      }

      await Future.delayed(Duration(milliseconds: 80));

      // Probe fails.
      try {
        await cb.interceptUnary<String, String>(
          callContext,
          'req',
          (ctx, req) async => throw RpcException('still failing'),
        );
      } on RpcException {
        // expected
      }

      expect(cb.state, CircuitBreakerState.open);
    });

    test('success resets failure count', () async {
      final cb = RpcCircuitBreakerInterceptor(failureThreshold: 3);

      // 2 failures.
      for (var i = 0; i < 2; i++) {
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
      expect(cb.failureCount, 2);

      // 1 success resets count.
      await cb.interceptUnary<String, String>(
        callContext,
        'req',
        (ctx, req) async => 'ok',
      );
      expect(cb.failureCount, 0);
      expect(cb.state, CircuitBreakerState.closed);
    });

    test('cancellation does not count as failure', () async {
      final cb = RpcCircuitBreakerInterceptor(failureThreshold: 1);

      try {
        await cb.interceptUnary<String, String>(
          callContext,
          'req',
          (ctx, req) async => throw const RpcCancelledException('cancelled'),
        );
      } on RpcCancelledException {
        // expected
      }

      expect(cb.state, CircuitBreakerState.closed);
      expect(cb.failureCount, 0);
    });

    test('custom failureOn predicate', () async {
      final cb = RpcCircuitBreakerInterceptor(
        failureThreshold: 1,
        failureOn: (e) => e is RpcException && e.message == 'critical',
      );

      // Non-critical error — not counted.
      try {
        await cb.interceptUnary<String, String>(
          callContext,
          'req',
          (ctx, req) async => throw RpcException('minor'),
        );
      } on RpcException {
        // expected
      }
      expect(cb.state, CircuitBreakerState.closed);

      // Critical error — counted.
      try {
        await cb.interceptUnary<String, String>(
          callContext,
          'req',
          (ctx, req) async => throw RpcException('critical'),
        );
      } on RpcException {
        // expected
      }
      expect(cb.state, CircuitBreakerState.open);
    });

    test('manual reset', () async {
      final cb = RpcCircuitBreakerInterceptor(failureThreshold: 1);

      try {
        await cb.interceptUnary<String, String>(
          callContext,
          'req',
          (ctx, req) async => throw RpcException('fail'),
        );
      } on RpcException {
        // expected
      }
      expect(cb.state, CircuitBreakerState.open);

      cb.reset();
      expect(cb.state, CircuitBreakerState.closed);
      expect(cb.failureCount, 0);
    });
  });
}
