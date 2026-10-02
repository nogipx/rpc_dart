// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `RpcResponderEndpoint.setLogController` exists so a framework can wire logging
// into an endpoint a transport server built without it. The ping handler was
// built once, in the constructor, and kept the scope it was given then.

import 'package:rpc_dart/rpc_dart.dart';
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
  test('a log controller set after construction receives the ping', () async {
    final (client, server) = RpcChannelTransport.memoryPair();
    final responder = RpcResponderEndpoint(transport: server);
    final capture = _Capture();
    responder
      ..setLogController(capture)
      ..start();
    final caller = RpcCallerEndpoint(transport: client);

    await caller.ping(timeout: const Duration(seconds: 5));

    expect(
      capture.messages.where((m) => m.startsWith('Ping handled')),
      isNotEmpty,
      reason: 'got: ${capture.messages}',
    );
    await caller.close();
    await responder.close();
  });
}
