// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `pingInterval` was accepted and DROPPED on the web. A browser owns ping/pong
// and exposes neither the interval nor the outcome, so a missing pong never
// reaches the page. Measured in round 466 against a peer that completes the
// handshake and then answers nothing, at a 300 ms interval:
//
//   ws_open_io   (dart:io honours it)   626ms to notice
//   ws_open_stub (web, drops it)        NEVER (capped at 5s)
//   CONTROL: io with no interval        NEVER
//
// So a web client on a half-open path learned only when a call reached its own
// deadline — which is OPTIONAL on this transport.
//
// The transport now runs the library's own ping at the same cadence where the
// platform will not, and answers a dead peer the way dart:io does: by closing
// the socket. `platformHandlesPing: false` is what makes that reachable from a
// VM test — the stub is the portable fallback as well as the web
// implementation, but the constant selecting them is a conditional import and
// cannot be varied at runtime.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:rpc_dart_websocket/src/websocket_io_connections.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A server that completes the upgrade and then answers NOTHING — the shape of
/// a half-open path, and the only peer against which a heartbeat can fail.
Future<HttpServer> _silentServer() async {
  final server = await HttpServer.bind('127.0.0.1', 0);
  unawaited(
    server.forEach((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((_) {}, onError: (Object _) {}, cancelOnError: false);
    }),
  );
  addTearDown(() => server.close(force: true));
  return server;
}

Future<WebSocketChannel> _connect(HttpServer server) async {
  final channel = IOWebSocketChannel.connect(
    Uri.parse('ws://127.0.0.1:${server.port}'),
  );
  await channel.ready;
  return channel;
}

/// How long until the transport reports the path is gone, or null at [cap].
Future<int?> _timeToNotice(
  RpcWebSocketCallerTransport transport, {
  required Duration cap,
}) async {
  final started = DateTime.timestamp();
  var waited = Duration.zero;
  while (waited < cap) {
    if (transport.isClosed) {
      return DateTime.timestamp().difference(started).inMilliseconds;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    waited += const Duration(milliseconds: 50);
  }
  return null;
}

void main() {
  const interval = Duration(milliseconds: 200);

  // WITNESS. Before this the web arm had no liveness signal at all: the
  // transport sat open against a peer that would never answer again.
  test(
    'a platform that drops pingInterval still notices a dead peer',
    () async {
      final server = await _silentServer();
      final transport = RpcWebSocketCallerTransport(
        await _connect(server),
        pingInterval: interval,
        platformHandlesPing: false,
      );
      transport.incomingMessages.listen((_) {}, onError: (Object _) {});
      addTearDown(() => transport.close().catchError((Object _) {}));

      final ms = await _timeToNotice(
        transport,
        cap: const Duration(seconds: 5),
      );

      expect(
        ms,
        isNotNull,
        reason:
            'the heartbeat never fired or never gave up, so a web client on a '
            'half-open path is back to waiting out a deadline that is optional '
            'on this transport',
      );
    },
  );

  // CONTROL. The same silent peer with NO interval: nothing should notice,
  // because nothing is probing. Without this, "the transport closed" is equally
  // consistent with the harness closing it for some other reason.
  test('CONTROL: with no pingInterval the same peer goes unnoticed', () async {
    final server = await _silentServer();
    final transport = RpcWebSocketCallerTransport(
      await _connect(server),
      platformHandlesPing: false,
    );
    transport.incomingMessages.listen((_) {}, onError: (Object _) {});
    addTearDown(() => transport.close().catchError((Object _) {}));

    expect(
      await _timeToNotice(transport, cap: const Duration(seconds: 2)),
      isNull,
    );
  });

  // CONTROL. On a platform that HANDLES the ping, the transport must not run a
  // second one — dart:io already pings and closes, and doubling it would double
  // the wire cost. Same interval, same silent peer, and nothing of ours fires.
  test(
    'CONTROL: where the platform handles ping, no second heartbeat runs',
    () async {
      final server = await _silentServer();
      final transport = RpcWebSocketCallerTransport(
        await _connect(server),
        pingInterval: interval,
        platformHandlesPing: true,
      );
      transport.incomingMessages.listen((_) {}, onError: (Object _) {});
      addTearDown(() => transport.close().catchError((Object _) {}));

      expect(
        await _timeToNotice(transport, cap: const Duration(seconds: 2)),
        isNull,
        reason:
            'the app-level heartbeat ran on a platform whose own ping already '
            'covers this, which is double the wire cost for nothing',
      );
    },
  );

  // WITNESS. Only SILENCE is death. `createStream` throws resourceExhausted at
  // `maxActiveStreams`, and a catch-all that read every throw as a dead peer
  // closed the connection — taking down the very calls that filled the ceiling.
  // Measured against a live responder: CLOSED at 4 of 4 held, open at 3 of 4.
  test('a full stream ceiling is not mistaken for a dead peer', () async {
    const ceiling = 4;
    final http = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => http.close(force: true));
    final server = RpcWebSocketServer(
      connections: rpcWebSocketConnections(http),
      onEndpointCreated: (_) {},
    );
    unawaited(Future<void>.sync(server.start));

    final transport = RpcWebSocketCallerTransport(
      IOWebSocketChannel(
        await WebSocket.connect('ws://127.0.0.1:${http.port}'),
      ),
      pingInterval: interval,
      platformHandlesPing: false,
      policy: const RpcSecurityPolicy(maxActiveStreams: ceiling),
    );
    transport.incomingMessages.listen((_) {}, onError: (Object _) {});
    addTearDown(() => transport.close().catchError((Object _) {}));

    final held = [for (var i = 0; i < ceiling; i++) transport.createStream()];
    addTearDown(() {
      for (final id in held) {
        transport.releaseStreamId(id);
      }
    });

    expect(
      await _timeToNotice(transport, cap: const Duration(seconds: 2)),
      isNull,
      reason:
          'the heartbeat could not mint a stream id and read that as the peer '
          'being dead, so a connection at its concurrency ceiling closes and '
          'every call holding those ids dies with it',
    );
  });

  // GUARD. A LIVE peer must survive the heartbeat — otherwise "notices a dead
  // peer" is satisfied by a transport that closes itself on a timer.
  test('GUARD: a peer that answers keeps the transport open', () async {
    final http = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => http.close(force: true));
    final server = RpcWebSocketServer(
      connections: rpcWebSocketConnections(http),
      onEndpointCreated: (_) {},
    );
    unawaited(Future<void>.sync(server.start));

    final transport = RpcWebSocketCallerTransport(
      IOWebSocketChannel(
        await WebSocket.connect('ws://127.0.0.1:${http.port}'),
      ),
      pingInterval: interval,
      platformHandlesPing: false,
    );
    transport.incomingMessages.listen((_) {}, onError: (Object _) {});
    addTearDown(() => transport.close().catchError((Object _) {}));

    expect(
      await _timeToNotice(transport, cap: const Duration(seconds: 2)),
      isNull,
      reason: 'a responder answers the ping, so the path is demonstrably alive',
    );
  });
}
