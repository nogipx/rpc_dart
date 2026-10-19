// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// An upgrade still in flight when the consumer cancels the connections stream
// completes afterwards. Nothing will ever take that socket, so it is closed
// rather than dropped with the connection still open.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart_websocket/io.dart';
import 'package:test/test.dart';

void main() {
  test('a socket upgraded after the cancel is closed', () async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => http.close(force: true));

    final upgrading = Completer<void>();
    final release = Completer<void>();
    final connections = rpcWebSocketConnections(
      http,
      pingInterval: null,
      // Holds the upgrade open, so the cancel lands while it is in flight.
      protocolSelector: (protocols) async {
        upgrading.complete();
        await release.future;
        return protocols.first;
      },
    );
    final subscription = connections.listen((_) {});

    final client = WebSocket.connect(
      'ws://127.0.0.1:${http.port}/',
      protocols: ['rpc'],
    );
    await upgrading.future.timeout(const Duration(seconds: 5));
    await subscription.cancel();
    release.complete();

    final socket = await client.timeout(const Duration(seconds: 5));
    final closed = socket.listen((_) {}).asFuture<void>();
    await expectLater(
      closed.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          unawaited(socket.close());
          fail('the server kept a socket nothing will ever read');
        },
      ),
      completes,
    );
  });
}
