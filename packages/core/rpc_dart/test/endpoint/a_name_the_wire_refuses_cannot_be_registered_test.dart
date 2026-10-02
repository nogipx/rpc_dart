// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Registration did not check names against the wire grammar the caller and
// the responder's path parser both enforce. A method `a.b` on service `S`
// took the binding key `S.a.b` -- the key of method `b` on service `S.a` --
// so a call for `/S.a/b` was answered by `S`'s handler; and a method `x/y`
// registered fine and could never be called. Now both are refused when
// registered.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Named extends RpcResponderContract {
  _Named(super.serviceName, this.method);

  final String method;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: method,
      handler: (r, {RpcContext? context}) async => '$serviceName/$method'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  final refused = throwsA(
    isA<RpcStatusException>().having(
      (e) => e.statusCode,
      'status',
      RpcStatus.internal,
    ),
  );

  RpcResponderEndpoint endpoint() {
    final (_, server) = RpcChannelTransport.pair();
    final e = RpcResponderEndpoint(transport: server);
    addTearDown(e.close);
    return e;
  }

  test('a dotted method name is refused', () {
    expect(
      () => endpoint().registerServiceContract(_Named('S', 'a.b')),
      refused,
    );
  });

  test('a method name with a slash is refused', () {
    expect(
      () => endpoint().registerServiceContract(_Named('S', 'x/y')),
      refused,
    );
  });

  test('a service name with a slash is refused', () {
    expect(
      () => endpoint().registerServiceContract(_Named('S/T', 'm')),
      refused,
    );
  });

  test('CONTROL: a dotted SERVICE name is legal and reachable', () async {
    final (client, server) = RpcChannelTransport.pair();
    final responder = RpcResponderEndpoint(transport: server)
      ..registerServiceContract(_Named('myapp.v1.S', 'Get'))
      ..start();
    final caller = RpcCallerEndpoint(transport: client);
    addTearDown(() async {
      await caller.close();
      await responder.close();
    });

    final answer = await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'myapp.v1.S',
      methodName: 'Get',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    expect(answer.value, 'myapp.v1.S/Get');
  });
}
