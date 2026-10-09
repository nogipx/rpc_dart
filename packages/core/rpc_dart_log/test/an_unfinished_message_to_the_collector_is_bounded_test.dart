// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The collector upgrades through rpcWebSocketConnections, so a message that
// never ends is cut at the policy's message ceiling instead of being
// assembled by dart:io for as long as the peer writes.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rpc_dart_log/rpc_dart_log_server.dart';
import 'package:test/test.dart';

const _frame = 1024 * 1024;
const _frames = 64;

void main() {
  test('WITNESS the collector drops a peer whose message never ends', () async {
    final server = LogCollectorServer(port: 0);
    await server.start();
    addTearDown(server.stop);

    final socket = await Socket.connect('127.0.0.1', server.boundPort!);
    addTearDown(socket.destroy);
    final key = base64.encode(List<int>.generate(16, (i) => i));
    socket.write(
      'GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n'
      'Upgrade: websocket\r\nConnection: Upgrade\r\n'
      'Sec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\n\r\n',
    );
    final upgraded = Completer<void>();
    final closed = Completer<void>();
    socket.listen(
      (data) {
        if (!upgraded.isCompleted && latin1.decode(data).contains(' 101 ')) {
          upgraded.complete();
        }
      },
      onError: (Object _) {
        if (!closed.isCompleted) closed.complete();
      },
      onDone: () {
        if (!closed.isCompleted) closed.complete();
      },
    );
    await upgraded.future.timeout(const Duration(seconds: 5));

    // Binary frames with FIN clear, masked with a zero key.
    Uint8List header(bool first) => Uint8List.fromList([
      first ? 0x02 : 0x00,
      0x80 | 127,
      0,
      0,
      0,
      0,
      0,
      _frame >> 16 & 0xff,
      _frame >> 8 & 0xff,
      _frame & 0xff,
      0,
      0,
      0,
      0,
    ]);
    final payload = Uint8List(_frame);
    var sent = 0;
    unawaited(() async {
      for (var i = 0; i < _frames && !closed.isCompleted; i++) {
        try {
          socket
            ..add(header(i == 0))
            ..add(payload);
          await socket.flush().timeout(const Duration(seconds: 3));
        } catch (_) {
          return;
        }
        sent++;
      }
    }());

    await closed.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () => fail(
        'the collector kept the connection after $sent MiB of one message',
      ),
    );
    expect(sent, lessThan(_frames));
  });
}
