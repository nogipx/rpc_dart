// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Two construction gaps on RpcWebSocketServer. Passing both endpoint callbacks
// ran only the peer one, so the responder registration an application wrote
// never happened and its connections served nothing. And `createWithContracts`
// had no way to take a LogController, so its endpoints logged nowhere.

import 'dart:async';
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
      methodName: 'echo',
      handler: (request, {RpcContext? context}) async => request,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  test('both endpoint callbacks are refused at construction', () {
    expect(
      () => RpcWebSocketServer(
        connections: const Stream<Never>.empty(),
        onEndpointCreated: (_) {},
        onPeerEndpointCreated: (_) {},
      ),
      throwsArgumentError,
    );
  });

  test('either callback alone is accepted', () {
    expect(
      () => RpcWebSocketServer(
        connections: const Stream<Never>.empty(),
        onEndpointCreated: (_) {},
      ),
      returnsNormally,
    );
    expect(
      () => RpcWebSocketServer(
        connections: const Stream<Never>.empty(),
        onPeerEndpointCreated: (_) {},
      ),
      returnsNormally,
    );
  });

  test(
    'createWithContracts hands its LogController to the endpoints',
    () async {
      final logs = LogController(minLevel: RpcLogLevel.internal);
      final records = <LogRecord>[];
      final sub = logs.stream.listen(records.add);

      final http = await HttpServer.bind('127.0.0.1', 0);
      final server = RpcWebSocketServer.createWithContracts(
        connections: rpcWebSocketConnections(http),
        contracts: [_Echo()],
        logController: logs,
      );
      await server.start();
      final client = await RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://127.0.0.1:${http.port}'),
      );
      final caller = RpcCallerEndpoint(transport: client);
      addTearDown(() async {
        await caller.close();
        await client.close();
        await server.stop();
        await http.close(force: true);
        await sub.cancel();
      });

      final answer = await caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'echo',
        request: 'x'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      );
      expect(answer.value, 'x');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        records,
        isNotEmpty,
        reason:
            'the server endpoint logged nothing to the controller it was given',
      );
    },
  );
}
