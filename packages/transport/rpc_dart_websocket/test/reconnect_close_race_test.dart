// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcClientConnection.dispose() landing while a reconnect is still opening its
// socket. Opening a websocket takes real time -- a handshake is tens to
// hundreds of ms -- so dispose() lands inside that window routinely. The
// transport the factory returns afterwards belongs to a connection that is
// already gone: nothing can deliver its messages, and nothing else holds it,
// so unless the connection closes it on arrival its socket is never released.
//
// Counted on a real WebSocket server, which is the only place a socket the
// client has lost track of is still visible. Closes are counted on the socket
// stream's onDone: counting via `ws.done` reports the control as leaking too.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

/// Counts sockets the SERVER sees.
class _CountingServer {
  _CountingServer(this._server);

  final HttpServer _server;
  int opened = 0;
  int closed = 0;

  int get live => opened - closed;
  Uri get uri => Uri.parse('ws://127.0.0.1:${_server.port}');

  static Future<_CountingServer> start() async {
    final http = await HttpServer.bind('127.0.0.1', 0);
    final server = _CountingServer(http);
    http.transform(WebSocketTransformer()).listen((ws) {
      server.opened++;
      ws.listen(
        (_) {},
        onError: (Object _) => server.closed++,
        onDone: () => server.closed++,
      );
    });
    return server;
  }

  Future<void> stop() => _server.close(force: true);
}

/// A connection whose factory is fast for the first connect and [slow] after,
/// so dispose() can reliably land inside a reconnect's handshake.
({RpcClientConnection connection, void Function() slowDown}) _connection(
  _CountingServer server,
) {
  var slow = false;
  final connection = RpcClientConnection(
    transportFactory: () async {
      if (slow) await Future<void>.delayed(const Duration(milliseconds: 150));
      return RpcWebSocketCallerTransport.connect(server.uri);
    },
  );
  return (connection: connection, slowDown: () => slow = true);
}

Future<void> _online(RpcClientConnection connection, void Function() go) {
  final online = connection.state
      .firstWhere((s) => s is RpcClientOnline)
      .timeout(const Duration(seconds: 10));
  go();
  return online;
}

void main() {
  late _CountingServer server;

  setUp(() async {
    server = await _CountingServer.start();
  });

  tearDown(() async {
    await server.stop();
  });

  // WITNESS: the transport that arrives after dispose() must be closed.
  test(
    'dispose() during a reconnect does not leave the new socket open',
    () async {
      final rig = _connection(server);
      await _online(rig.connection, rig.connection.connect);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      rig.slowDown();
      rig.connection.forceReconnect();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await rig.connection.dispose();

      // Past the factory's delay and the handshake, then time for the close.
      await Future<void>.delayed(const Duration(milliseconds: 800));

      expect(
        server.opened,
        2,
        reason:
            'the reconnect must have opened its socket for this to say anything',
      );
      expect(
        server.live,
        0,
        reason:
            '${server.live} socket(s) still open on the server after dispose(): '
            'a transport built for a disposed connection was kept',
      );
      expect(rig.connection.currentState, isNot(isA<RpcClientOnline>()));
    },
  );

  group('the ordinary paths are unaffected', () {
    // GUARD: without this the witness above proves nothing -- it must be
    // possible to release a socket at all.
    test('a plain connect + close releases the socket', () async {
      final transport = await RpcWebSocketCallerTransport.connect(server.uri);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await transport.close();
      await Future<void>.delayed(const Duration(milliseconds: 800));

      expect(server.live, 0);
    });

    // GUARD: a reconnect nobody interrupts must still attach and be usable.
    test('an uninterrupted reconnect succeeds', () async {
      final rig = _connection(server);
      await _online(rig.connection, rig.connection.connect);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      rig.slowDown();
      await _online(rig.connection, rig.connection.forceReconnect);
      expect((await rig.connection.transport.health()).isHealthy, isTrue);

      // The replacement is live; the old one is gone.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(server.live, 1);

      await rig.connection.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(
        server.live,
        0,
        reason: 'dispose() must release the new socket too',
      );
    });
  });
}
