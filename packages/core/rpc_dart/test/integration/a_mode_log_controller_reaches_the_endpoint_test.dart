// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A mode's log controller is how a framework wires logging into the endpoints a
// server builds. It takes the place of the server's own, so the endpoint logs
// there and only there.

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

final class _Capture extends LogController {
  _Capture() : super(minLevel: RpcLogLevel.internal);

  final messages = <String>[];

  @override
  void add(LogRecord record) {
    if (record is LogEvent) messages.add(record.message);
    super.add(record);
  }
}

void main() {
  for (final peer in [false, true]) {
    final kind = peer ? 'peer' : 'responder';
    test('a $kind mode log controller receives the ping', () async {
      final fromMode = _Capture();
      final fromServer = _Capture();
      final host = RpcConnectionHost(
        mode: peer
            ? RpcPeerMode((_) {}, logController: fromMode)
            : RpcResponderMode((_) {}, logController: fromMode),
        logController: fromServer,
      );
      final (client, server) = RpcChannelTransport.memoryPair();
      host.serve(server, done: Completer<void>().future);
      final caller = RpcCallerEndpoint(transport: client);

      await caller.ping(
        context: RpcContext.empty().withTimeout(const Duration(seconds: 5)),
      );

      expect(
        fromMode.messages.where((m) => m.startsWith('Ping handled')),
        isNotEmpty,
        reason: 'got: ${fromMode.messages}',
      );
      expect(fromServer.messages, isEmpty);
      await caller.close();
      await host.stop();
    });
  }

  test('CONTROL: without one the server controller is used', () async {
    final fromServer = _Capture();
    final host = RpcConnectionHost(
      mode: RpcResponderMode((_) {}),
      logController: fromServer,
    );
    final (client, server) = RpcChannelTransport.memoryPair();
    host.serve(server, done: Completer<void>().future);
    final caller = RpcCallerEndpoint(transport: client);

    await caller.ping(
      context: RpcContext.empty().withTimeout(const Duration(seconds: 5)),
    );

    expect(
      fromServer.messages.where((m) => m.startsWith('Ping handled')),
      isNotEmpty,
      reason: 'got: ${fromServer.messages}',
    );
    await caller.close();
    await host.stop();
  });
}
