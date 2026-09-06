// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A hostile SERVER pushing frames at stream ids the client never opened.
//
// Every ghost-id measurement in this repo so far has been against a server --
// the flow-control maps got their maxActiveStreams cap that way. This is the
// mirror, and it is a real position: a client connects OUT to something it may
// not control (a proxy, a compromised backend, a third-party endpoint).
//
// The property is that a client allocates no per-stream state for an id it did
// not mint. It holds because RpcChannelTransport creates a controller only in
// getMessagesForStream, i.e. on local initiative, and _onMessage looks the id up
// rather than creating it. Measured with 50000 ghost frames:
//
//   streamControllers : 0
//   activeStreams     : 0
//   transport healthy : true
//
// Nothing pinned that, so a later "create the controller on demand" would open
// an unbounded remote allocation with every test still green.

@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// One channel frame: streamId, no flags, a small payload.
Uint8List _frame(int streamId, List<int> payload) {
  final data = Uint8List(RpcChannelFrame.headerSize + payload.length);
  final view = ByteData.view(data.buffer);
  view.setUint32(0, streamId);
  data[4] = 0;
  view.setUint32(5, payload.length);
  data.setRange(RpcChannelFrame.headerSize, data.length, payload);
  return data;
}

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'hold',
      handler: (request, {RpcContext? context}) async* {
        yield 'first'.rpc;
        await Future<void>.delayed(const Duration(minutes: 5));
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  test('frames for ids the client never opened allocate nothing', () async {
    const ghosts = 20000;

    final http = await HttpServer.bind('127.0.0.1', 0);
    // Raw peer: no rpc_dart on this side, it only pushes ghost frames. EVEN ids
    // are the server-initiated parity, which a client's own manager never mints.
    http.transform(WebSocketTransformer()).listen((socket) {
      for (var i = 1; i <= ghosts; i++) {
        socket.add(_frame(i * 2, const [0, 0, 0, 0, 0]));
      }
    });

    final client = RpcWebSocketCallerTransport(
      IOWebSocketChannel(
        await WebSocket.connect('ws://127.0.0.1:${http.port}'),
      ),
    );
    client.incomingMessages.listen((_) {}, onError: (Object _) {});
    addTearDown(() async {
      await client.close();
      await http.close(force: true);
    });

    await Future<void>.delayed(const Duration(seconds: 3));
    final health = await client.health();

    expect(
      health.details['streamControllers'],
      0,
      reason: 'a peer must not be able to make us allocate per-stream state',
    );
    expect(health.details['activeStreams'], 0);
    expect(
      health.isHealthy,
      isTrue,
      reason: 'and the flood must not knock the transport over either',
    );
  });

  test('GUARD: a stream the client DID open does allocate', () async {
    // Load-bearing: without it the test above would pass on a transport that
    // allocates nothing for anyone, i.e. one that is simply broken.
    final http = await HttpServer.bind('127.0.0.1', 0);
    final server = RpcWebSocketServer(
      connections: rpcWebSocketConnections(http),
      onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
    );
    await server.start();

    final client = await RpcWebSocketCallerTransport.connect(
      Uri.parse('ws://127.0.0.1:${http.port}'),
    );
    addTearDown(() async {
      await client.close();
      await server.stop();
      await http.close(force: true);
    });

    final id = client.createStream();
    client.getMessagesForStream(id).listen((_) {}, onError: (Object _) {});
    await client.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'hold'));

    expect((await client.health()).details['streamControllers'], 1);
  });
}
