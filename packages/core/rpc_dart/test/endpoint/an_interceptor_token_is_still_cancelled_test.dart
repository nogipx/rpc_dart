// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// An interceptor that hands next() a context with its own cancellation token
// -- the only way it can own cancellation -- cut the call off from every
// cancel the endpoint tracks, which follows the token the call started with:
//
//   - caller side: cancelAllMethods() reached nothing, the call hung, and
//     pendingRequests no longer counted it;
//   - responder side: a client cancel never reached the handler.
//
// The original token now cancels the interceptor's.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Swaps in a fresh token, or passes the context through unchanged.
final class _OwnToken extends IRpcInterceptor {
  _OwnToken({required this.swap});

  final bool swap;

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) => next(
    swap ? call.context.withCancellation(RpcCancellationToken()) : call.context,
    request,
  );
}

final class _Parks extends RpcResponderContract {
  _Parks(this.cancelled) : super('S');

  final Completer<String> cancelled;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'park',
      handler: (r, {RpcContext? context}) async {
        final token = context?.cancellationToken;
        await Future.any([
          if (token != null) token.cancelled,
          Future<void>.delayed(const Duration(seconds: 2)),
        ]);
        if (!cancelled.isCompleted) {
          cancelled.complete(token?.isCancelled ?? false ? 'cancelled' : 'not');
        }
        return r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  for (final swap in [true, false]) {
    final arm = swap ? 'a swapped token' : 'CONTROL: the original token';

    test('$arm: cancelAllMethods on the caller reaches the call', () async {
      final handlerSaw = Completer<String>();
      final (client, server) = RpcChannelTransport.pair();
      final responder = RpcResponderEndpoint(transport: server)
        ..registerServiceContract(_Parks(handlerSaw))
        ..start();
      final caller = RpcCallerEndpoint(transport: client)
        ..addInterceptor(_OwnToken(swap: swap));
      addTearDown(() async {
        await caller.close();
        await responder.close();
      });

      final call = caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'S',
            methodName: 'park',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .then(
            (_) => 'value',
            onError: (Object e) => e.runtimeType.toString(),
          );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(caller.collectEndpointMetrics()['pendingRequests'], 1);
      caller.cancelAllMethods('user cancel');

      expect(
        await call.timeout(const Duration(seconds: 1), onTimeout: () => 'HUNG'),
        'RpcCancelledException',
      );
      expect(await handlerSaw.future, 'cancelled');
    });

    test('$arm: a client cancel reaches the server handler', () async {
      final handlerSaw = Completer<String>();
      final (client, server) = RpcChannelTransport.pair();
      final responder = RpcResponderEndpoint(transport: server)
        ..addInterceptor(_OwnToken(swap: swap))
        ..registerServiceContract(_Parks(handlerSaw))
        ..start();
      final caller = RpcCallerEndpoint(transport: client);
      addTearDown(() async {
        await caller.close();
        await responder.close();
      });

      final token = RpcCancellationToken();
      final call = caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'S',
            methodName: 'park',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
            context: RpcContext.withCancellation(token),
          )
          .then((_) {}, onError: (Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      token.cancel('user cancel');
      await call;

      expect(
        await handlerSaw.future.timeout(const Duration(seconds: 1)),
        'cancelled',
      );
    });
  }
}
