// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `pingInterval` is the only way to notice a half-open path, and on one of the
// two construction paths it did nothing at all.
//
// `platformHonoursPingInterval` describes what `openWebSocket` does with the
// parameter. `connect()` goes through `openWebSocket`, so on the VM the socket
// really is pinged natively and the library's own ping is correctly off. The
// plain constructor does not: a caller who builds the channel and passes
// `pingInterval:` was consulting a constant about a function nobody called, so
// dart:io was never told the interval and the app-level heartbeat was off too.
//
// Neither can be fixed by reaching for the socket — `IOWebSocketChannel` keeps
// it private, so the constructor can neither set a native ping nor ask whether
// one is running. Running its own is the only answer available.
//
// The controls are the two cases that must not change: `connect()` on the VM
// must still leave the native ping alone, and an explicit
// `platformHandlesPing: true` must still switch ours off.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A peer that completes the upgrade and then answers no RPC.
///
/// It still PONGS: a dart:io `WebSocket` answers a ping frame itself, before any
/// listener sees it. So this is a dead path for an RPC-level probe and a live one
/// for a native keepalive — which is what lets the last control tell the two
/// apart, and what would make a native-ping assertion against this server wrong.
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

Future<WebSocketChannel> _handBuilt(HttpServer server) async {
  final channel = IOWebSocketChannel.connect(
    Uri.parse('ws://127.0.0.1:${server.port}'),
  );
  await channel.ready;
  return channel;
}

/// Milliseconds until the transport reports the path is gone, or null at [cap].
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

  test(
    'WITNESS: a hand-built channel with pingInterval notices a dead peer',
    () async {
      final server = await _silentServer();
      final transport = RpcWebSocketCallerTransport(
        await _handBuilt(server),
        pingInterval: interval,
      );
      transport.incomingMessages.listen((_) {}, onError: (Object _) {});
      addTearDown(() => transport.close().catchError((Object _) {}));

      expect(
        await _timeToNotice(transport, cap: const Duration(seconds: 5)),
        isNotNull,
        reason:
            'a documented keepalive was silently absent: dart:io was never told '
            'the interval, and the app-level heartbeat was skipped on the '
            'strength of a constant describing a function this path never calls',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // CONTROL: the same construction with NO interval must stay quiet, or
  // "notices" above is satisfied by a transport that closes itself on a timer.
  test(
    'CONTROL: a hand-built channel with no interval notices nothing',
    () async {
      final server = await _silentServer();
      final transport = RpcWebSocketCallerTransport(await _handBuilt(server));
      transport.incomingMessages.listen((_) {}, onError: (Object _) {});
      addTearDown(() => transport.close().catchError((Object _) {}));

      expect(
        await _timeToNotice(transport, cap: const Duration(seconds: 2)),
        isNull,
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // CONTROL: a caller who already has a native ping can still say so, and ours
  // must stay off — otherwise the fix doubles the keepalive for everyone who
  // built the socket properly.
  test(
    'CONTROL: platformHandlesPing: true still switches ours off',
    () async {
      final server = await _silentServer();
      final transport = RpcWebSocketCallerTransport(
        await _handBuilt(server),
        pingInterval: interval,
        platformHandlesPing: true,
      );
      transport.incomingMessages.listen((_) {}, onError: (Object _) {});
      addTearDown(() => transport.close().catchError((Object _) {}));

      expect(
        await _timeToNotice(transport, cap: const Duration(seconds: 2)),
        isNull,
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // CONTROL, and the one that bounds the fix: `connect()` must still NOT run
  // this library's ping. It goes through `openWebSocket`, so on the VM dart:io
  // already pings and closes, and a second probe is double the wire cost for
  // nothing.
  //
  // This peer PONGS — a dart:io `WebSocket` answers a ping frame itself, which
  // is why it is not a half-open path for a native keepalive and is one for an
  // RPC-level probe. That asymmetry is what makes the check sharp: if `connect()`
  // ran ours, this would go degraded in about a second, exactly as the witness
  // above does.
  //
  // Read through `health()`, not `isClosed`: `connect()` always installs a
  // reconnect factory, and a transport with one reports degraded and waits to be
  // re-attached rather than closing.
  test(
    'CONTROL: connect() on the VM does not add a second keepalive',
    () async {
      final server = await _silentServer();
      final transport = await RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://127.0.0.1:${server.port}'),
        pingInterval: interval,
      );
      transport.incomingMessages.listen((_) {}, onError: (Object _) {});
      addTearDown(() => transport.close().catchError((Object _) {}));

      await Future<void>.delayed(const Duration(seconds: 2));

      expect(
        (await transport.health()).level,
        RpcHealthLevel.healthy,
        reason:
            'the app-level heartbeat ran on the one path where the platform is '
            'already pinging, which is what the default it replaced was for',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
