// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Regression: a client-stream handler must observe each request exactly once
// over a real WebSocket connection.
//
// The responder pipeline buffers client-stream payloads itself and replays them
// when it binds the responder, while RpcChannelTransport also keeps a
// per-stream single-subscription controller that buffers until its consumer
// subscribes. If both buffers ever hold the same frames, the handler sees every
// chunk twice — which is what a downstream blob-upload service worked around by
// deduplicating the request stream.
import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test('client stream over real WebSocket delivers each chunk once', () async {
    final server = await _startIoWsServer();
    final clientChannel = WebSocketChannel.connect(server.url);
    final serverTransport = await server.acceptTransport();
    final callerTransport = RpcWebSocketCallerTransport(clientChannel);

    final service = _CountingContract();
    final responder = RpcResponderEndpoint(transport: serverTransport);
    responder.registerServiceContract(service);
    responder.start();

    final caller = RpcCallerEndpoint(transport: callerTransport);

    final requests = StreamController<RpcString>();
    final responseFuture = caller.clientStream<RpcString, RpcString>(
      serviceName: 'Counting',
      methodName: 'Collect',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    )(requests.stream);

    for (var i = 0; i < 8; i++) {
      requests.add('chunk-$i'.rpc);
    }
    await requests.close();

    await responseFuture.timeout(const Duration(seconds: 10));

    expect(
      service.received,
      equals(List.generate(8, (i) => 'chunk-$i')),
      reason: 'handler saw duplicates: ${service.received}',
    );

    await caller.close();
    await responder.close();
    await server.stop();
  });
}

final class _CountingContract extends RpcResponderContract {
  _CountingContract() : super('Counting');

  final List<String> received = [];

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'Collect',
      handler: _collect,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }

  Future<RpcString> _collect(
    Stream<RpcString> requests, {
    RpcContext? context,
  }) async {
    await for (final r in requests) {
      received.add(r.value);
    }
    return 'ok'.rpc;
  }
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
