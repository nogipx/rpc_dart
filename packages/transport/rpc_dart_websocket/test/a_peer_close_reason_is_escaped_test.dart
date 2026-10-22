// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A peer's close reason ends up in the status every open call fails with, and
// that status is logged. Raw, a CR/LF in the reason forged lines in this
// side's log.

@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

Future<String> _failureWhenClosedWith(String reason) async {
  final io = await HttpServer.bind('127.0.0.1', 0);
  addTearDown(() => io.close(force: true));
  io.transform(WebSocketTransformer()).listen((ws) async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await ws.close(4000, reason);
  });
  final transport = await RpcWebSocketCallerTransport.connect(
    Uri.parse('ws://127.0.0.1:${io.port}'),
  );
  final caller = RpcCallerEndpoint(transport: transport);
  addTearDown(caller.close);
  try {
    await caller.unary<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'm',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
      context: RpcContext.withTimeout(const Duration(seconds: 5)),
    );
    return 'answered';
  } on RpcStatusException catch (e) {
    return e.message;
  }
}

void main() {
  test('WITNESS: a close reason with CR/LF reaches the call escaped', () async {
    final message = await _failureWhenClosedWith('bye\r\nFORGED LINE');
    expect(message, contains('code 4000'));
    expect(message, isNot(matches(RegExp(r'[\x00-\x1f\x7f]'))));
    expect(message, contains(r'bye\r\nFORGED LINE'));
  });

  test('GUARD: a printable close reason is quoted as it is', () async {
    expect(
      await _failureWhenClosedWith('going away for maintenance'),
      endsWith('code 4000: going away for maintenance'),
    );
  });
}
