// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A transport built on a channel that is still connecting is returned at
// once, and RpcClientConnection reported Online as soon as its factory
// returned one: every failed attempt flapped Online -> Offline. The transport
// now exposes IRpcTransportReadiness, and the connection waits on it.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

Future<RpcClientConnection> _connection(Uri uri) async {
  final connection = RpcClientConnection(
    maxAttempts: 3,
    backoff: const ExponentialBackoff(
      baseDelay: Duration(milliseconds: 50),
      jitter: false,
    ),
    transportFactory: () async =>
        RpcWebSocketCallerTransport(IOWebSocketChannel.connect(uri)),
  );
  addTearDown(connection.dispose);
  return connection;
}

void main() {
  test('WITNESS a channel that never connects is never Online', () async {
    final free = await ServerSocket.bind('127.0.0.1', 0);
    final port = free.port;
    await free.close();

    final connection = await _connection(Uri.parse('ws://127.0.0.1:$port'));
    final states = <RpcClientConnectionState>[];
    final sub = connection.state.listen(states.add);
    addTearDown(sub.cancel);
    connection.connect();

    await connection.state
        .firstWhere((s) => s is RpcClientDisconnected)
        .timeout(const Duration(seconds: 20));
    expect(
      states.whereType<RpcClientOnline>(),
      isEmpty,
      reason: 'Online was reported for a channel that never connected',
    );
  });

  test('a channel that connects reads Online and healthy', () async {
    final http = await HttpServer.bind('127.0.0.1', 0);
    final server = RpcWebSocketServer(
      connections: rpcWebSocketConnections(http),
      onEndpointCreated: (e) => e.start(),
    );
    await server.start();
    addTearDown(() async {
      await server.stop();
      await http.close(force: true);
    });

    final connection = await _connection(
      Uri.parse('ws://127.0.0.1:${http.port}'),
    );
    connection.connect();
    await connection.state
        .firstWhere((s) => s is RpcClientOnline)
        .timeout(const Duration(seconds: 10));
    final health = await connection.transport.health();
    expect(health.isHealthy, isTrue, reason: '$health');
  });
}
