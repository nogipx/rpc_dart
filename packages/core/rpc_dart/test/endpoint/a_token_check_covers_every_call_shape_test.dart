// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `IRpcInterceptor.check` runs for every call shape, so a check put there
// cannot miss one. The skill's `RequireTokenInterceptor`
// (contracts-and-endpoints.md) is copied here as written there. Keep this
// copy in step with the skill's.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final class RequireTokenInterceptor extends IRpcInterceptor {
  const RequireTokenInterceptor();

  @override
  void check(RpcMiddlewareContext call) {
    if (call.context.getHeader('authorization') == null) {
      throw RpcStatusException(RpcStatus.unauthenticated, 'missing token');
    }
  }
}

/// The same check, asynchronous: a token store that answers later.
final class AsyncTokenInterceptor extends IRpcInterceptor {
  const AsyncTokenInterceptor();

  @override
  Future<void> check(RpcMiddlewareContext call) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (call.context.getHeader('authorization') == null) {
      throw RpcStatusException(RpcStatus.permissionDenied, 'no grant');
    }
  }
}

/// Records the order hooks run in.
final class _Order extends IRpcInterceptor {
  _Order(this.name, this.seen);
  final String name;
  final List<String> seen;

  @override
  void check(RpcMiddlewareContext call) => seen.add('$name.check');

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) {
    seen.add('$name.unary');
    return next(call.context, request);
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

/// A caller to a server whose responder carries [serverSide], and whose own
/// endpoint carries [callerSide].
_Caller _rig({IRpcInterceptor? serverSide, IRpcInterceptor? callerSide}) {
  final (ct, st) = RpcChannelTransport.pair();
  final server = RpcResponderEndpoint(transport: st)
    ..registerServiceContract(_Svc());
  if (serverSide != null) server.addInterceptor(serverSide);
  server.start();
  final endpoint = RpcCallerEndpoint(transport: ct);
  if (callerSide != null) endpoint.addInterceptor(callerSide);
  addTearDown(() async {
    await endpoint.close();
    await server.close();
  });
  return _Caller(endpoint);
}

final _token = RpcContext.withHeaders({'authorization': 'Bearer t'});
const _shapes = ['unary', 'serverStream', 'clientStream', 'bidi'];

void main() {
  for (final shape in _shapes) {
    test('WITNESS: a $shape call without a token is refused', () async {
      final caller = _rig(serverSide: const RequireTokenInterceptor());
      expect(
        await caller.call(shape, RpcContext.empty()),
        RpcStatus.unauthenticated,
      );
    });

    test('GUARD: a $shape call with a token is served', () async {
      final caller = _rig(serverSide: const RequireTokenInterceptor());
      expect(await caller.call(shape, _token), isNot(isA<int>()));
    });

    test('an asynchronous check refuses a $shape call too', () async {
      final caller = _rig(serverSide: const AsyncTokenInterceptor());
      expect(
        await caller.call(shape, RpcContext.empty()),
        RpcStatus.permissionDenied,
      );
      expect(await caller.call(shape, _token), isNot(isA<int>()));
    });

    test('a check on the caller endpoint refuses a $shape call', () async {
      final caller = _rig(callerSide: const RequireTokenInterceptor());
      expect(
        await caller.call(shape, RpcContext.empty()),
        RpcStatus.unauthenticated,
      );
    });
  }

  test('check runs outermost first, each before its own method', () async {
    final seen = <String>[];
    final (ct, st) = RpcChannelTransport.pair();
    final server = RpcResponderEndpoint(transport: st)
      ..registerServiceContract(_Svc())
      ..addInterceptor(_Order('a', seen))
      ..addInterceptor(_Order('b', seen))
      ..start();
    final endpoint = RpcCallerEndpoint(transport: ct);
    addTearDown(() async {
      await endpoint.close();
      await server.close();
    });

    await _Caller(endpoint).call('unary', RpcContext.empty());
    expect(seen, ['a.check', 'a.unary', 'b.check', 'b.unary']);
  });
}
