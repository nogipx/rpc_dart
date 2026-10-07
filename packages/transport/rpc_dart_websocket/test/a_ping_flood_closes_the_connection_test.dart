// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// dart:io answers every ping with a pong queued on an unbounded write buffer.
// A client that floods pings and never reads made the server hold a pong per
// ping: one deaf connection grew the server by about 3 GiB in ten seconds.
// The frame guard now rate-limits pings and drops a client past the limit.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

/// A masked frame with [opcode] and [payload] zero bytes.
Uint8List _frame(int opcode, int payload) => Uint8List.fromList([
  0x80 | opcode,
  0x80 | payload,
  1,
  2,
  3,
  4,
  ...List<int>.filled(payload, 0),
]);

/// Upgrades a raw socket by hand and returns it, unread from then on.
Future<Socket> _upgrade(int port) async {
  final socket = await Socket.connect('127.0.0.1', port);
  socket.write(
    'GET / HTTP/1.1\r\n'
    'Host: 127.0.0.1:$port\r\n'
    'Upgrade: websocket\r\n'
    'Connection: Upgrade\r\n'
    'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
    'Sec-WebSocket-Version: 13\r\n\r\n',
  );
  await socket.flush();
  return socket;
}

void main() {
  test(
    'WITNESS a client flooding pings is dropped',
    () async {
      final http = await HttpServer.bind('127.0.0.1', 0);
      final closed = Completer<void>();
      final server = RpcWebSocketServer(
        connections: rpcWebSocketConnections(http),
        onConnectionClosed: (_) {
          if (!closed.isCompleted) closed.complete();
        },
      );
      await server.start();
      addTearDown(() async {
        await server.stop();
        await http.close(force: true);
      });

      final socket = await _upgrade(http.port);
      addTearDown(socket.destroy);
      // Never read: the pongs pile up on the server unless it drops us.
      socket.listen(null).pause();
      final ping = _frame(9, 125);
      try {
        for (var i = 0; i < 4096; i++) {
          socket.add(ping);
        }
        await socket.flush();
      } on SocketException {
        // The server may already have closed it.
      }

      await closed.future.timeout(const Duration(seconds: 10));
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
