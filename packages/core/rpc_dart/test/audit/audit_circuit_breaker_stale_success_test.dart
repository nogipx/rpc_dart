// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Regression guard (audit R1): a success from a call that began while the
// breaker was CLOSED must NOT re-close a breaker that other concurrent calls
// have since OPENED.
//
// Fix: _onSuccess() is state-aware — it only closes from halfOpen (the admitted
// probe); a success observed while open is stale and is ignored. This test
// FAILED before the fix (breaker came back closed).

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('R1: circuit breaker stale-success reset', () {
    late RpcMiddlewareContext ctx;

    setUp(() {
      final (clientTransport, _) = RpcChannelTransport.memoryPair();
      final endpoint = RpcCallerEndpoint(transport: clientTransport);
      ctx = RpcMiddlewareContext(
        endpoint: endpoint,
        serviceName: 'S',
        methodName: 'M',
        context: RpcContext.empty(),
      );
    });

    test(
      'a stale success must not re-close a breaker opened by other calls',
      () async {
        final cb = RpcCircuitBreakerInterceptor(failureThreshold: 3);

        // 1. A slow call passes _checkState() while CLOSED, then parks on a gate.
        final slowGate = Completer<String>();
        final slow = cb.interceptUnary<String, String>(
          ctx,
          'req',
          (c, r) => slowGate.future,
        );

        // 2. Three failing calls (all start while closed) trip the breaker.
        for (var i = 0; i < 3; i++) {
          try {
            await cb.interceptUnary<String, String>(
              ctx,
              'req',
              (c, r) async => throw RpcException('fail'),
            );
          } on RpcException {
            // expected
          }
        }
        expect(
          cb.state,
          CircuitBreakerState.open,
          reason: 'breaker should be open after 3 failures',
        );

        // 3. The stale success now resolves.
        slowGate.complete('ok');
        expect(await slow, 'ok');

        // CORRECT behavior: the breaker stays OPEN — a success from a call that
        // began before the breaker opened proves nothing about recovery.
        // If R1 is real, the breaker is wrongly back to CLOSED here.
        expect(
          cb.state,
          CircuitBreakerState.open,
          reason: 'a stale success must not re-close an open breaker',
        );
      },
    );
  });
}
