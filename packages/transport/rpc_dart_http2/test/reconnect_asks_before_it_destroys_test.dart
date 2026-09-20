// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `reconnect()` on a `viaSocket` transport destroyed a working connection to
// learn a fact fixed at CONSTRUCTION.
//
// `viaSocket` wraps a socket the caller opened, so there is nothing to
// reconnect to. It said so by passing
//
//     connectionFactory: () => throw ...('does not support reconnect')
//
// and `reconnect()` calls the factory LAST -- after discarding the connection,
// cancelling every stream subscription, disposing every outgoing pump and
// clearing six per-stream maps. So the only way to discover the answer was to
// make it true: every in-flight call died to produce an error that was known
// before the method was entered.
//
// The factory is now nullable, and null is checked before the teardown.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (request, {RpcContext? context}) async => 'ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  late RpcHttp2Server server;
  late Socket socket;
  late RpcHttp2CallerTransport transport;
  late RpcCallerEndpoint caller;

  setUp(() async {
    server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      onEndpointCreated: (e) {
        e.registerServiceContract(_Svc());
        e.start();
      },
    );
    await server.start();

    socket = await Socket.connect('127.0.0.1', server.port);
    transport = RpcHttp2CallerTransport.viaSocket(
      socket,
      host: '127.0.0.1',
      port: server.port,
      scheme: 'http',
    );
    caller = RpcCallerEndpoint(transport: transport);
  });

  tearDown(() async {
    await caller.close();
    await server.stop();
  });

  Future<String> call() async =>
      (await caller
              .unaryRequest<RpcString, RpcString>(
                serviceName: 'Svc',
                methodName: 'echo',
                request: 'x'.rpc,
                requestCodec: _codec,
                responseCodec: _codec,
              )
              .timeout(const Duration(seconds: 10)))
          .value;

  test('a refused reconnect leaves the connection working', () async {
    expect(await call(), 'ok');

    final health = await transport.reconnect();

    expect(
      health.details['supported'],
      isFalse,
      reason: 'viaSocket cannot rebuild the socket it was handed',
    );
    expect(
      await call(),
      'ok',
      reason:
          'the connection was torn down to discover something known at '
          'construction: every in-flight call died to produce that answer',
    );
  });

  // GUARD: the refusal must not be mistaken for a healthy reconnect.
  test('GUARD: the refusal is not reported as healthy', () async {
    final health = await transport.reconnect();

    expect(health.isHealthy, isFalse);
    expect(transport.isClosed, isFalse, reason: 'refused, not closed');
  });

  // GUARD: asking twice is still safe and still non-destructive.
  test('GUARD: a second refused reconnect also leaves it working', () async {
    await transport.reconnect();
    await transport.reconnect();

    expect(await call(), 'ok');
  });
}
