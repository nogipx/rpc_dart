// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// close() on a transport whose socket the peer accepted and never upgraded.
// The given-channel form is a row of the conformance matrix (I-5); the
// reconnect form is websocket's own, so it is pinned here.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  late ServerSocket silent;
  late HttpServer live;
  final held = <Socket>[];

  setUp(() async {
    silent = await ServerSocket.bind('127.0.0.1', 0);
    silent.listen((s) {
      held.add(s);
      s.listen((_) {}, onError: (_) {});
    });
    live = await HttpServer.bind('127.0.0.1', 0);
    live.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      ws.listen((_) {}, onError: (_) {});
    });
  });

  tearDown(() async {
    for (final s in held) {
      s.destroy();
    }
    held.clear();
    await silent.close();
    await live.close(force: true);
  });

  Uri uriOf(int port) => Uri.parse('ws://127.0.0.1:$port');

  Future<String> closeWithin(RpcWebSocketCallerTransport t) async {
    try {
      await t.close().timeout(const Duration(seconds: 2));
      return 'closed';
    } on TimeoutException {
      return 'STILL PENDING at 2 s';
    }
  }

  test(
    'a reconnect to a peer that never upgrades does not hold close()',
    () async {
      final first = WebSocketChannel.connect(uriOf(live.port));
      await first.ready;
      final t = RpcWebSocketCallerTransport(
        first,
        reconnectFactory: () async =>
            WebSocketChannel.connect(uriOf(silent.port)),
      );
      await t.reconnect();
      // The reconnect's socket is accepted: the handshake is what is unanswered.
      while (held.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await closeWithin(t), 'closed');
    },
  );

  test('a channel whose upgrade was answered still closes', () async {
    final t = RpcWebSocketCallerTransport(
      WebSocketChannel.connect(uriOf(live.port)),
    );
    await t.ready;
    expect(await closeWithin(t), 'closed');
  });
}
