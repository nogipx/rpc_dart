// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A request over the server's size limit closes the WebSocket connection --
// dart:io has already buffered the whole message, so closing is the only
// lever left -- and the caller is told it was a size: RESOURCE_EXHAUSTED, as
// http1 and http2 answer the same request.

@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

const _limit = 64 * 1024;
const _policy = RpcSecurityPolicy(maxMessageLengthBytes: _limit);
final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Future<RpcCallerEndpoint> _open() async {
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
    await caller.close().catchError((_) {});
    await client.close().catchError((_) {});
    await server.stop().catchError((_) {});
    await http.close(force: true);
  });
  return caller;
}

Future<String> _echo(RpcCallerEndpoint caller, String value) async {
  try {
    return (await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'echo',
      request: value.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    )).value;
  } on RpcStatusException catch (e) {
    return 'status ${e.statusCode}';
  }
}

void main() {
  test('an oversized request fails as RESOURCE_EXHAUSTED', () async {
    final caller = await _open();
    expect(
      await _echo(caller, 'a' * (_limit + 1024)),
      'status ${RpcStatus.resourceExhausted}',
    );
  });

  test('GUARD: a request under the limit is answered', () async {
    final caller = await _open();
    final value = 'a' * (_limit - 1024);
    expect(await _echo(caller, value), value);
  });
}
