// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcClientConnection learns of a drop from its transport's message stream
// ending, or from IRpcConnectionLossReporting. RpcHttp2CallerTransport keeps
// that stream open across a drop so its own reconnect() can re-attach, and
// package:http2 reports no connection end at all, so the transport notices the
// socket ending and reports it on `connectionLost`. These tests restart the
// server on the same port.

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
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

Future<RpcHttp2Server> _serve(int port) async {
  final server = RpcHttp2Server(
    host: '127.0.0.1',
    port: port,
    onEndpointCreated: (e) => e.registerServiceContract(_Echo()),
  );
  await server.start();
  return server;
}

Future<RpcString> _call(RpcCallerEndpoint caller) =>
    caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Echo',
      methodName: 'u',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );

/// Calls until one succeeds. A client reconnecting to a closed loopback port
/// in the ephemeral range can connect to ITSELF, which reads as a brief
/// online, so the first online after the restart is not proof enough.
Future<RpcString> _eventually(RpcCallerEndpoint caller) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (true) {
    try {
      return await _call(caller).timeout(const Duration(seconds: 2));
    } catch (_) {
      if (DateTime.now().isAfter(deadline)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

void main() {
  test(
    'WITNESS a dropped connection is noticed and comes back with the server',
    () async {
      var server = await _serve(0);
      final port = server.port;
      final connection = RpcClientConnection(
        transportFactory: () =>
            RpcHttp2CallerTransport.connect(host: '127.0.0.1', port: port),
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

      server = await _serve(port);
      expect((await _eventually(caller)).value, 'x');
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'GUARD the bare transport still reconnects with reconnect()',
    () async {
      var server = await _serve(0);
      final port = server.port;
      final transport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: port,
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
      var losses = 0;
      final lossSub = transport.connectionLost.listen((_) => losses++);
      addTearDown(lossSub.cancel);
      await server.stop();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (losses == 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(losses, 1);
      expect(transport.isClosed, isFalse);
      expect(streamErrors, isEmpty);

      server = await _serve(port);
      final health = await transport.reconnect();
      expect(health.isHealthy, isTrue, reason: health.message);
      expect((await _call(caller)).value, 'x');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        losses,
        1,
        reason:
            'reconnect() retires the old connection itself; its end is not '
            'a loss to report',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
