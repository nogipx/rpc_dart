// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The frame guard in rpcWebSocketConnections refuses a message past the
// largest one the policy admits. That policy is the SERVER's: a limit raised on
// RpcWebSocketServer alone must raise the guard's ceiling too, or a message
// between the two is refused as a broken connection and retried forever.

@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Echo extends RpcResponderContract {
  _Echo() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'length',
      handler: (request, {RpcContext? context}) async =>
          '${request.value.length}'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

const _raised = RpcSecurityPolicy(maxMessageLengthBytes: 32 * 1024 * 1024);
const _size = 20 * 1024 * 1024;

Future<String> _send({RpcSecurityPolicy? connectionsPolicy}) async {
  final http = await HttpServer.bind('127.0.0.1', 0);
  final server = RpcWebSocketServer(
    connections: rpcWebSocketConnections(http, policy: connectionsPolicy),
    policy: _raised,
    onEndpointCreated: (endpoint) => endpoint.registerServiceContract(_Echo()),
  );
  await server.start();
  addTearDown(() async {
    await server.stop();
    await http.close(force: true);
  });

  final client = await RpcWebSocketCallerTransport.connect(
    Uri.parse('ws://127.0.0.1:${http.port}'),
    policy: _raised,
  );
  final caller = RpcCallerEndpoint(transport: client);
  addTearDown(() async {
    await caller.close();
    await client.close();
  });
  final answer = await caller
      .unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'length',
        request: ('a' * _size).rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      )
      .timeout(const Duration(seconds: 20));
  return answer.value;
}

void main() {
  test(
    'a limit raised on the server alone admits the larger message',
    () async {
      expect(await _send(), '$_size');
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'CONTROL the same policy passed to the connections too',
    () async {
      expect(await _send(connectionsPolicy: _raised), '$_size');
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
