// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Nothing in this transport runs when the PEER dies on its own -- there is no
// callback to set a flag in -- so health() answered from its own bookkeeping
// and reported the transport as ready with the server gone:
//
//   isClosed        : false
//   health          : HTTP/2 transport ready      <-- the peer was gone
//   call after death: caught StateError
//
// The call already failed honestly; only the report was wrong. That is the
// half that matters for recovery, because a supervisor decides whether to
// reconnect by polling health() -- and would never reconnect.
//
// health() now asks the connection (`ClientTransportConnection.isOpen`) instead
// of assuming. Sibling defect to the websocket caller's, found by running the
// same battery against both.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (request, {RpcContext? context}) async => 'echo-ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Future<String> _echo(RpcCallerEndpoint caller) async {
  try {
    final r = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 5));
    return r.value;
  } on TimeoutException {
    return 'HUNG';
  } catch (e) {
    return 'caught: $e';
  }
}

void main() {
  test('health() reports a dead peer instead of "ready"', () async {
    final server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      onEndpointCreated: (e) => e.registerServiceContract(_Contract()),
    );
    await server.start();
    final client = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: server.port,
    );
    final caller = RpcCallerEndpoint(transport: client);
    addTearDown(() async {
      await caller.close();
      await client.close();
    });

    expect(await _echo(caller), 'echo-ok');
    expect((await client.health()).message, contains('ready'));

    await server.stop();
    await Future<void>.delayed(const Duration(seconds: 1));

    final health = await client.health();
    expect(
      health.message,
      contains('Reconnect is required'),
      reason:
          'a supervisor polls health() to decide whether to reconnect, and was '
          'told the transport was ready while the server was gone',
    );
    expect(health.message, isNot(contains('ready')));
    expect(
      client.isClosed,
      isFalse,
      reason: 'the caller never closed it; this is recoverable',
    );
  });

  test('GUARD: a live transport still reports ready, repeatedly', () async {
    // The check runs on every health() call, so the healthy path must stay
    // healthy -- including after calls have been made and streams retired.
    final server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      onEndpointCreated: (e) => e.registerServiceContract(_Contract()),
    );
    await server.start();
    addTearDown(server.stop);
    final client = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: server.port,
    );
    final caller = RpcCallerEndpoint(transport: client);
    addTearDown(() async {
      await caller.close();
      await client.close();
    });

    for (var i = 0; i < 5; i++) {
      expect(await _echo(caller), 'echo-ok', reason: 'round $i');
      expect((await client.health()).message, contains('ready'));
    }
  });

  test(
    'GUARD: a closed transport still reports closed, not degraded',
    () async {
      final server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (e) => e.registerServiceContract(_Contract()),
      );
      await server.start();
      addTearDown(server.stop);
      final client = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
      );

      await client.close();

      expect(client.isClosed, isTrue);
      expect((await client.health()).message, contains('closed'));
    },
  );
}
