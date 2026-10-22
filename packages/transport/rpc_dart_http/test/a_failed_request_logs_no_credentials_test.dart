// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A failed request is logged with its status, not with the raw
// `ClientException`, whose text carries the request uri and so the password
// of a `baseUrl` with userinfo.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

void main() {
  test('WITNESS: a request the server cuts off logs no password', () async {
    final closer = await ServerSocket.bind('127.0.0.1', 0);
    addTearDown(closer.close);
    closer.listen((s) => s.listen((_) => s.destroy()));

    final logs = <String>[];
    final controller = LogController(minLevel: RpcLogLevel.debug);
    addTearDown(controller.dispose);
    controller.stream.listen((r) {
      if (r is LogEvent) logs.add('${r.message} ${r.error} ${r.data}');
    });
    final transport = RpcHttpCallerTransport(
      baseUrl: 'http://user:pw-secret@127.0.0.1:${closer.port}',
      logger: controller.scope('http'),
    );
    final caller = RpcCallerEndpoint(transport: transport);
    addTearDown(caller.close);

    await expectLater(
      caller.unary<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'm',
        request: 'x'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
        context: RpcContext.withTimeout(const Duration(seconds: 5)),
      ),
      throwsA(isA<RpcStatusException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      logs.where((l) => l.contains('HTTP request failed')),
      isNotEmpty,
      reason: 'the failure must still be logged',
    );
    expect(logs.where((l) => l.contains('pw-secret')), isEmpty);
  });

  test(
    'WITNESS: health details show the base url without its password',
    () async {
      final transport = RpcHttpCallerTransport(
        baseUrl: 'http://user:pw-secret@127.0.0.1:1/base',
      );
      addTearDown(transport.close);

      final status = await transport.health();
      expect(status.details['baseUrl'], 'http://127.0.0.1:1/base');
    },
  );
}
