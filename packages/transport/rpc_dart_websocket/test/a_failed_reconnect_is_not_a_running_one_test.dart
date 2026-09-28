// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// "Disconnected" was two states wearing one word, and the three reconnect
// machines gave them three answers between them. Measured on a send 200 ms into
// an 800 ms factory stall:
//
//                            websocket   http2
//   during the factory await     9         14
//   after a FAILED reconnect     9          9
//
// The two want OPPOSITE advice. A reconnect IN FLIGHT will have a connection in
// tens of milliseconds and the caller can do nothing but wait — UNAVAILABLE,
// retry. A reconnect that FAILED needs reconnect() called — FAILED_PRECONDITION,
// whose meaning is "do not retry until the state is fixed".
//
// And the difference is not academic. One call through RpcRetryInterceptor,
// fired 100 ms into an 800 ms window, first backoff 250 ms:
//
//   FAILED_PRECONDITION   status=9 after 0ms     never retried
//   UNAVAILABLE           OK pong after 711ms    retried, succeeded

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
  // WITNESS. Both states answered FAILED_PRECONDITION before this split, so a
  // standard gRPC retry policy declined to retry a condition that resolves
  // itself in tens of milliseconds.
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

  // WITNESS for the other half, and the CONTROL for the one above: the same
  // transport, the same guard, the same method — only the state differs. Without
  // this, "the window is UNAVAILABLE" is indistinguishable from "this type is
  // always UNAVAILABLE".
  test(
    'a FAILED reconnect is FAILED_PRECONDITION — the remedy is yours',
    () async {
      final rig = await _rig();
      rig.failNext();

      final outcome = await rig.transport.reconnect();
      expect(outcome.level, RpcHealthLevel.unhealthy);

      expect(_refusal(rig.transport), (
        status: RpcStatus.failedPrecondition,
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

      // Now fail one, and the answer must be the caller's-remedy shape rather
      // than a leftover "retry".
      rig.failNext();
      await rig.transport.reconnect();
      expect(_refusal(rig.transport), (
        status: RpcStatus.failedPrecondition,
        reconnecting: false,
      ));
    },
  );
}
