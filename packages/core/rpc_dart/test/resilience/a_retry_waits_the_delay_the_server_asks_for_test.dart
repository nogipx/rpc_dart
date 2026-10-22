// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Pushback names its own delay: a retry after an [RpcRetryInfo] with a
/// positive delay waits that delay, not the interceptor's backoff.
void main() {
  late RpcCallerEndpoint endpoint;

  setUp(() {
    final (client, _) = RpcChannelTransport.memoryPair();
    endpoint = RpcCallerEndpoint(transport: client);
    addTearDown(endpoint.close);
  });

  RpcCallInfo callWith(RpcContext context) => RpcCallInfo(
    endpoint: endpoint,
    serviceName: 'S',
    methodName: 'M',
    context: context,
    direction: RpcCallDirection.outgoing,
  );

  Future<List<Duration>> gaps(
    RpcContext context,
    RpcStatusException Function() failure,
  ) async {
    final clock = Stopwatch()..start();
    final starts = <Duration>[];
    final retry = RpcRetryInterceptor(
      maxAttempts: 3,
      backoff: const FixedBackoff(Duration(milliseconds: 10)),
    );
    await expectLater(
      retry.interceptUnary<int, int>(callWith(context), 0, (ctx, req) async {
        starts.add(clock.elapsed);
        throw failure();
      }),
      throwsA(isA<RpcStatusException>()),
    );
    return [for (var i = 1; i < starts.length; i++) starts[i] - starts[i - 1]];
  }

  test('a positive retry delay replaces the backoff', () async {
    final waited = await gaps(
      RpcContext.empty(),
      () => RpcRateLimitException(
        'slow down',
        retryAfter: const Duration(milliseconds: 300),
      ),
    );

    expect(waited, hasLength(2));
    for (final gap in waited) {
      expect(gap, greaterThanOrEqualTo(const Duration(milliseconds: 290)));
    }
  });

  test('a zero retry delay waits the backoff', () async {
    final waited = await gaps(
      RpcContext.empty(),
      () => RpcStatusException.atCapacity('full'),
    );

    expect(waited, hasLength(2));
    for (final gap in waited) {
      expect(gap, lessThan(const Duration(milliseconds: 200)));
    }
  });

  test('a retry delay past the deadline ends the call at once', () async {
    final clock = Stopwatch()..start();
    final waited = await gaps(
      RpcContext.withTimeout(const Duration(seconds: 1)),
      () => RpcRateLimitException(
        'slow down',
        retryAfter: const Duration(seconds: 5),
      ),
    );

    expect(waited, isEmpty);
    expect(clock.elapsed, lessThan(const Duration(seconds: 1)));
  });
}
