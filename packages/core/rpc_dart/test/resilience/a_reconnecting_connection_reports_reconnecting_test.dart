// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcClientConnection is the one layer that reconnects, so its transport is
// the one place a reconnect can be reported. While the connect loop runs the
// transport is reconnecting, which the framework reads as degraded; once the
// loop has stopped it is unhealthy.

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

void main() {
  test('the transport is reconnecting while the connect loop runs', () async {
    final never = Completer<IRpcTransport>();
    final connection = RpcClientConnection(
      transportFactory: (_) => never.future,
      connectTimeout: const Duration(seconds: 30),
    );
    addTearDown(connection.dispose);
    final connecting = connection.state.firstWhere(
      (s) => s is RpcClientConnecting,
    );
    connection.connect();
    await connecting.timeout(const Duration(seconds: 5));

    final health = await connection.transport.health();
    expect(health.level, RpcHealthLevel.reconnecting);
  });

  test('GUARD the transport is unhealthy when no loop runs', () async {
    final connection = RpcClientConnection(
      transportFactory: (_) => Completer<IRpcTransport>().future,
    );
    addTearDown(connection.dispose);

    final health = await connection.transport.health();
    expect(health.level, RpcHealthLevel.unhealthy);
  });
}
