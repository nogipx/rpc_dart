// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A connection the peer has drained must be reported as UNAVAILABLE, not as
// package:http2's raw StateError.
//
// GOAWAY is the routine case, not an exotic one: every load balancer drains
// with it, and every gRPC server with a max-connection-age sends it on a
// schedule. The defect was an inconsistency inside one transport -- the same
// underlying condition produced two different answers:
//
//   connection dies MID-call  -> RpcStatusException(14) "No response received"
//                                (caller_pipeline), retryable
//   connection dead, NEW call -> StateError, NOT retryable
//
// and only one of them is usable. RpcRetryInterceptor's default retries
// UNAVAILABLE and RESOURCE_EXHAUSTED, and its doc states the intent outright:
// "a lost connection becomes UNAVAILABLE". Measured against a raw
// package:http2 server that answered one call and then sent GOAWAY, with
// maxAttempts: 3 and attempts counted INSIDE the retry interceptor:
//
//   before: 1 attempt
//   after : 3 attempts
//
// Same defect shape as e4756025, where non-200 statuses collapsing to INTERNAL
// made 502/503/504 permanently non-retryable.
//
// Note this makes the failure CLASSIFIABLE; it does not by itself make a retry
// succeed on a dead connection -- that needs reconnect(), exactly as it
// already does for the mid-call UNAVAILABLE path.
//
// Driven by a raw package:http2 peer because rpc_dart's own responder never
// sends GOAWAY on its own.

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Counts how many times a call actually reaches the transport. Must be added
/// AFTER the retry interceptor so it sits INSIDE it -- added before, it counts
/// the single outer call and reports 1 no matter what the retry does.
final class _CountingInterceptor extends IRpcInterceptor {
  _CountingInterceptor(this.onAttempt);
  final void Function() onAttempt;

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) async {
    onAttempt();
    return next(call.context, request);
  }
}

void _answerOk(http2.ServerTransportStream stream) {
  stream.sendHeaders([
    http2.Header.ascii(':status', '200'),
    http2.Header.ascii('content-type', 'application/grpc+proto'),
  ]);
  stream.sendData(
    RpcMessageFrame.encode(_codec.serialize('ok'.rpc), compressed: false),
  );
  stream.sendHeaders([http2.Header.ascii('grpc-status', '0')], endStream: true);
}

void main() {
  late ServerSocket socket;
  late RpcHttp2CallerTransport transport;
  http2.ServerTransportConnection? live;

  setUp(() async {
    socket = await ServerSocket.bind('127.0.0.1', 0);
    socket.listen((client) {
      final conn = http2.ServerTransportConnection.viaSocket(client);
      live = conn;
      conn.incomingStreams.listen((stream) {
        stream.incomingMessages.listen((_) {}, onError: (Object _) {});
        _answerOk(stream);
      }, onError: (Object _) {});
    }, onError: (Object _) {});

    transport = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: socket.port,
    );
  });

  tearDown(() async {
    await transport.close().catchError((Object _) {});
    await socket.close();
  });

  Future<void> drain() async {
    unawaited(live!.finish().catchError((Object _) {}));
    await Future<void>.delayed(const Duration(seconds: 1));
  }

  Future<Object?> callAndCatch(RpcCallerEndpoint caller) async {
    try {
      await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Echo',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 8));
      return null;
    } catch (e) {
      return e;
    }
  }

  test('a call after GOAWAY fails with UNAVAILABLE', () async {
    final caller = RpcCallerEndpoint(transport: transport);
    addTearDown(() => caller.close().catchError((Object _) {}));

    // Control: the connection works before the drain.
    expect(await callAndCatch(caller), isNull);

    await drain();

    final error = await callAndCatch(caller);
    expect(
      error,
      isA<RpcStatusException>(),
      reason:
          'package:http2 throws a raw StateError here; every layer above keys '
          'off the gRPC status, so an unclassifiable error is invisible to '
          'retry, circuit breakers and failover',
    );
    expect((error as RpcStatusException).statusCode, RpcStatus.unavailable);
  });

  test('a drained connection is retried as the retry doc promises', () async {
    var attempts = 0;
    final caller = RpcCallerEndpoint(transport: transport)
      ..addInterceptor(
        RpcRetryInterceptor(
          maxAttempts: 3,
          backoff: const ExponentialBackoff(
            baseDelay: Duration(milliseconds: 20),
            maxDelay: Duration(milliseconds: 50),
          ),
        ),
      )
      // INSIDE the retry, on purpose -- see _CountingInterceptor.
      ..addInterceptor(_CountingInterceptor(() => attempts++));
    addTearDown(() => caller.close().catchError((Object _) {}));

    expect(await callAndCatch(caller), isNull);
    expect(attempts, 1, reason: 'the control call is one attempt');

    await drain();
    attempts = 0;

    await callAndCatch(caller);
    expect(
      attempts,
      3,
      reason:
          'RpcRetryInterceptor retries UNAVAILABLE and its doc says "a lost '
          'connection becomes UNAVAILABLE"; a StateError is not a status, so '
          'a routine load-balancer drain got exactly one attempt',
    );
  });

  test('GUARD: health still reports the drained connection honestly', () async {
    final caller = RpcCallerEndpoint(transport: transport);
    addTearDown(() => caller.close().catchError((Object _) {}));
    expect(await callAndCatch(caller), isNull);

    expect((await transport.health()).level, RpcHealthLevel.healthy);
    await drain();
    final health = await transport.health();
    expect(
      health.level,
      isNot(RpcHealthLevel.healthy),
      reason: 'a supervisor polls health to decide whether to reconnect',
    );
  });
}
