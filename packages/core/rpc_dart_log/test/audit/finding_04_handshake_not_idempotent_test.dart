// Audit finding 4: _handleHandshake is not idempotent.
//
// log_server.dart:154-164. Each handshake unconditionally allocates a new
// session id, inserts into _sessions and _endpointSessions[endpoint] (clobbering
// the previous mapping for that endpoint), and fires DeviceConnected. A second
// handshake on the SAME endpoint therefore:
//   - leaks the first session (it stays in _sessions, never disconnected)
//   - overwrites _endpointSessions[endpoint] so disconnect only removes session #2
//   - fires a spurious DeviceConnected with no matching DeviceDisconnected
//
// We drive a real client connection and call handshake() twice on it.
// CORRECT behavior: exactly ONE active session and ONE DeviceConnected event for
// one physical connection. If we see 2 sessions / 2 connect events -> CONFIRMED.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_log/rpc_dart_log_server.dart';
import 'package:rpc_dart_log/src/contract/log_caller.dart';
import 'package:rpc_dart_log/src/contract/messages.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  group('finding 4: handshake idempotency', () {
    late LogCollectorServer server;

    setUp(() async {
      server = LogCollectorServer(host: '127.0.0.1', port: 0);
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    test(
      'two handshakes on one connection -> one session, one connect event',
      () async {
        final connects = <DeviceConnected>[];
        server.onConnection.listen((e) {
          if (e is DeviceConnected) connects.add(e);
        });

        // Raw client (not LogCollectorOutput) so we control handshake count.
        final channel = WebSocketChannel.connect(
          Uri.parse('ws://127.0.0.1:${server.boundPort}'),
        );
        await channel.ready;
        final transport = RpcWebSocketCallerTransport(channel);
        final endpoint = RpcCallerEndpoint(transport: transport);
        endpoint.start();
        final caller = LogCollectorServiceCaller(endpoint);

        await caller.handshake(
          const LogCollectorHandshake(deviceName: 'devA', app: 'appA'),
        );
        await caller.handshake(
          const LogCollectorHandshake(deviceName: 'devA-again', app: 'appA'),
        );

        // Let events settle.
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(
          server.sessions.length,
          1,
          reason:
              'second handshake leaked a session; active sessions=${server.sessions.map((s) => s.deviceName).toList()}',
        );
        expect(
          connects.length,
          1,
          reason:
              'second handshake fired a spurious DeviceConnected with no matching disconnect; '
              'connects=${connects.map((c) => c.session.deviceName).toList()}',
        );

        await endpoint.close();
        await transport.close();
      },
    );
  });
}
