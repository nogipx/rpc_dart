// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A throwing RpcResponderMode register callback leaked the endpoint
// permanently.
//
// _handleConnection registers the endpoint BEFORE calling the user callback,
// and installs the `sink.done` release wiring only AFTER it:
//
//   _endpoints.add(endpoint);
//   register(endpoint);                   // <-- user code, can throw
//   endpoint.start();
//   channel.sink.done.then(_releaseEndpoint)
//
// so a throw left the endpoint registered, never started, with nothing able to
// reclaim it. The catch closed the socket, but the socket closing could not
// help: the hook that reacts to it had not been attached yet.
//
// Measured with a callback that throws on every connection, three connections:
//
//   endpoints held      : 3   (want 0)
//   contracts disposed  : 0   (want 3)
//
// The PEER branch leaked identically. Each branch is asserted on disposal as
// well as on the list: the list says what the server holds, the disposal that
// the contracts were let go.
//
// A throwing register callback is ordinary rather than exotic: that callback is
// where the application registers its contracts, so a DI failure, a duplicate
// registration or a bad config lands exactly there.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

final _codec = RpcCodec(RpcString.fromJson);

var _disposed = 0;

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (request, {RpcContext? context}) async => 'echo-ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }

  @override
  void dispose() => _disposed++;
}

void main() {
  late HttpServer http;
  late RpcWebSocketServer server;
  late Uri uri;

  setUp(() {
    _disposed = 0;
  });

  tearDown(() async {
    await server.stop().catchError((Object _) {});
    await http.close(force: true);
  });

  /// Opens [count] connections and lets each fail, then closes them.
  Future<void> connectAndDrop(int count) async {
    for (var i = 0; i < count; i++) {
      final ch = IOWebSocketChannel.connect(uri);
      await ch.ready;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await ch.sink.close().catchError((Object _) {});
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }

  test(
    'a throwing responder register callback releases the endpoint',
    () async {
      http = await HttpServer.bind('127.0.0.1', 0);
      server = RpcWebSocketServer(
        connections: rpcWebSocketConnections(http),
        mode: RpcResponderMode((e) {
          e.registerServiceContract(_Contract());
          throw StateError('DI failed while registering contracts');
        }),
      );
      await server.start();
      uri = Uri.parse('ws://127.0.0.1:${http.port}');

      await connectAndDrop(3);

      expect(
        server.endpoints,
        isEmpty,
        reason: 'the endpoint was registered before the callback that threw',
      );
      expect(
        _disposed,
        3,
        reason:
            'closing the endpoint is what disposes the contracts; without it the '
            'application keeps whatever they hold for the life of the process',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test('the PEER branch releases too', () async {
    http = await HttpServer.bind('127.0.0.1', 0);
    server = RpcWebSocketServer(
      connections: rpcWebSocketConnections(http),
      mode: RpcPeerMode((e) {
        e.registerServiceContract(_Contract());
        throw StateError('DI failed while registering contracts');
      }),
    );
    await server.start();
    uri = Uri.parse('ws://127.0.0.1:${http.port}');

    await connectAndDrop(3);

    expect(server.endpoints, isEmpty);
    expect(_disposed, 3, reason: 'peer endpoints leaked');
  }, timeout: const Timeout(Duration(seconds: 90)));

  test(
    'GUARD: the server still serves once the callback stops throwing',
    () async {
      // The failure must be per-connection, not fatal to the server.
      var fail = true;
      http = await HttpServer.bind('127.0.0.1', 0);
      server = RpcWebSocketServer(
        connections: rpcWebSocketConnections(http),
        mode: RpcResponderMode((e) {
          e.registerServiceContract(_Contract());
          if (fail) throw StateError('transient DI failure');
        }),
      );
      await server.start();
      uri = Uri.parse('ws://127.0.0.1:${http.port}');

      await connectAndDrop(2);
      fail = false;

      final transport = await RpcWebSocketCallerTransport.connect(uri);
      final caller = RpcCallerEndpoint(transport: transport);
      addTearDown(() async {
        await caller.close().catchError((Object _) {});
        await transport.close().catchError((Object _) {});
      });

      final r = await caller
          .unary<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Echo',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 8));
      expect(r.value, 'echo-ok');
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'GUARD: a healthy connection is registered and released normally',
    () async {
      http = await HttpServer.bind('127.0.0.1', 0);
      server = RpcWebSocketServer(
        connections: rpcWebSocketConnections(http),
        mode: RpcResponderMode((e) => e.registerServiceContract(_Contract())),
      );
      await server.start();
      uri = Uri.parse('ws://127.0.0.1:${http.port}');

      final transport = await RpcWebSocketCallerTransport.connect(uri);
      final caller = RpcCallerEndpoint(transport: transport);
      final r = await caller
          .unary<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Echo',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 8));
      expect(r.value, 'echo-ok');
      expect(server.endpoints, hasLength(1));

      await caller.close().catchError((Object _) {});
      await transport.close().catchError((Object _) {});
      await Future<void>.delayed(const Duration(seconds: 1));

      expect(server.endpoints, isEmpty);
      expect(_disposed, 1);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
