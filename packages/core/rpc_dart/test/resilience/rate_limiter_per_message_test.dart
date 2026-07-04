// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Per-message accounting for streaming RPCs, split by load direction.
//
// Inbound streams (client-stream / bidirectional requests) count one token per
// message — genuine client-driven load. Server-streams meter establishment (one
// token per open, like unary) by default, because the responses are server-paced
// output; opt into per-response accounting with meterServerStreamMessages: true.
// When a metered limit is exceeded mid-stream the wrapped stream emits an
// RpcRateLimitException error (RESOURCE_EXHAUSTED), consistent with the unary
// path.

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

    test('server-stream (default): establishment metered once, every response '
        'passes through regardless of count', () async {
      // Limit of 3, but a single stream open costs ONE token — so all five
      // responses must be delivered even though 5 > 3.
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

      expect(await out.toList(), ['a', 'b', 'c', 'd', 'e']);
      limiter.dispose();
    });

    test(
      'server-stream (default): the Nth+1 stream OPEN is rejected',
      () async {
        // Establishment metering: 3 opens allowed per window, the 4th throws.
        final limiter = RpcRateLimiter(
          global: RateLimit.slidingWindow(
            max: 3,
            window: const Duration(hours: 1),
          ),
          nowMicros: frozenClock,
        );

        Future<Stream<String>> open() => Future.value(
          limiter.interceptServerStream<String, String>(
            callContext,
            'req',
            (ctx, req) => Stream<String>.fromIterable(['x']),
          ),
        );

        await open();
        await open();
        await open();
        await expectLater(open(), throwsA(isA<RpcRateLimitException>()));
        limiter.dispose();
      },
    );

    test(
      'server-stream (meterServerStreamMessages: true): each response '
      'consumes a token and then emits RESOURCE_EXHAUSTED after limit',
      () async {
        final limiter = RpcRateLimiter(
          global: RateLimit.slidingWindow(
            max: 3,
            window: const Duration(hours: 1),
          ),
          meterServerStreamMessages: true,
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
      },
    );

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
