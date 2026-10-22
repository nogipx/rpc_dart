// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A client decides how its request body arrives -- slow, oversized,
// malformed -- and how many such requests it sends. The responder answers
// every one with its status and reports the kind once.

@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'sink',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async => 'ok'.rpc,
    );
  }
}

void main() {
  test('three oversized bodies, three refusals, one warning', () async {
    final warnings = <String>[];
    final controller = LogController(minLevel: RpcLogLevel.warning);
    controller.stream.listen((r) {
      if (r is LogEvent) warnings.add(r.message);
    });
    addTearDown(controller.dispose);

    final server = RpcHttpServer(
      host: '127.0.0.1',
      port: 0,
      policy: const RpcSecurityPolicy(maxMessageLengthBytes: 1024),
      logger: controller.scope('http'),
      mode: RpcResponderMode((e) => e.registerServiceContract(_Svc())),
    );
    await server.start();
    await server.afterModulesStart();
    final caller = RpcCallerEndpoint(
      transport: RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:${server.actualPort}',
      ),
    );
    addTearDown(() async {
      await caller.close();
      await server.stop();
    });

    for (var i = 0; i < 3; i++) {
      await expectLater(
        caller.unary<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'sink',
          request: ('x' * 4096).rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        ),
        throwsA(isA<RpcStatusException>()),
      );
    }

    expect(
      warnings.where((m) => m.startsWith('Failed to read a request body')),
      hasLength(1),
    );
  });
}
