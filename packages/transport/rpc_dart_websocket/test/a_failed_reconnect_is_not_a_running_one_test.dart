// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// "Disconnected" is two states: a reconnect IN FLIGHT, which resolves itself,
// and one that FAILED, which needs reconnect() called. Both answer UNAVAILABLE,
// the status every transport gives for a dead peer -- RpcRetryInterceptor
// retries it and reconnects before the next attempt -- and
// `RpcNoConnectionException.reconnecting` says which state it is.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

typedef _Rig = ({
  RpcWebSocketCallerTransport transport,
  void Function(Duration) stall,
  void Function() failNext,
});

Future<_Rig> _rig() async {
  final server = await HttpServer.bind('127.0.0.1', 0);
  server.transform(WebSocketTransformer()).listen((ws) {
    ws.listen((_) {}, onError: (Object _) {}, cancelOnError: false);
  });
  addTearDown(() => server.close(force: true));
  final uri = 'ws://${server.address.host}:${server.port}';

  var stall = Duration.zero;
  var failNext = false;
  Future<WebSocketChannel> factory() async {
    if (stall > Duration.zero) await Future<void>.delayed(stall);
    if (failNext) throw const SocketException('factory refused');
    return IOWebSocketChannel(await WebSocket.connect(uri));
  }

  final transport = RpcWebSocketCallerTransport(
    IOWebSocketChannel(await WebSocket.connect(uri)),
    reconnectFactory: factory,
  );
  addTearDown(() => transport.close().catchError((Object _) {}));
  transport.incomingMessages.listen((_) {}, onError: (Object _) {});

  return (
    transport: transport,
    stall: (Duration d) => stall = d,
    failNext: () => failNext = true,
  );
}

/// The status and the `reconnecting` fact from one refused `createStream`.
({int status, bool reconnecting}) _refusal(
  RpcWebSocketCallerTransport transport,
) {
  try {
    transport.createStream();
    fail('the transport accepted work with no connection');
  } on RpcNoConnectionException catch (e) {
    return (status: e.statusCode, reconnecting: e.reconnecting);
  }
}

void main() {
  test(
    'a reconnect IN FLIGHT is UNAVAILABLE — retry, do not intervene',
    () async {
      final rig = await _rig();
      rig.stall(const Duration(milliseconds: 800));
      final reconnecting = rig.transport.reconnect();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(_refusal(rig.transport), (
        status: RpcStatus.unavailable,
        reconnecting: true,
      ));

      await reconnecting.timeout(const Duration(seconds: 8));
    },
  );

  // The other state, through the same guard: only `reconnecting` differs.
  test(
    'a FAILED reconnect is UNAVAILABLE and says no reconnect is running',
    () async {
      final rig = await _rig();
      rig.failNext();

      final outcome = await rig.transport.reconnect();
      expect(outcome.level, RpcHealthLevel.unhealthy);

      expect(_refusal(rig.transport), (
        status: RpcStatus.unavailable,
        reconnecting: false,
      ));
    },
  );

  // GUARD. A healthy transport is untouched by either arm, which is what makes
  // the two above a statement about the STATE and not about the guard.
  test('GUARD: a connected transport still accepts work', () async {
    final rig = await _rig();

    expect(rig.transport.createStream(), greaterThan(0));
  });

  // GUARD. `reconnecting` must go back to false, or the first successful
  // reconnect leaves every later refusal saying "retry" forever.
  test(
    'GUARD: the reconnecting fact is cleared by a SUCCESSFUL reconnect',
    () async {
      final rig = await _rig();
      rig.stall(const Duration(milliseconds: 100));

      await rig.transport.reconnect().timeout(const Duration(seconds: 8));
      expect(rig.transport.createStream(), greaterThan(0));

      // Now fail one: `reconnecting` must read false, not a leftover true.
      rig.failNext();
      await rig.transport.reconnect();
      expect(_refusal(rig.transport), (
        status: RpcStatus.unavailable,
        reconnecting: false,
      ));
    },
  );
}
