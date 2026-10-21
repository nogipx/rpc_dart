// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `IRpcServer.endpoints` lists the endpoint of every live connection in either
// mode. A peer-mode server's endpoints are RpcPeerEndpoints, which are
// RpcResponderEndpoints that can also start calls, so they belong in that list
// like a responder-mode server's do.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late HttpServer http;
  late RpcWebSocketServer server;

  tearDown(() async {
    await server.dispose().catchError((Object _) {});
    await http.close(force: true);
  });

  for (final peer in [true, false]) {
    final name = peer ? 'peer' : 'responder';
    test('a $name-mode server lists each live connection', () async {
      http = await HttpServer.bind('127.0.0.1', 0);
      server = RpcWebSocketServer(
        connections: rpcWebSocketConnections(http),
        mode: peer ? RpcPeerMode((_) {}) : RpcResponderMode((_) {}),
      );
      await server.start();

      final transport = await RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://127.0.0.1:${http.port}'),
      );
      await _until(() => server.endpoints.isNotEmpty);

      expect(
        server.endpoints,
        hasLength(1),
        reason: 'the server holds one live connection',
      );
      expect(
        server.endpoints.single,
        peer ? isA<RpcPeerEndpoint>() : isNot(isA<RpcPeerEndpoint>()),
      );

      await transport.close();
      await _until(() => server.endpoints.isEmpty);
      expect(server.endpoints, isEmpty);
    });
  }
}
