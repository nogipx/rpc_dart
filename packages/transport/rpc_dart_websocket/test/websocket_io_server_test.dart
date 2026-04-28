// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Integration test: real dart:io WebSocket server + transports.
import 'dart:async';
import 'dart:io';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test('caller -> responder over real WebSocket server', () async {
    final server = await _startIoWsServer();

    final clientChannel = WebSocketChannel.connect(server.url);
    final serverTransport = await server.acceptTransport();
    final caller = RpcWebSocketCallerTransport(clientChannel);

    final received = <RpcTransportMessage>[];
    final sub = serverTransport.incomingMessages.listen(received.add);

    final streamId = caller.createStream();
    await caller.sendMetadata(
      streamId,
      RpcMetadata([const RpcHeader('x-test', 'io')]),
    );
    final rawPayload = Uint8List.fromList([42, 43, 44]);
    final grpcFrame = RpcMessageFrame.encode(rawPayload);
    await caller.sendMessage(streamId, grpcFrame, endStream: true);

    await Future.delayed(const Duration(milliseconds: 50));

    await caller.close();
    await serverTransport.close();
    await sub.cancel();
    await server.stop();

    expect(received.length, 2);
    expect(received.first.metadata?.headers.first.value, 'io');
    expect(received[1].payload, grpcFrame);
  });

  test('responder -> caller over real WebSocket server', () async {
    final server = await _startIoWsServer();

    final clientChannel = WebSocketChannel.connect(server.url);
    final serverTransport = await server.acceptTransport();
    final caller = RpcWebSocketCallerTransport(clientChannel);

    final incoming = <RpcTransportMessage>[];
    final sub = caller.incomingMessages.listen(incoming.add);

    final streamId = serverTransport.createStream();
    final rawPayload = Uint8List.fromList([1, 2, 3, 4, 5]);
    final grpcFrame = RpcMessageFrame.encode(rawPayload);
    await serverTransport.sendMessage(streamId, grpcFrame, endStream: true);

    await Future.delayed(const Duration(milliseconds: 50));

    await caller.close();
    await serverTransport.close();
    await sub.cancel();
    await server.stop();

    expect(incoming.single.payload, grpcFrame);
    expect(incoming.single.streamId, streamId);
  });

  test('caller -> responder metadata and message', () async {
    final server = await _startIoWsServer();

    final clientChannel = WebSocketChannel.connect(server.url);
    final serverTransport = await server.acceptTransport();
    final caller = RpcWebSocketCallerTransport(clientChannel);

    final received = <RpcTransportMessage>[];
    final sub = serverTransport.incomingMessages.listen(received.add);

    final streamId = caller.createStream();
    await caller.sendMetadata(
      streamId,
      RpcMetadata([const RpcHeader('x-test', '1')]),
    );
    final rawPayload = Uint8List.fromList([1, 2, 3, 4]);
    final grpcFrame = RpcMessageFrame.encode(rawPayload);
    await caller.sendMessage(streamId, grpcFrame, endStream: true);

    await Future.delayed(const Duration(milliseconds: 50));
    await caller.close();
    await serverTransport.close();
    await sub.cancel();
    await server.stop();

    expect(received.length, 2);
    expect(received.first.metadata?.headers.first.name, 'x-test');
    expect(received[1].payload, grpcFrame);
    expect(received[1].isEndOfStream, isTrue);
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
