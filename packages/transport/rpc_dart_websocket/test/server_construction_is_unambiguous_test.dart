// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Construction of RpcWebSocketServer: both an RpcResponderMode and an
// RpcPeerMode server construct, and `createWithContracts` hands the
// LogController it is given to the endpoints it builds.

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
  test('either mode is accepted', () {
    expect(
      () => RpcWebSocketServer(
        connections: const Stream<Never>.empty(),
        mode: RpcResponderMode((_) {}),
      ),
      returnsNormally,
    );
    expect(
      () => RpcWebSocketServer(
        connections: const Stream<Never>.empty(),
        mode: RpcPeerMode((_) {}),
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
