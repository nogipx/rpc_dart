// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// With meterServerStreamMessages: true, a server-stream was charged per
// response only, and the handler ran before any check: a stream that emits
// nothing cost nothing, so ten of them opened against a limit of two. Every
// other shape is charged when it is opened, and this one now is too, with
// its first response prepaid.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  for (final meter in [true, false]) {
    test(
      'meterServerStreamMessages: $meter -- empty streams are charged',
      () async {
        final (_, server) = RpcChannelTransport.memoryPair();
        final endpoint = RpcResponderEndpoint(transport: server);
        addTearDown(endpoint.close);
        final call = RpcMiddlewareContext(
          endpoint: endpoint,
          serviceName: 'Feed',
          methodName: 'subscribe',
          context: RpcContext.empty(),
        );
        final limiter = RpcRateLimiter(
          global: const RateLimit.slidingWindow(
            max: 2,
            window: Duration(hours: 1),
          ),
          meterServerStreamMessages: meter,
        );

        var handlerRuns = 0;
        var refused = 0;
        for (var i = 0; i < 10; i++) {
          try {
            final stream = await limiter.interceptServerStream<String, String>(
              call,
              'r',
              (c, r) {
                handlerRuns++;
                return const Stream<String>.empty();
              },
            );
            await stream.drain<void>();
          } on RpcRateLimitException {
            refused++;
          }
        }

        expect(handlerRuns, 2);
        expect(refused, 8);
      },
    );
  }

  test(
    'metered: the first response is prepaid, the rest are charged',
    () async {
      final (_, server) = RpcChannelTransport.memoryPair();
      final endpoint = RpcResponderEndpoint(transport: server);
      addTearDown(endpoint.close);
      final call = RpcMiddlewareContext(
        endpoint: endpoint,
        serviceName: 'Feed',
        methodName: 'subscribe',
        context: RpcContext.empty(),
      );
      final limiter = RpcRateLimiter(
        global: const RateLimit.slidingWindow(
          max: 3,
          window: Duration(hours: 1),
        ),
        meterServerStreamMessages: true,
      );

      final stream = await limiter.interceptServerStream<String, String>(
        call,
        'r',
        (c, r) => Stream.fromIterable(['a', 'b', 'c', 'd', 'e']),
      );
      final got = <String>[];
      Object? error;
      await stream.forEach(got.add).catchError((Object e) => error = e);

      // One token at opening covers 'a'; 'b' and 'c' take the other two.
      expect(got, ['a', 'b', 'c']);
      expect(error, isA<RpcRateLimitException>());
    },
  );
}
