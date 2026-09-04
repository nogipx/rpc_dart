// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcWebSocketCallerTransport.reconnect() checked `_closed` before its awaits
// and then called _attach(ws) once the factory resolved, without re-checking.
// Opening a socket takes real time -- a handshake is tens to hundreds of ms --
// so close() lands inside that window routinely. Attaching anyway handed a live
// socket to a transport that was already closed: `_incomingCtl` is shut so
// nothing is delivered, and nothing holds the socket, so it could never be
// closed.
//
// Measured against a real WebSocket server counting live connections, with a
// 150ms factory and close() 30ms in:
//
//   control, plain connect + close : opened=1 closed=1  (socket released)
//   close during reconnect, before : opened=3 closed=2  (1 left open)
//   close during reconnect, after  : opened=3 closed=3  (nothing left)
//
// Same defect as RpcClientConnection in core (commit 334b3337), whose connect
// loop also checked "stopped" before the await and not after.
//
// The control matters: an early version of this measurement counted closes via
// `ws.done.whenComplete` and reported the CONTROL as leaking too, which was the
// harness rather than the library. Counting on the socket stream's onDone is
// what made the result trustworthy.

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Counts sockets the SERVER sees, which is the only place a socket the client
/// has lost track of is still visible.
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

  Future<WebSocketChannel> connect() async =>
      IOWebSocketChannel(await WebSocket.connect(uri.toString()));

  Future<void> stop() => _server.close(force: true);
}

/// Long enough that close() can reliably land inside the window.
Future<WebSocketChannel> Function() _slowFactory(_CountingServer server) =>
    () async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      return server.connect();
    };

void main() {
  late _CountingServer server;

  setUp(() async {
    server = await _CountingServer.start();
  });

  tearDown(() async {
    await server.stop();
  });

  group('close() during an in-flight reconnect', () {
    // WITNESS: this left one socket open with nothing able to close it.
    test('does not leave the new socket open', () async {
      final transport = RpcWebSocketCallerTransport(
        await server.connect(),
        reconnectFactory: _slowFactory(server),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final reconnecting = transport.reconnect();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await transport.close();
      await reconnecting;

      await Future<void>.delayed(const Duration(milliseconds: 800));

      expect(
        server.live,
        0,
        reason:
            '${server.live} socket(s) still open on the server after close(): '
            'the transport attached a socket it had already stopped owning',
      );
    });

    test('reports that it was closed rather than healthy', () async {
      final transport = RpcWebSocketCallerTransport(
        await server.connect(),
        reconnectFactory: _slowFactory(server),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final reconnecting = transport.reconnect();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await transport.close();
      final status = await reconnecting;

      expect(
        status.isHealthy,
        isFalse,
        reason: 'a reconnect abandoned by close() must not report healthy',
      );
    });
  });

  group('the ordinary paths are unaffected', () {
    // GUARD: without this the witness above proves nothing -- it must be
    // possible to release a socket at all.
    test('a plain connect + close releases the socket', () async {
      final transport = RpcWebSocketCallerTransport(await server.connect());
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await transport.close();
      await Future<void>.delayed(const Duration(milliseconds: 800));

      expect(server.live, 0);
    });

    // GUARD: a reconnect nobody interrupts must still attach and be usable.
    test('an uninterrupted reconnect succeeds', () async {
      final transport = RpcWebSocketCallerTransport(
        await server.connect(),
        reconnectFactory: _slowFactory(server),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final status = await transport.reconnect();
      expect(status.isHealthy, isTrue, reason: 'reconnect did not attach');

      // The replacement is live; the old one is gone.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(server.live, 1);

      await transport.close();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(server.live, 0, reason: 'close() must release the new socket too');
    });
  });
}
