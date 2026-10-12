// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A streaming call fires its context's cancellation token only when the
// consumer walks away. A call the server failed was followed by the
// consumer's own cancel (any `await for` or `toList` cancels at the error),
// which fired the token of a context the caller reuses: the next call on it
// failed CANCELLED. Bidi and server stream share the bridge; unary and
// client-stream do not use it.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'fails',
      handler: (requests, {RpcContext? context}) async* {
        throw RpcStatusException(RpcStatus.aborted, 'no');
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (requests, {RpcContext? context}) => requests,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'itemsFail',
      handler: (r, {RpcContext? context}) async* {
        throw RpcStatusException(RpcStatus.aborted, 'no');
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'items',
      handler: (r, {RpcContext? context}) async* {
        yield r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'unaryFail',
      handler: (r, {RpcContext? context}) async =>
          throw RpcStatusException(RpcStatus.aborted, 'no'),
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'collectFail',
      handler: (reqs, {RpcContext? context}) async =>
          throw RpcStatusException(RpcStatus.aborted, 'no'),
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'ping',
      handler: (r, {RpcContext? context}) async => 'pong'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Future<void> _check(String method) async {
  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Svc())
    ..start();
  final caller = RpcCallerEndpoint(transport: client);
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });

  final token = RpcCancellationToken();
  final shared = RpcContext.withCancellation(token);
  if (method == 'unaryFail' || method == 'collectFail') {
    final Future<RpcString> call = method == 'unaryFail'
        ? caller.unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: method,
            request: 'q'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
            context: shared,
          )
        : caller.clientStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: method,
            requestCodec: _codec,
            responseCodec: _codec,
            context: shared,
          )(Stream.value('q'.rpc));
    await call.then<void>((_) {}, onError: (Object _) {});
    expect(token.isCancelled, isFalse);
    return;
  }
  final Stream<RpcString> stream = method.startsWith('items')
      ? caller.serverStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: method,
          request: 'q'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
          context: shared,
        )
      : caller.bidirectionalStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: method,
          requests: Stream.value('q'.rpc),
          requestCodec: _codec,
          responseCodec: _codec,
          context: shared,
        );
  // toList cancels its subscription at the error, as any `await for` does.
  await stream.toList().then<void>((_) {}, onError: (Object _) {});

  expect(token.isCancelled, isFalse);
  final answer = await caller.unaryRequest<RpcString, RpcString>(
    serviceName: 'Svc',
    methodName: 'ping',
    request: 'x'.rpc,
    requestCodec: _codec,
    responseCodec: _codec,
    context: shared,
  );
  expect(answer.value, 'pong');
}

void main() {
  test('WITNESS a bidi call the server fails leaves its context usable', () {
    return _check('fails');
  });

  test('GUARD a bidi call that ends OK leaves its context usable', () {
    return _check('echo');
  });

  test(
    'WITNESS a server stream the server fails leaves its context usable',
    () {
      return _check('itemsFail');
    },
  );

  test('GUARD a server stream that ends OK leaves its context usable', () {
    return _check('items');
  });

  test('GUARD a unary call the server fails leaves its context usable', () {
    return _check('unaryFail');
  });

  test('GUARD a client stream the server fails leaves its context usable', () {
    return _check('collectFail');
  });
}
