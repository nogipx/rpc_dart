// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcRetryInterceptor retried UNAVAILABLE and never called reconnect(), so on a
// bare transport every attempt went back to the SAME dead connection. The
// budget burned and no attempt could pass — a retry that cannot succeed, which
// spends the caller's deadline to arrive at the same failure.
//
// That made two http2 contracts hollow rather than wrong: "a drained connection
// is retried as the retry doc promises" and "a dead connection is UNAVAILABLE
// (reconnect), not saturated" both say retrying is the remedy, and retrying was
// not reaching the remedy.
//
// B-61's third option: teach the interceptor to reconnect. It overturns neither
// transport's decision — websocket keeps refusing the reconnect WINDOW
// non-retryably, http2 keeps answering UNAVAILABLE — and makes UNAVAILABLE mean
// what it says.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Counts reconnects and reports whether the "connection" is up.
class _FlakyTransport implements IRpcTransport {
  int reconnects = 0;
  bool up = false;

  @override
  Future<RpcHealthStatus> reconnect() async {
    reconnects++;
    up = true;
    return RpcHealthStatus.healthy(component: 'flaky', message: 'reconnected');
  }

  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}

  @override
  Future<RpcHealthStatus> health() async =>
      RpcHealthStatus.healthy(component: 'flaky', message: 'ok');

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

void main() {
  late _FlakyTransport transport;
  late RpcMiddlewareContext callContext;

  setUp(() {
    transport = _FlakyTransport();
    callContext = RpcMiddlewareContext(
      endpoint: RpcCallerEndpoint(transport: transport),
      serviceName: 'Svc',
      methodName: 'echo',
      context: RpcContext.empty(),
    );
  });

  // WITNESS: reconnects was 0 however many attempts were spent.
  test('an UNAVAILABLE retry reconnects first', () async {
    final interceptor = RpcRetryInterceptor(
      maxAttempts: 3,
      backoff: FixedBackoff(Duration(milliseconds: 5)),
    );
    var attempts = 0;

    final result = await interceptor.interceptUnary<String, String>(
      callContext,
      'req',
      (ctx, req) async {
        attempts++;
        // Fails until something has re-established the connection.
        if (!transport.up) {
          throw RpcStatusException(RpcStatus.unavailable, 'connection is gone');
        }
        return 'recovered';
      },
    );

    expect(result, 'recovered');
    expect(attempts, 2, reason: 'the second attempt should find it up');
    expect(
      transport.reconnects,
      1,
      reason:
          'without a reconnect every attempt hits the same dead transport and '
          'the retry budget is spent for nothing',
    );
  });

  // GUARD: RESOURCE_EXHAUSTED means the PEER is overloaded and its connection
  // is fine. Reconnecting would drop a working one and add load to a server
  // that just asked for less.
  test('RESOURCE_EXHAUSTED is retried WITHOUT reconnecting', () async {
    final interceptor = RpcRetryInterceptor(
      maxAttempts: 3,
      backoff: FixedBackoff(Duration(milliseconds: 5)),
    );
    var attempts = 0;

    try {
      await interceptor.interceptUnary<String, String>(callContext, 'req', (
        ctx,
        req,
      ) async {
        attempts++;
        throw RpcStatusException(RpcStatus.resourceExhausted, 'slow down');
      });
      fail('should have thrown');
    } on RpcStatusException {
      // expected
    }

    expect(attempts, 3, reason: 'still retried');
    expect(transport.reconnects, 0, reason: 'but the connection was fine');
  });

  // GUARD: a non-transient failure must not reconnect either — it is not
  // retried at all, and reconnecting would be work done for nothing.
  test('a non-transient error neither retries nor reconnects', () async {
    final interceptor = RpcRetryInterceptor(
      maxAttempts: 3,
      backoff: FixedBackoff(Duration(milliseconds: 5)),
    );
    var attempts = 0;

    try {
      await interceptor.interceptUnary<String, String>(callContext, 'req', (
        ctx,
        req,
      ) async {
        attempts++;
        throw RpcStatusException(RpcStatus.invalidArgument, 'bad request');
      });
      fail('should have thrown');
    } on RpcStatusException {
      // expected
    }

    expect(attempts, 1);
    expect(transport.reconnects, 0);
  });
}
