// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `await controller.close()` on a SINGLE-SUBSCRIPTION controller that nothing
// ever listened to returns a future which does not complete until someone
// listens. RpcWebSocketChannel awaited exactly that, so close() deadlocked.
//
// Measured, with a listener as the control:
//
//   no listener : close() still pending after 3s, and forever
//   listener    : close() returns
//
// The normal path is safe because RpcFrameMultiplexedChannel subscribes in its
// constructor. The path that is not is closing a channel that was built but
// never wrapped -- an aborted setup, or an error between construction and use,
// which is exactly when cleanup has to work. This class is public and its own
// doc comment shows direct construction, so that is reachable code.
//
// Same fault as the CONNECT-proxy deadlock in dcc14f8c, found by sweeping every
// awaited controller close in the transports for this shape. All the others are
// broadcast controllers, whose close() completes immediately; this was the only
// single-subscription one.
//
// Broadcast would also "fix" it and must NOT be used: a broadcast controller
// DROPS events arriving before the frame channel subscribes, where this one
// buffers them.

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

void main() {
  late HttpServer server;
  late Uri uri;

  setUp(() async {
    server = await HttpServer.bind('127.0.0.1', 0);
    server.transform(WebSocketTransformer()).listen((ws) {
      ws.listen((_) {}, onError: (Object _) {}, cancelOnError: false);
    });
    uri = Uri.parse('ws://127.0.0.1:${server.port}');
  });

  tearDown(() => server.close(force: true));

  test('close() returns even when nothing listened to incoming', () async {
    final channel = RpcWebSocketChannel(IOWebSocketChannel.connect(uri));

    await expectLater(
      channel.close().timeout(const Duration(seconds: 5)),
      completes,
      reason:
          'closing a never-listened single-subscription controller waits for a '
          'listener that will never arrive, so close() hung forever',
    );
    expect(channel.isClosed, isTrue);
  });

  test('CONTROL: close() returns when someone did listen', () async {
    final channel = RpcWebSocketChannel(IOWebSocketChannel.connect(uri));
    final sub = channel.incoming.listen((_) {});
    addTearDown(sub.cancel);

    await expectLater(
      channel.close().timeout(const Duration(seconds: 5)),
      completes,
    );
    expect(channel.isClosed, isTrue);
  });

  test('GUARD: close() is still idempotent', () async {
    final channel = RpcWebSocketChannel(IOWebSocketChannel.connect(uri));

    await channel.close().timeout(const Duration(seconds: 5));
    await expectLater(
      channel.close().timeout(const Duration(seconds: 5)),
      completes,
    );
  });

  test('GUARD: bytes arriving before a listener are still delivered', () async {
    // The reason this is NOT fixed by switching to a broadcast controller: a
    // broadcast one drops whatever arrives before the first subscriber, and
    // the frame channel subscribes a moment after construction.
    final serverSide = Completer<WebSocket>();
    final other = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => other.close(force: true));
    other.transform(WebSocketTransformer()).listen((ws) {
      if (!serverSide.isCompleted) serverSide.complete(ws);
    });

    final channel = RpcWebSocketChannel(
      IOWebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${other.port}')),
    );
    addTearDown(channel.close);

    final ws = await serverSide.future.timeout(const Duration(seconds: 5));
    ws.add([1, 2, 3]);

    // Subscribe only AFTER the bytes were sent.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final first = await channel.incoming.first.timeout(
      const Duration(seconds: 5),
    );
    expect(first, [1, 2, 3]);
  });
}
