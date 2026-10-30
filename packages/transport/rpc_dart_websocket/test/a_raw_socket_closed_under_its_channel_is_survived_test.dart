// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

/// A channel over a raw socket its caller keeps, built by
/// `rpcWebSocketChannel`, and the raw socket itself.
Future<({RpcWebSocketChannel channel, WebSocket ours})> _rig(
  List<Object> callerErrors,
) async {
  final accepted = Completer<WebSocket>();
  final server = await HttpServer.bind('127.0.0.1', 0);
  server.transform(WebSocketTransformer()).listen((ws) {
    if (!accepted.isCompleted) accepted.complete(ws);
  });
  addTearDown(() => server.close(force: true));

  final ours = await WebSocket.connect(
    'ws://${server.address.host}:${server.port}',
  );
  final peer = await accepted.future;
  addTearDown(() => peer.close().catchError((Object _) {}));

  late final RpcWebSocketChannel channel;
  final built = Completer<void>();
  // The caller's zone: what reaches it would have been uncaught.
  runZonedGuarded(() {
    channel = RpcWebSocketChannel(rpcWebSocketChannel(ours));
    built.complete();
  }, (error, _) => callerErrors.add(error));
  await built.future;
  channel.incoming.listen((_) {}, onError: (Object _) {});
  addTearDown(() => channel.close().catchError((Object _) {}));
  return (channel: channel, ours: ours);
}

void main() {
  // What `send_after_raw_socket_close_test` pins as thrown into the zone a
  // channel is built in: built by rpcWebSocketChannel, the write to a socket
  // closed under it is dropped, and nothing reaches the caller.
  test('a raw socket closed under its channel mid-send is survived', () async {
    final callerErrors = <Object>[];
    final rig = await _rig(callerErrors);

    await rig.channel.send(Uint8List.fromList([1, 2, 3]));
    // In the same turn as the send, before the write goes out.
    unawaited(rig.ours.close());
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(callerErrors, isEmpty);
  });

  // GUARD: a live socket still carries what is sent.
  test('GUARD: a send over a live socket reaches the peer', () async {
    final callerErrors = <Object>[];
    final accepted = Completer<WebSocket>();
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.transform(WebSocketTransformer()).listen((ws) {
      if (!accepted.isCompleted) accepted.complete(ws);
    });
    addTearDown(() => server.close(force: true));
    final ours = await WebSocket.connect(
      'ws://${server.address.host}:${server.port}',
    );
    final peer = await accepted.future;
    final got = <Object?>[];
    peer.listen(got.add);
    addTearDown(() => peer.close().catchError((Object _) {}));

    late final RpcWebSocketChannel channel;
    runZonedGuarded(() {
      channel = RpcWebSocketChannel(rpcWebSocketChannel(ours));
    }, (error, _) => callerErrors.add(error));
    channel.incoming.listen((_) {}, onError: (Object _) {});
    addTearDown(() => channel.close().catchError((Object _) {}));

    await channel.send(Uint8List.fromList([7, 8]));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(got, [
      [7, 8],
    ]);
    expect(callerErrors, isEmpty);
  });
}
