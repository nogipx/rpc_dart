// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The circuit breaker judged a call's outcome by the state it was in when the
// call ENDED, not the one it was admitted in. A call admitted while closed and
// still running when the breaker opened, half-opened and admitted its probe
// was then taken for the probe:
//
//   - its success CLOSED the breaker while the real probe was in flight;
//   - its cancellation, or an uncounted error, freed the gate and a second
//     probe got in;
//   - its counted failure reopened the breaker and restarted the timer, and
//     the real probe's success then landed in OPEN and was dropped.
//
// A long-lived stream admitted as the probe held the gate for its whole life,
// rejecting every other call; and the abandon timer cancelled a stream nobody
// had listened to yet and left it open, so a late listener waited forever.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  late RpcMiddlewareContext ctx;

  setUp(() {
    final (client, _) = RpcChannelTransport.memoryPair();
    final endpoint = RpcCallerEndpoint(transport: client);
    addTearDown(endpoint.close);
    ctx = RpcMiddlewareContext(
      endpoint: endpoint,
      serviceName: 'S',
      methodName: 'M',
      context: RpcContext.empty(),
    );
  });

  Future<void> fail(RpcCircuitBreakerInterceptor cb) => cb
      .interceptUnary<String, String>(
        ctx,
        'r',
        (c, r) async => throw RpcStatusException(RpcStatus.unavailable, 'down'),
      )
      .then((_) {}, onError: (Object _) {});

  Future<String> tryCall(RpcCircuitBreakerInterceptor cb) => cb
      .interceptUnary<String, String>(ctx, 'r', (c, r) async => 'ok')
      .then(
        (_) => 'admitted',
        onError: (Object e) =>
            e is CircuitBreakerOpenException ? 'rejected' : 'error',
      );

  group('a call admitted while closed ends during the probe', () {
    /// Starts a stale call, trips the breaker, admits a probe, then ends the
    /// stale call with [stale]. Returns the breaker and the probe's gate.
    Future<(RpcCircuitBreakerInterceptor, Completer<String>, Future<void>)>
    staleDuringProbe(Object stale) async {
      final cb = RpcCircuitBreakerInterceptor(
        failureThreshold: 2,
        resetTimeout: const Duration(milliseconds: 30),
      );
      final staleGate = Completer<String>();
      final staleCall = cb
          .interceptUnary<String, String>(ctx, 'r', (c, r) => staleGate.future)
          .then((_) {}, onError: (Object _) {});
      await fail(cb);
      await fail(cb);
      expect(cb.state, CircuitBreakerState.open);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final probeGate = Completer<String>();
      final probe = cb
          .interceptUnary<String, String>(ctx, 'r', (c, r) => probeGate.future)
          .then((_) {}, onError: (Object _) {});
      expect(cb.state, CircuitBreakerState.halfOpen);

      if (stale is String) {
        staleGate.complete(stale);
      } else {
        staleGate.completeError(stale);
      }
      await staleCall;
      return (cb, probeGate, probe);
    }

    final outcomes = <String, Object>{
      'success': 'late',
      'cancellation': const RpcCancelledException('caller left'),
      'uncounted error': RpcStatusException(RpcStatus.notFound, 'nf'),
      'counted failure': RpcStatusException(RpcStatus.internal, 'boom'),
    };
    for (final MapEntry(key: name, value: stale) in outcomes.entries) {
      test('$name: only the probe decides', () async {
        final (cb, probeGate, probe) = await staleDuringProbe(stale);

        expect(cb.state, CircuitBreakerState.halfOpen);
        expect(await tryCall(cb), 'rejected', reason: 'one probe at a time');

        probeGate.complete('p');
        await probe;
        expect(cb.state, CircuitBreakerState.closed);
      });
    }
  });

  test(
    'a long-lived stream probe frees the gate at its first message',
    () async {
      final cb = RpcCircuitBreakerInterceptor(
        failureThreshold: 1,
        resetTimeout: const Duration(milliseconds: 20),
      );
      await fail(cb);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      final feed = StreamController<String>();
      addTearDown(feed.close);
      final probe = await cb.interceptServerStream<String, String>(
        ctx,
        'r',
        (c, r) async => feed.stream,
      );
      final received = <String>[];
      final sub = probe.listen(received.add);
      addTearDown(sub.cancel);
      feed.add('m1');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(received, ['m1']);
      expect(cb.state, CircuitBreakerState.closed);
      expect(await tryCall(cb), 'admitted');
    },
  );

  test('a stream nobody listened to in time ends with an error', () async {
    final cb = RpcCircuitBreakerInterceptor(
      probeAbandonTimeout: const Duration(milliseconds: 30),
    );
    final source = StreamController<String>();
    addTearDown(source.close);
    final stream = await cb.interceptServerStream<String, String>(
      ctx,
      'r',
      (c, r) async => source.stream,
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));

    await expectLater(
      stream.toList().timeout(const Duration(seconds: 1)),
      throwsA(isA<RpcCancelledException>()),
    );
  });
}
