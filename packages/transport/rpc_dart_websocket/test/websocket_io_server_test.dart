// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Integration test: real dart:io WebSocket server + transports.
//
// These talk over a real socket, so the arrival of a message is asynchronous.
// Instead of sleeping a fixed delay (which races the round-trip and flakes
// under parallel `melos test` load), each test subscribes BEFORE sending and
// awaits exactly the expected number of frames with a generous timeout.
import 'dart:async';
import 'dart:io';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const _timeout = Duration(seconds: 5);

void main() {
  test('caller -> responder over real WebSocket server', () async {
    final server = await _startIoWsServer();
    final clientChannel = WebSocketChannel.connect(server.url);
    final serverTransport = await server.acceptTransport();
    final caller = RpcWebSocketCallerTransport(clientChannel);

    // Subscribe before sending; incomingMessages buffers the pre-listen prefix.
    final receivedFuture = serverTransport.incomingMessages
        .take(2)
        .toList()
        .timeout(_timeout);

    final streamId = caller.createStream();
    await caller.sendMetadata(
      streamId,
      RpcMetadata([const RpcHeader('x-test', 'io')]),
    );
    final rawPayload = Uint8List.fromList([42, 43, 44]);
    final grpcFrame = RpcMessageFrame.encode(rawPayload);
    await caller.sendMessage(streamId, grpcFrame, endStream: true);

    final received = await receivedFuture;

    expect(received.length, 2);
    expect(received.first.metadata?.headers.first.value, 'io');
    expect(received[1].payload, grpcFrame);

    await caller.close();
    await serverTransport.close();
    await server.stop();
  });

  test('responder -> caller over real WebSocket server', () async {
    final server = await _startIoWsServer();
    final clientChannel = WebSocketChannel.connect(server.url);
    final serverTransport = await server.acceptTransport();
    final caller = RpcWebSocketCallerTransport(clientChannel);

    final incomingFuture = caller.incomingMessages
        .take(1)
        .toList()
        .timeout(_timeout);

    final streamId = serverTransport.createStream();
    final rawPayload = Uint8List.fromList([1, 2, 3, 4, 5]);
    final grpcFrame = RpcMessageFrame.encode(rawPayload);
    await serverTransport.sendMessage(streamId, grpcFrame, endStream: true);

    final incoming = await incomingFuture;

    expect(incoming.single.payload, grpcFrame);
    expect(incoming.single.streamId, streamId);

    await caller.close();
    await serverTransport.close();
    await server.stop();
  });

  test('caller -> responder metadata and message', () async {
    final server = await _startIoWsServer();
    final clientChannel = WebSocketChannel.connect(server.url);
    final serverTransport = await server.acceptTransport();
    final caller = RpcWebSocketCallerTransport(clientChannel);

    final receivedFuture = serverTransport.incomingMessages
        .take(2)
        .toList()
        .timeout(_timeout);

    final streamId = caller.createStream();
    await caller.sendMetadata(
      streamId,
      RpcMetadata([const RpcHeader('x-test', '1')]),
    );
    final rawPayload = Uint8List.fromList([1, 2, 3, 4]);
    final grpcFrame = RpcMessageFrame.encode(rawPayload);
    await caller.sendMessage(streamId, grpcFrame, endStream: true);

    final received = await receivedFuture;

    expect(received.length, 2);
    expect(received.first.metadata?.headers.first.name, 'x-test');
    expect(received[1].payload, grpcFrame);
    expect(received[1].isEndOfStream, isTrue);

    await caller.close();
    await serverTransport.close();
    await server.stop();
  });
}

class _IoServer {
  _IoServer(this.server, this.controller);

  final HttpServer server;
  final StreamController<IOWebSocketChannel> controller;

  Uri get url => Uri.parse('ws://${server.address.host}:${server.port}');

  Future<RpcWebSocketResponderTransport> acceptTransport() async {
    final channel = await controller.stream.first;
    return RpcWebSocketResponderTransport(channel);
  }

  Future<void> stop() async {
    await controller.close();
    await server.close(force: true);
  }
}

Future<_IoServer> _startIoWsServer() async {
  final controller = StreamController<IOWebSocketChannel>.broadcast();
  final server = await HttpServer.bind('127.0.0.1', 0);
  server.transform(WebSocketTransformer()).listen((ws) {
    controller.add(IOWebSocketChannel(ws));
  });
  return _IoServer(server, controller);
}
