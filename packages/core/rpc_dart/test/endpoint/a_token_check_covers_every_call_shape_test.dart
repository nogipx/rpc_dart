// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The shipped skill's `RequireTokenInterceptor` (contracts-and-endpoints.md),
// copied here as written there. It used to override `interceptUnary` only, so
// a caller without a token was refused a unary call and served every
// streaming one. Keep this copy in step with the skill's.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final class RequireTokenInterceptor extends IRpcInterceptor {
  const RequireTokenInterceptor();

  static void _check(RpcMiddlewareContext call) {
    if (call.context.getHeader('authorization') == null) {
      throw RpcStatusException(RpcStatus.unauthenticated, 'missing token');
    }
  }

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) async {
    _check(call);
    return next(call.context, request);
  }

  @override
  FutureOr<Stream<TResponse>> interceptServerStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcServerStreamNext<TRequest, TResponse> next,
  ) {
    _check(call);
    return next(call.context, request);
  }

  @override
  Future<TResponse> interceptClientStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcClientStreamNext<TRequest, TResponse> next,
  ) async {
    _check(call);
    return next(call.context, requests);
  }

  @override
  FutureOr<Stream<TResponse>> interceptBidirectionalStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcBidirectionalStreamNext<TRequest, TResponse> next,
  ) {
    _check(call);
    return next(call.context, requests);
  }
}

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');
  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'u',
      handler: (r, {RpcContext? context}) async => 'secret'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'ss',
      handler: (r, {RpcContext? context}) => Stream.value('secret'.rpc),
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'cs',
      handler: (s, {RpcContext? context}) async {
        await s.drain<void>();
        return 'secret'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'bi',
      handler: (s, {RpcContext? context}) => s.map((_) => 'secret'.rpc),
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

final class _Caller extends RpcCallerContract {
  _Caller(RpcCallerEndpoint e) : super('Svc', e);

  Future<Object> call(String shape, RpcContext ctx) async {
    try {
      return switch (shape) {
        'unary' => await callUnary<RpcString, RpcString>(
          methodName: 'u',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
          context: ctx,
        ),
        'serverStream' => await callServerStream<RpcString, RpcString>(
          methodName: 'ss',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
          context: ctx,
        ).toList(),
        'clientStream' => await callClientStream<RpcString, RpcString>(
          methodName: 'cs',
          requests: Stream.value('x'.rpc),
          requestCodec: _codec,
          responseCodec: _codec,
          context: ctx,
        ),
        _ => await callBidirectionalStream<RpcString, RpcString>(
          methodName: 'bi',
          requests: Stream.value('x'.rpc),
          requestCodec: _codec,
          responseCodec: _codec,
          context: ctx,
        ).toList(),
      };
    } on RpcStatusException catch (e) {
      return e.statusCode;
    }
  }
}

void main() {
  late _Caller caller;

  setUp(() {
    final (ct, st) = RpcChannelTransport.pair();
    final server = RpcResponderEndpoint(transport: st)
      ..registerServiceContract(_Svc())
      ..addInterceptor(const RequireTokenInterceptor())
      ..start();
    final endpoint = RpcCallerEndpoint(transport: ct);
    caller = _Caller(endpoint);
    addTearDown(() async {
      await endpoint.close();
      await server.close();
    });
  });

  for (final shape in ['unary', 'serverStream', 'clientStream', 'bidi']) {
    test('WITNESS: a $shape call without a token is refused', () async {
      expect(
        await caller.call(shape, RpcContext.empty()),
        RpcStatus.unauthenticated,
      );
    });

    test('GUARD: a $shape call with a token is served', () async {
      expect(
        await caller.call(
          shape,
          RpcContext.withHeaders({'authorization': 'Bearer t'}),
        ),
        isNot(RpcStatus.unauthenticated),
      );
    });
  }
}
