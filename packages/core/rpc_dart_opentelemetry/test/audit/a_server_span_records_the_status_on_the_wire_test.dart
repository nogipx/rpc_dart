@TestOn('vm || chrome')
library;

// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A handler that throws something other than an RpcStatusException answers
// its caller INTERNAL: core translates every such error that way before it
// goes on the wire. The server span records that status, so a trace and the
// client it describes agree.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_opentelemetry/rpc_dart_opentelemetry.dart';
import 'package:test/test.dart';

import '_support.dart';

Future<Object?> _statusOf(Object thrown) async {
  final t = buildTracer();
  final interceptor = OtelRpcInterceptor(tracer: t.tracer);
  await expectLater(
    interceptor.interceptUnary<String, String>(
      buildCall(),
      'req',
      (ctx, req) async => throw thrown,
    ),
    throwsA(anything),
  );
  final span = t.exporter.spans.firstWhere(
    (s) => s.name == 'TestService/testMethod',
  );
  return span.attributes.get('rpc.grpc.status_code');
}

void main() {
  test('a plain exception is recorded as INTERNAL on the server', () async {
    expect(await _statusOf(StateError('db down')), RpcStatus.internal);
  });

  test('GUARD a status exception keeps its own code', () async {
    expect(
      await _statusOf(RpcStatusException(RpcStatus.notFound, 'missing')),
      RpcStatus.notFound,
    );
  });
}
