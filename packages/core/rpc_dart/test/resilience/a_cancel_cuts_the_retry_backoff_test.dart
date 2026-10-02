// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A call cancelled while the retry interceptor is backing off waited out the
// rest of the backoff before the next attempt noticed the token. Measured
// through the default jittered backoff the wait is random, which is how an
// earlier reading took it for prompt; a fixed backoff shows it.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Flaky extends RpcResponderContract {
  _Flaky() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'always',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async =>
          throw RpcStatusException(RpcStatus.unavailable, 'try again'),
    );
  }
}

/// Status and elapsed milliseconds of one call with a fixed 3 s backoff,
/// cancelled after [cancelAfter] when given.
Future<(int, int)> _call({Duration? cancelAfter}) async {
  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Flaky())
    ..start();
  final caller = RpcCallerEndpoint(transport: client)
    ..addInterceptor(
      RpcRetryInterceptor(
        maxAttempts: 2,
        backoff: const FixedBackoff(Duration(seconds: 3)),
      ),
    );
  final token = RpcCancellationToken();
  final sw = Stopwatch()..start();
  if (cancelAfter != null) {
    Timer(cancelAfter, () => token.cancel('not interested'));
  }
  var status = -1;
  try {
    await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'always',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
      context: RpcContext.withCancellation(token),
    );
  } on RpcStatusException catch (e) {
    status = e.statusCode;
  }
  final ms = sw.elapsedMilliseconds;
  await caller.close();
  await responder.close();
  return (status, ms);
}

void main() {
  test('a cancel during the backoff ends the call promptly', () async {
    final (status, ms) = await _call(
      cancelAfter: const Duration(milliseconds: 300),
    );
    expect(status, RpcStatus.cancelled);
    expect(ms, lessThan(1500), reason: 'waited out the backoff: $ms ms');
  });

  test('CONTROL: without a cancel the backoff is waited out', () async {
    final (status, ms) = await _call();
    expect(status, RpcStatus.unavailable);
    expect(ms, greaterThanOrEqualTo(3000));
  });

  // After the backoff the interceptor reconnects a transport whose connection
  // is gone. A cancelled call must neither start that reconnect nor wait for
  // one.
  group('with a connection that takes 3 s to come back', () {
    Future<(String, int, int)> run({required bool cancel}) async {
      final transport = _SlowReconnect();
      final token = RpcCancellationToken();
      final call = RpcMiddlewareContext(
        endpoint: RpcCallerEndpoint(transport: transport),
        serviceName: 'Svc',
        methodName: 'm',
        context: RpcContext.withCancellation(token),
      );
      final retry = RpcRetryInterceptor(
        maxAttempts: 2,
        backoff: const FixedBackoff(Duration(seconds: 2)),
      );
      if (cancel) {
        Timer(const Duration(milliseconds: 100), () => token.cancel('x'));
      }
      final sw = Stopwatch()..start();
      String outcome;
      try {
        await retry.interceptUnary<String, String>(call, 'r', (c, r) async {
          c.cancellationToken?.throwIfCancelled();
          throw RpcStatusException(RpcStatus.unavailable, 'gone');
        });
        outcome = 'ok';
      } on RpcCancelledException {
        outcome = 'cancelled';
      } on RpcStatusException catch (e) {
        outcome = 'status ${e.statusCode}';
      }
      return (outcome, sw.elapsedMilliseconds, transport.reconnects);
    }

    test('a cancel during the backoff skips the reconnect', () async {
      final (outcome, ms, reconnects) = await run(cancel: true);
      expect(outcome, 'cancelled');
      expect(ms, lessThan(1500), reason: 'waited for the reconnect: $ms ms');
      expect(reconnects, 0, reason: 'an abandoned call started a reconnect');
    });

    test('CONTROL: without a cancel the reconnect runs', () async {
      final (outcome, ms, reconnects) = await run(cancel: false);
      expect(outcome, 'status ${RpcStatus.unavailable}');
      expect(reconnects, 1);
      expect(ms, greaterThanOrEqualTo(5000));
    });
  });
}

/// A transport whose connection is gone and takes 3 s to fail to come back.
final class _SlowReconnect implements IRpcTransport {
  int reconnects = 0;

  @override
  Future<RpcHealthStatus> reconnect() async {
    reconnects++;
    await Future<void>.delayed(const Duration(seconds: 3));
    return RpcHealthStatus.unhealthy(component: 't', message: 'still down');
  }

  @override
  Future<RpcHealthStatus> health() async =>
      RpcHealthStatus.unhealthy(component: 't', message: 'no connection');

  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}

  @override
  bool get isClient => true;

  @override
  bool get supportsZeroCopy => false;

  @override
  int createStream() => 1;

  @override
  bool releaseStreamId(int streamId) => true;

  @override
  Stream<RpcTransportMessage> get incomingMessages => const Stream.empty();

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      const Stream.empty();

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {}

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {}

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {}

  @override
  Future<void> finishSending(int streamId) async {}
}
