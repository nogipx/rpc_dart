// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A keepalive probe that was in flight on the OLD connection when reconnect()
// swapped it out may time out afterwards. It must not mark the transport --
// now on a healthy new connection -- as disconnected.
//
// The relay in front of the server stops passing the server's bytes back on
// the first connection only, so the first connection's ping is never acked
// while the second connection works.

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
      methodName: 'Echo',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Relays to [targetPort]; once [muteFirst] is called, the first
/// connection's server-to-client bytes are dropped.
final class _Relay {
  _Relay._(this.socket);

  final ServerSocket socket;
  var _connections = 0;
  var _firstMuted = false;

  void muteFirst() => _firstMuted = true;

  static Future<_Relay> start(int targetPort) async {
    final relay = _Relay._(await ServerSocket.bind('127.0.0.1', 0));
    relay.socket.listen((client) async {
      final index = ++relay._connections;
      final upstream = await Socket.connect('127.0.0.1', targetPort);
      client.listen(
        upstream.add,
        onDone: upstream.destroy,
        onError: (Object _) => upstream.destroy(),
      );
      upstream.listen(
        (data) {
          if (index == 1 && relay._firstMuted) return;
          client.add(data);
        },
        onDone: client.destroy,
        onError: (Object _) => client.destroy(),
      );
    });
    return relay;
  }
}

void main() {
  test(
    'a probe that times out after reconnect leaves the transport usable',
    () async {
      final server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
      );
      await server.start();
      final relay = await _Relay.start(server.port);
      final transport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: relay.socket.port,
        pingInterval: const Duration(milliseconds: 200),
        pingTimeout: const Duration(milliseconds: 800),
      );
      final caller = RpcCallerEndpoint(transport: transport);
      addTearDown(() async {
        await caller.close().catchError((Object _) {});
        await transport.close().catchError((Object _) {});
        await relay.socket.close();
        await server.stop().catchError((Object _) {});
      });

      Future<String> echo(String v) async {
        try {
          return (await caller
                  .unaryRequest<RpcString, RpcString>(
                    serviceName: 'Svc',
                    methodName: 'Echo',
                    request: v.rpc,
                    requestCodec: _codec,
                    responseCodec: _codec,
                  )
                  .timeout(const Duration(seconds: 5)))
              .value;
        } catch (e) {
          return 'ERR $e';
        }
      }

      expect(await echo('a'), 'a');

      // The next probe on the first connection goes unanswered...
      relay.muteFirst();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // ...and the transport moves to a second connection while it waits.
      final health = await transport.reconnect();
      expect(health.level, RpcHealthLevel.healthy);
      expect(await echo('b'), 'b');

      // Past the old probe's timeout.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(await echo('c'), 'c');
    },
  );

  test('a call after a keepalive death is UNAVAILABLE', () async {
    final server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
    );
    await server.start();
    final relay = await _Relay.start(server.port);
    final transport = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: relay.socket.port,
      pingInterval: const Duration(milliseconds: 200),
      pingTimeout: const Duration(milliseconds: 400),
    );
    final caller = RpcCallerEndpoint(transport: transport);
    addTearDown(() async {
      await caller.close().catchError((Object _) {});
      await transport.close().catchError((Object _) {});
      await relay.socket.close();
      await server.stop().catchError((Object _) {});
    });

    relay.muteFirst();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    Object? error;
    try {
      await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Echo',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      error = e;
    }
    expect(error, isA<RpcStatusException>());
    expect((error as RpcStatusException).statusCode, RpcStatus.unavailable);
  });
}
