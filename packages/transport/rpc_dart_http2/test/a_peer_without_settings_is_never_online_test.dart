// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcHttp2CallerTransport.connect returns once the socket is up, before the
// peer has sent SETTINGS, and RpcClientConnection reported Online, with
// health() healthy, for a peer that never speaks HTTP/2. The transport now
// exposes IRpcTransportReadiness, completed by the first SETTINGS.

@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

RpcClientConnection _connection(int port) {
  final connection = RpcClientConnection(
    maxAttempts: 1,
    connectTimeout: const Duration(seconds: 2),
    transportFactory: () =>
        RpcHttp2CallerTransport.connect(host: '127.0.0.1', port: port),
  );
  addTearDown(connection.dispose);
  return connection;
}

void main() {
  test('WITNESS a peer that never sends SETTINGS is never Online', () async {
    final silent = await ServerSocket.bind('127.0.0.1', 0);
    final held = <Socket>[];
    silent.listen((s) {
      held.add(s);
      s.listen((_) {});
    });
    addTearDown(() async {
      for (final s in held) {
        s.destroy();
      }
      await silent.close();
    });

    final connection = _connection(silent.port);
    final states = <RpcClientConnectionState>[];
    final sub = connection.state.listen(states.add);
    addTearDown(sub.cancel);
    connection.connect();

    // The attempt's 2 s connectTimeout ends it; 4 s covers that.
    await Future<void>.delayed(const Duration(seconds: 4));
    expect(states.last, isA<RpcClientDisconnected>(), reason: '$states');
    expect(
      states.whereType<RpcClientOnline>(),
      isEmpty,
      reason: 'Online was reported for a peer that never sent SETTINGS',
    );
  });

  test('an HTTP/2 server reads Online and healthy', () async {
    final server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      onEndpointCreated: (_) {},
    );
    await server.start();
    addTearDown(server.stop);

    final connection = _connection(server.port);
    connection.connect();
    await connection.state
        .firstWhere((s) => s is RpcClientOnline)
        .timeout(const Duration(seconds: 10));
    final health = await connection.transport.health();
    expect(health.isHealthy, isTrue, reason: '$health');
  });
}
