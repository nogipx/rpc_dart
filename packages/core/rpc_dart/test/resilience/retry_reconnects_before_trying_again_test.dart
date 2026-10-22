// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Before retrying an UNAVAILABLE call, RpcRetryInterceptor waits for the
// transport's next reconnect outcome, so the retry does not go back to the
// SAME dead connection. Without that wait the budget burns and no attempt can
// pass: a retry that cannot succeed spends the caller's deadline to arrive at
// the same failure.
//
// The status alone does NOT say the connection is gone, so the interceptor
// asks the transport's health first; a fake here has to answer that question
// honestly or it is not the situation being measured.
//
// Only RpcClientConnection's proxy reconnects; the fake stands in for it by
// returning itself as its reconnectOutcome, as the proxy does.

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

/// Counts reconnect waits and reports whether the "connection" is up.
class _FlakyTransport extends IRpcTransport implements IRpcReconnectOutcome {
  int reconnects = 0;
  bool up = false;

  @override
  IRpcReconnectOutcome get reconnectOutcome => this;

  @override
  Future<RpcHealthStatus> awaitReconnect() async {
    reconnects++;
    up = true;
    return RpcHealthStatus.healthy(component: 'flaky', message: 'reconnected');
  }

  @override
  int get lastIssuedStreamId => 1;

  @override
  void resumeStreamIdsAfter(int streamId) {}

  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}

  // The interceptor asks before reconnecting, so this has to answer about the
  // CONNECTION rather than always say ok: a fake that reports healthy while
  // `up` is false describes no transport this library ships.
  @override
  Future<RpcHealthStatus> health() async => up
      ? RpcHealthStatus.healthy(component: 'flaky', message: 'ok')
      : RpcHealthStatus.unhealthy(component: 'flaky', message: 'no connection');

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
  late RpcCallInfo callContext;

  setUp(() {
    transport = _FlakyTransport();
    callContext = RpcCallInfo(
      endpoint: RpcCallerEndpoint(transport: transport),
      serviceName: 'Svc',
      methodName: 'echo',
      context: RpcContext.empty(),
      direction: RpcCallDirection.outgoing,
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
        throw RpcStatusException.atCapacity('slow down');
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
