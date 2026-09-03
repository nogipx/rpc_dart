// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcWebSocketChannel forwarded Uint8List and List<int> and had no else branch,
// so a WebSocket TEXT frame -- which arrives as a String -- fell through both
// and vanished.
//
// Measured against a real dart:io WebSocket server, sending one text frame:
//
//   before: clientClosed=false clientError=none serverReported=false
//           => SILENTLY IGNORED
//   after : serverReported=true
//           => RpcException: RpcWebSocketChannel: expected a binary WebSocket
//              message, got String...
//
// Silence is the worst option available: the peer gets nothing on the wire and
// the server logs nothing, so a call made over that connection just hangs to
// its deadline with no clue anywhere.
//
// Reported, NOT fatal. The error travels RpcFrameMultiplexedChannel ->
// RpcChannelTransport -> the endpoint's incoming stream, where it is logged,
// and the connection keeps working for the binary frames around it. Closing
// would turn one stray frame -- an app-level keepalive from a proxy, say --
// into a dropped connection, which is a bigger change than the defect.

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

const _timeout = Duration(seconds: 5);

class _IoServer {
  _IoServer(this.server, this.controller);

  final HttpServer server;
  final StreamController<IOWebSocketChannel> controller;

  Uri get url => Uri.parse('ws://${server.address.host}:${server.port}');

  Future<void> stop() async {
    await controller.close();
    await server.close(force: true);
  }
}

Future<_IoServer> _startServer() async {
  final controller = StreamController<IOWebSocketChannel>.broadcast();
  final server = await HttpServer.bind('127.0.0.1', 0);
  server.transform(WebSocketTransformer()).listen((ws) {
    controller.add(IOWebSocketChannel(ws));
  });
  return _IoServer(server, controller);
}

void main() {
  late _IoServer server;

  setUp(() async {
    server = await _startServer();
  });

  tearDown(() async {
    await server.stop();
  });

  // WITNESS: nothing was reported at all before the fix.
  test('a text frame is reported, not silently dropped', () async {
    final accepted = server.controller.stream.first;
    final raw = await WebSocket.connect(server.url.toString());

    final serverChannel = RpcWebSocketChannel(await accepted);
    // `incoming` is single-subscription: listen exactly once.
    final errors = <Object>[];
    final sub = serverChannel.incoming.listen((_) {}, onError: errors.add);

    raw.add('a text frame, which this binary protocol cannot carry');
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      errors,
      isNotEmpty,
      reason:
          'a non-binary WebSocket message produced no error and no data: it '
          'was discarded with no signal to either side',
    );
    expect(errors.first, isA<RpcException>());
    expect(errors.first.toString(), contains('binary'));

    await sub.cancel();
    await raw.close();
    await serverChannel.close();
  });

  // GUARD: binary must still flow untouched — the whole point of the channel.
  test('binary frames still arrive intact', () async {
    final accepted = server.controller.stream.first;
    final raw = await WebSocket.connect(server.url.toString());

    final serverChannel = RpcWebSocketChannel(await accepted);
    final received = serverChannel.incoming.first.timeout(_timeout);

    final payload = Uint8List.fromList([1, 2, 3, 250]);
    raw.add(payload);

    expect(await received, payload);

    await raw.close();
    await serverChannel.close();
  });

  // GUARD: a text frame must not poison the connection for later binary
  // frames. This is what distinguishes "report" from "close".
  test('binary still works after a text frame', () async {
    final accepted = server.controller.stream.first;
    final raw = await WebSocket.connect(server.url.toString());

    final serverChannel = RpcWebSocketChannel(await accepted);
    final data = <Uint8List>[];
    final errors = <Object>[];
    final sub = serverChannel.incoming.listen(data.add, onError: errors.add);

    raw.add('text first');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final payload = Uint8List.fromList([7, 8, 9]);
    raw.add(payload);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(errors, hasLength(1), reason: 'the text frame should report once');
    expect(data, [
      payload,
    ], reason: 'the binary frame after it must still be delivered');
    expect(
      serverChannel.isClosed,
      isFalse,
      reason: 'one stray text frame must not tear the connection down',
    );

    await sub.cancel();
    await raw.close();
    await serverChannel.close();
  });
}
