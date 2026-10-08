// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcClientConnection learns of a drop from its transport's message stream
// ending, or from IRpcConnectionLossReporting. RpcWebSocketCallerTransport
// built by connect() keeps that stream open across a drop so its own
// reconnect() can re-attach, so it reports the loss on `connectionLost`. NOT
// as an error on the message stream: that stream is public, and a listener
// without onError would take it as an uncaught error. These tests restart the
// server on the same port, which is what the README's "automatic reconnect
// with backoff" is for.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Echo extends RpcResponderContract {
  _Echo() : super('Echo');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'u',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

final class _Server {
  _Server._(this.http, this.server);

  final HttpServer http;
  final RpcWebSocketServer server;

  static Future<_Server> bind(int port) async {
    final http = await HttpServer.bind('127.0.0.1', port);
    final server = RpcWebSocketServer(
      connections: rpcWebSocketConnections(http),
      onEndpointCreated: (e) => e.registerServiceContract(_Echo()),
    );
    await server.start();
    return _Server._(http, server);
  }

  Future<void> stop() async {
    await server.stop();
    await http.close(force: true);
  }
}

Future<RpcString> _call(RpcCallerEndpoint caller) =>
    caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Echo',
      methodName: 'u',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );

void main() {
  test(
    'WITNESS a dropped connection is noticed and comes back with the server',
    () async {
      var server = await _Server.bind(0);
      final port = server.http.port;
      final connection = RpcClientConnection(
        transportFactory: () => RpcWebSocketCallerTransport.connect(
          Uri.parse('ws://127.0.0.1:$port'),
        ),
        backoff: const ExponentialBackoff(
          baseDelay: Duration(milliseconds: 50),
          maxDelay: Duration(milliseconds: 200),
          jitter: false,
        ),
      );
      final caller = RpcCallerEndpoint(transport: connection.transport);
      addTearDown(() async {
        await caller.close();
        await connection.dispose();
        await server.stop();
      });

      connection.connect();
      await connection.state
          .firstWhere((s) => s is RpcClientOnline)
          .timeout(const Duration(seconds: 5));
      expect((await _call(caller)).value, 'x');

      final offline = connection.state
          .firstWhere((s) => s is RpcClientOffline)
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => fail(
              'the server stopped and the connection still reports '
              '${connection.currentState.runtimeType}',
            ),
          );
      await server.stop();
      await offline;

      final online = connection.state
          .firstWhere((s) => s is RpcClientOnline)
          .timeout(const Duration(seconds: 10));
      server = await _Server.bind(port);
      await online;
      expect((await _call(caller)).value, 'x');
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'GUARD the bare transport still reconnects with reconnect()',
    () async {
      var server = await _Server.bind(0);
      final port = server.http.port;
      final transport = await RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://127.0.0.1:$port'),
      );
      final caller = RpcCallerEndpoint(transport: transport);
      addTearDown(() async {
        await caller.close();
        await transport.close();
        await server.stop();
      });
      expect((await _call(caller)).value, 'x');

      // The loss is reported once on connectionLost; the message stream stays
      // open and carries no error.
      final streamErrors = <Object>[];
      final sub = transport.incomingMessages.listen(
        (_) {},
        onError: streamErrors.add,
      );
      addTearDown(sub.cancel);
      final lost = transport.connectionLost.first;
      await server.stop();
      await lost.timeout(const Duration(seconds: 5));
      expect(transport.isClosed, isFalse);
      expect(streamErrors, isEmpty);

      server = await _Server.bind(port);
      final health = await transport.reconnect();
      expect(health.isHealthy, isTrue, reason: health.message);
      expect((await _call(caller)).value, 'x');
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
