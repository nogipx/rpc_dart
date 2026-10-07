// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// With `maxMessageLengthBytes` below the flow-control window, the receiver's
// per-stream queue was bounded by one message while the sender could send the
// whole window. A stream of items near the limit to a slow reader failed with
// RESOURCE_EXHAUSTED at the third item.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const _policy = RpcSecurityPolicy(maxMessageLengthBytes: 64 * 1024);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'big',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async* {
        for (var i = 0; i < 30; i++) {
          yield ('b' * (60 * 1024)).rpc;
        }
      },
    );
  }
}

void main() {
  test(
    'WITNESS items near the limit reach a slow reader',
    () async {
      final http = await HttpServer.bind('127.0.0.1', 0);
      final server = RpcWebSocketServer(
        connections: rpcWebSocketConnections(http),
        policy: _policy,
        onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
      );
      await server.start();
      final client = await RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://127.0.0.1:${http.port}'),
        policy: _policy,
      );
      final caller = RpcCallerEndpoint(transport: client);
      addTearDown(() async {
        await caller.close();
        await server.stop();
        await http.close(force: true);
      });

      var got = 0;
      await for (final _ in caller.serverStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'big',
        request: ''.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      )) {
        got++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(got, 30);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
