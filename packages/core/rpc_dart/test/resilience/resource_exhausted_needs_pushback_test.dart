// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RESOURCE_EXHAUSTED means two things. A limit that frees up -- a handler
// ceiling, a rate limit -- is worth another attempt, and the server says so with
// RpcRetryInfo. A message over the size limit fails the same way every time, and
// carries none. The default retry predicate and circuit breaker read the
// difference; before, a too-large message was sent three times.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc(this.calls) : super('Svc');
  final List<int> calls;
  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (r, {RpcContext? context}) async {
        calls[0]++;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return 'ok'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Runs [count] calls through a retrying caller against a server with
/// [serverPolicy]; returns the outcomes and how often the handler ran.
Future<({List<String> results, int ran, int attempts})> _run(
  RpcSecurityPolicy serverPolicy, {
  IRpcInterceptor? serverInterceptor,
  String request = 'x',
  int count = 2,
  bool together = true,
}) async {
  const loose = RpcSecurityPolicy();
  final (clientCh, serverCh) = RpcFrameMultiplexedChannel.pair(policy: loose);
  final client = RpcChannelTransport(
    channel: clientCh,
    isClient: true,
    policy: loose,
  );
  final server = RpcChannelTransport(
    channel: serverCh,
    isClient: false,
    policy: serverPolicy,
  );
  addTearDown(() async {
    await client.close();
    await server.close();
  });
  final calls = [0];
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Svc(calls));
  if (serverInterceptor != null) responder.addInterceptor(serverInterceptor);
  responder.start();
  // Attempts as the SERVER sees them: one stream opened per attempt.
  final opened = <int>{};
  server.incomingMessages.listen((m) {
    if (m.methodPath != null) opened.add(m.streamId);
  }, onError: (Object _) {});
  final caller = RpcCallerEndpoint(transport: client)
    ..addInterceptor(
      RpcRetryInterceptor(
        backoff: const FixedBackoff(Duration(milliseconds: 350)),
      ),
    );

  Future<String> call() => caller
      .unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'Echo',
        request: request.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      )
      .then(
        (_) => 'ok',
        onError: (Object e) =>
            e is RpcStatusException ? 'status ${e.statusCode}' : '$e',
      );

  final results = <String>[];
  if (together) {
    results.addAll(await Future.wait([for (var i = 0; i < count; i++) call()]));
  } else {
    for (var i = 0; i < count; i++) {
      results.add(await call());
    }
  }
  return (results: results, ran: calls[0], attempts: opened.length);
}

void main() {
  test('a message over the size limit is sent once', () async {
    final r = await _run(
      const RpcSecurityPolicy(maxMessageLengthBytes: 1024),
      request: 'x' * 4096,
      count: 1,
    );
    expect(r.results, ['status ${RpcStatus.resourceExhausted}']);
    expect(r.attempts, 1, reason: 'a size refusal fails the same way again');
  });

  test('a handler-ceiling refusal is retried', () async {
    final r = await _run(const RpcSecurityPolicy(maxConcurrentHandlers: 1));
    expect(r.results, ['ok', 'ok']);
    expect(r.ran, 2);
  });

  test('a rate-limit refusal is retried', () async {
    final r = await _run(
      const RpcSecurityPolicy(),
      serverInterceptor: RpcRateLimiter(
        global: const RateLimit.tokenBucket(
          max: 1,
          window: Duration(milliseconds: 300),
        ),
      ),
      together: false,
    );
    expect(r.results, ['ok', 'ok']);
    expect(r.ran, 2);
  });

  test('a bare RESOURCE_EXHAUSTED does not open the breaker', () async {
    final (client, _) = RpcChannelTransport.memoryPair();
    final endpoint = RpcCallerEndpoint(transport: client);
    addTearDown(() async {
      await endpoint.close();
      await client.close();
    });
    final breaker = RpcCircuitBreakerInterceptor(failureThreshold: 2);
    final call = RpcMiddlewareContext(
      endpoint: endpoint,
      serviceName: 'Svc',
      methodName: 'Echo',
      context: RpcContext.empty(),
    );
    Future<Object?> attempt(RpcStatusException error) => breaker
        .interceptUnary<String, String>(call, 'x', (_, _) async => throw error)
        .then<Object?>((_) => null, onError: (Object e) => e);

    for (var i = 0; i < 4; i++) {
      final e = await attempt(
        RpcStatusException(RpcStatus.resourceExhausted, 'too large'),
      );
      expect(e, isNot(isA<CircuitBreakerOpenException>()));
    }
    for (var i = 0; i < 2; i++) {
      await attempt(RpcStatusException.atCapacity('busy'));
    }
    expect(
      await attempt(RpcStatusException.atCapacity('busy')),
      isA<CircuitBreakerOpenException>(),
      reason: 'capacity refusals still count',
    );
  });
}
