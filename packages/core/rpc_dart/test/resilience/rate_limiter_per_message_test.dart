// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Feature #1: per-message accounting for streaming RPCs.
//
// Default changed: every message on a rate-limited streaming method counts
// against the limit (previously one token per stream open). When the limit is
// exceeded mid-stream the wrapped stream emits an RpcRateLimitException error
// (RESOURCE_EXHAUSTED), consistent with the unary path.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RpcRateLimiter per-message stream accounting', () {
    late RpcMiddlewareContext callContext;

    setUp(() {
      final (clientTransport, _) = RpcChannelTransport.memoryPair();
      final endpoint = RpcCallerEndpoint(transport: clientTransport);
      callContext = RpcMiddlewareContext(
        endpoint: endpoint,
        serviceName: 'EchoService',
        methodName: 'stream',
        context: RpcContext.empty(),
      );
    });

    // Fixed clock so the sliding window never advances during the test.
    int frozenClock() => 0;

    test('server-stream: each response message consumes a token and then '
        'emits RESOURCE_EXHAUSTED after limit', () async {
      final limiter = RpcRateLimiter(
        global: RateLimit.slidingWindow(
          max: 3,
          window: const Duration(hours: 1),
        ),
        nowMicros: frozenClock,
      );

      final out = await limiter.interceptServerStream<String, String>(
        callContext,
        'req',
        (ctx, req) => Stream<String>.fromIterable(['a', 'b', 'c', 'd', 'e']),
      );

      final received = <String>[];
      Object? error;
      final done = Completer<void>();
      out.listen(
        received.add,
        onError: (Object e) {
          error = e;
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );
      await done.future;

      expect(received, ['a', 'b', 'c']);
      expect(error, isA<RpcRateLimitException>());
      expect(error.toString(), contains('RESOURCE_EXHAUSTED'));
      limiter.dispose();
    });

    test('client-stream: each request message consumes a token', () async {
      final limiter = RpcRateLimiter(
        global: RateLimit.slidingWindow(
          max: 2,
          window: const Duration(hours: 1),
        ),
        nowMicros: frozenClock,
      );

      late Stream<String> seenRequests;
      await limiter.interceptClientStream<String, String>(
        callContext,
        Stream<String>.fromIterable(['1', '2', '3', '4']),
        (ctx, reqs) async {
          seenRequests = reqs;
          return 'ok';
        },
      );

      final received = <String>[];
      Object? error;
      final done = Completer<void>();
      seenRequests.listen(
        received.add,
        onError: (Object e) {
          error = e;
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );
      await done.future;

      expect(received, ['1', '2']);
      expect(error, isA<RpcRateLimitException>());
      limiter.dispose();
    });

    test('no limit configured: stream passes through unchanged', () async {
      final limiter = RpcRateLimiter(nowMicros: frozenClock);

      final out = await limiter.interceptServerStream<String, String>(
        callContext,
        'req',
        (ctx, req) => Stream<String>.fromIterable(['x', 'y', 'z']),
      );

      expect(await out.toList(), ['x', 'y', 'z']);
      limiter.dispose();
    });

    test('unary behavior unchanged: one token per call', () async {
      final limiter = RpcRateLimiter(
        global: RateLimit.slidingWindow(
          max: 2,
          window: const Duration(hours: 1),
        ),
        nowMicros: frozenClock,
      );
      final unaryCtx = RpcMiddlewareContext(
        endpoint: callContext.endpoint,
        serviceName: 'EchoService',
        methodName: 'ping',
        context: RpcContext.empty(),
      );

      Future<String> call() => limiter.interceptUnary<String, String>(
        unaryCtx,
        'req',
        (ctx, req) async => 'ok',
      );

      expect(await call(), 'ok');
      expect(await call(), 'ok');
      await expectLater(call(), throwsA(isA<RpcRateLimitException>()));
      limiter.dispose();
    });
  });
}
