// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A deadline a responder interceptor hands the handler is enforced, when it is
// EARLIER than the caller's: the handler's token is cancelled at it and the
// caller is answered DEADLINE_EXCEEDED. A later one never extends what the
// caller asked for. The caller side already worked this way.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc(this.onCancel) : super('S');

  final void Function() onCancel;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'slow',
      handler: (r, {RpcContext? context}) async {
        final token = context?.cancellationToken;
        await Future.any([
          Future<void>.delayed(const Duration(seconds: 2)),
          if (token != null) token.cancelled.then((_) => onCancel()),
        ]);
        return 'late'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

final class _Timeout extends IRpcInterceptor {
  _Timeout(this.timeout);

  final Duration timeout;

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) => next(call.context.withTimeout(timeout), request);
}

Future<({String outcome, int ms, bool cancelled})> _call({
  required Duration serverTimeout,
  Duration? clientTimeout,
}) async {
  var cancelled = false;
  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Svc(() => cancelled = true))
    ..addInterceptor(_Timeout(serverTimeout))
    ..start();
  final caller = RpcCallerEndpoint(transport: client);
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });
  final clock = Stopwatch()..start();
  String outcome;
  try {
    outcome = (await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'S',
      methodName: 'slow',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
      context: clientTimeout == null
          ? null
          : RpcContext.empty().withTimeout(clientTimeout),
    )).value;
  } on RpcStatusException catch (e) {
    outcome = 'status ${e.statusCode}';
  }
  return (
    outcome: outcome,
    ms: clock.elapsedMilliseconds,
    cancelled: cancelled,
  );
}

void main() {
  test('an earlier interceptor deadline ends the call', () async {
    final r = await _call(serverTimeout: const Duration(milliseconds: 200));
    expect(r.outcome, 'status ${RpcStatus.deadlineExceeded}');
    expect(r.cancelled, isTrue);
    expect(r.ms, lessThan(1000), reason: 'took ${r.ms}ms');
  });

  test('a later interceptor deadline does not extend the caller\'s', () async {
    final r = await _call(
      serverTimeout: const Duration(seconds: 10),
      clientTimeout: const Duration(milliseconds: 200),
    );
    expect(r.outcome, 'status ${RpcStatus.deadlineExceeded}');
    expect(r.ms, lessThan(1000), reason: 'took ${r.ms}ms');
  });
}
