// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// reconnect() was hardened against close() landing mid-flight, but not against
// ITSELF. Two overlapping calls each closed `_inner`, each awaited the factory,
// and each called _attach -- so the second overwrote `_inner` and `_fwdSub`
// while the FIRST socket was already attached and live. Nothing referenced it
// afterwards, so nothing could ever close it.
//
// Measured against a real server counting connections, with a 150ms factory,
// after close():
//
//   one reconnect (control) : opened=2 closed=2 live=0
//   two concurrent          : opened=3 closed=2 live=1
//   three concurrent        : opened=4 closed=2 live=2
//
// One orphan per extra attempt. On a server each of those also pins an endpoint
// and the contracts registered on it.
//
// The trigger is ordinary: a supervisor polling health() and calling
// reconnect() on a timer, where one slow handshake outlives the tick.
//
// Joining the in-flight attempt is the fix rather than refusing the second
// call: every caller asked for the same thing -- a working connection -- so
// they all learn the outcome of the one attempt that actually ran.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  late HttpServer http;
  late Uri uri;
  var opened = 0;
  var closed = 0;

  setUp(() async {
    opened = 0;
    closed = 0;
    http = await HttpServer.bind('127.0.0.1', 0);
    http.transform(WebSocketTransformer()).listen((ws) {
      opened++;
      ws.listen(
        (_) {},
        onError: (Object _) {},
        onDone: () => closed++,
        cancelOnError: false,
      );
    });
    uri = Uri.parse('ws://127.0.0.1:${http.port}');
  });

  tearDown(() => http.close(force: true));

  /// Slow enough that concurrent attempts genuinely overlap.
  Future<WebSocketChannel> slowFactory() async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final ch = IOWebSocketChannel.connect(uri);
    await ch.ready;
    return ch;
  }

  /// Live connections the server still holds. Polled to let closes land.
  Future<int> liveConnections() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline) && opened - closed > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return opened - closed;
  }

  Future<RpcWebSocketCallerTransport> connected() async {
    return RpcWebSocketCallerTransport(
      await slowFactory(),
      reconnectFactory: slowFactory,
    );
  }

  test(
    'concurrent reconnects do not orphan a socket',
    () async {
      final transport = await connected();

      // Both start before either finishes.
      await Future.wait([transport.reconnect(), transport.reconnect()]);
      await transport.close();

      expect(
        await liveConnections(),
        0,
        reason:
            'the losing attempt attached a live socket that was then overwritten '
            'and never closed -- nothing referenced it afterwards',
      );
      expect(
        opened,
        2,
        reason:
            'callers asking at the same time want one connection, not one each',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'it does not scale with the number of callers',
    () async {
      // The leak was one orphan per EXTRA attempt, so more callers made it worse.
      final transport = await connected();

      await Future.wait([
        transport.reconnect(),
        transport.reconnect(),
        transport.reconnect(),
        transport.reconnect(),
      ]);
      await transport.close();

      expect(await liveConnections(), 0);
      expect(opened, 2);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'every caller is told the outcome of the attempt that ran',
    () async {
      final transport = await connected();

      final results = await Future.wait([
        transport.reconnect(),
        transport.reconnect(),
        transport.reconnect(),
      ]);
      addTearDown(transport.close);

      for (final r in results) {
        expect(
          r.level,
          RpcHealthLevel.healthy,
          reason: 'joining an attempt must report its real result',
        );
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: a later reconnect still opens a new connection',
    () async {
      // The in-flight marker must clear, or the transport could reconnect only
      // once and every later attempt would silently reuse a finished result.
      final transport = await connected();

      final first = await transport.reconnect();
      expect(first.level, RpcHealthLevel.healthy);
      expect(opened, 2);

      final second = await transport.reconnect();
      expect(second.level, RpcHealthLevel.healthy);
      expect(opened, 3, reason: 'a sequential reconnect is a real one');

      await transport.close();
      expect(await liveConnections(), 0);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: a single reconnect is unaffected',
    () async {
      final transport = await connected();
      final r = await transport.reconnect();
      expect(r.level, RpcHealthLevel.healthy);
      await transport.close();
      expect(await liveConnections(), 0);
      expect(opened, 2);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
