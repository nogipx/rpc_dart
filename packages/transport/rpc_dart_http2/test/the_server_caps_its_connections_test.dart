// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// With maxConnections set, a connection past the cap is closed as it is
// accepted, and the ones already in are kept.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

Future<(Socket, Future<void>)> _connect(int port) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  final closed = Completer<void>();
  socket.listen(
    (_) {},
    onError: (_) {
      if (!closed.isCompleted) closed.complete();
    },
    onDone: () {
      if (!closed.isCompleted) closed.complete();
    },
  );
  return (socket, closed.future);
}

void main() {
  test('one past the cap is closed, the first stays open', () async {
    final server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      maxConnections: 1,
      pingInterval: null,
      prefaceTimeout: null,
      mode: RpcResponderMode((_) {}),
    );
    await server.start();
    addTearDown(server.stop);

    final (first, firstClosed) = await _connect(server.port);
    addTearDown(first.destroy);
    // The server has served the first before it accepts the second.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final (second, secondClosed) = await _connect(server.port);
    addTearDown(second.destroy);

    await secondClosed.timeout(const Duration(seconds: 5));
    var firstIsOpen = true;
    unawaited(firstClosed.then((_) => firstIsOpen = false));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(firstIsOpen, isTrue);
  });
}
