// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The session id a handshake returns is the collector's own id for that
// connection, so two connections get two ids.
@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_log/rpc_dart_log_server.dart';
import 'package:rpc_dart_log/src/contract/log_collector_contract.dart';
import 'package:rpc_dart_log/src/contract/messages.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test('each connection is welcomed with its server session id', () async {
    final server = LogCollectorServer(host: '127.0.0.1', port: 0);
    await server.start();
    addTearDown(server.stop);

    Future<int> handshake(String device) async {
      final channel = WebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:${server.boundPort}'),
      );
      await channel.ready;
      final endpoint = RpcCallerEndpoint(
        transport: RpcWebSocketCallerTransport(channel),
      );
      addTearDown(endpoint.close);
      final welcome = await LogCollectorServiceCaller(
        endpoint,
      ).handshake(LogCollectorHandshake(deviceName: device, app: 'app'));
      return welcome.sessionId;
    }

    final a = await handshake('a');
    final b = await handshake('b');

    expect(a, isNot(b));
    expect(
      {for (final s in server.sessions) s.deviceName: s.id},
      {'a': a, 'b': b},
    );
  });
}
