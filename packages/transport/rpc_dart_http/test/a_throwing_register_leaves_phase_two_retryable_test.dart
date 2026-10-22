// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `afterModulesStart` registers the application's contracts before it binds,
// and a contract builder can throw. That failure releases what the bind's own
// failure releases: the endpoint is closed and the slot is free, so calling
// phase two again serves -- rather than logging "already binding" and
// returning with nothing listening.
@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Echo extends RpcResponderContract {
  _Echo() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Future<int> _freePort() async {
  final s = await ServerSocket.bind('127.0.0.1', 0);
  final port = s.port;
  await s.close();
  return port;
}

void main() {
  test('phase two after a throwing register serves calls', () async {
    final port = await _freePort();
    var registers = 0;
    final server = RpcHttpServer(
      host: '127.0.0.1',
      port: port,
      mode: RpcResponderMode((e) {
        if (registers++ == 0) throw StateError('contract builder failed');
        e.registerServiceContract(_Echo());
      }),
    );
    addTearDown(() => server.stop().catchError((Object _) {}));

    await server.start();
    await expectLater(server.afterModulesStart(), throwsStateError);
    await server.afterModulesStart();
    expect(server.isRunning, isTrue);

    final transport = RpcHttpCallerTransport(baseUrl: 'http://127.0.0.1:$port');
    final caller = RpcCallerEndpoint(transport: transport);
    addTearDown(() async {
      await caller.close().catchError((Object _) {});
      await transport.close().catchError((Object _) {});
    });
    final reply = await caller
        .unary<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 5));
    expect(reply.value, 'x');
  });
}
