// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The README offers the constructor for a WebSocketChannel the caller built
// itself, and `IOWebSocketChannel.connect` returns before the handshake. When
// that connect fails, web_socket_channel completes `ready` with the error, and
// a `ready` nobody listens to is an uncaught error: in an app, the root zone,
// which ends the isolate. The transport owns the channel from the
// constructor on, and it learns of the failure from the stream anyway, so it
// observes `ready` itself.

@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

void main() {
  test(
    'WITNESS a channel whose connect fails closes the transport, quietly',
    () async {
      // A port that was just free.
      final probe = await ServerSocket.bind('127.0.0.1', 0);
      final port = probe.port;
      await probe.close();

      final transport = RpcWebSocketCallerTransport(
        IOWebSocketChannel.connect(Uri.parse('ws://127.0.0.1:$port')),
      );
      addTearDown(transport.close);

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!transport.isClosed && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        transport.isClosed,
        isTrue,
        reason:
            'the failed connect ends the stream, which closes the transport',
      );
    },
  );
}
