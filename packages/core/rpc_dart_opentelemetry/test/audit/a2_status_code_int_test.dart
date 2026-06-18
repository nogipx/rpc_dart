@TestOn('vm || chrome')
library;

// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart_opentelemetry/rpc_dart_opentelemetry.dart';
import 'package:test/test.dart';

import '_support.dart';

void main() {
  test('rpc.grpc.status_code span attribute is an int', () async {
    final t = buildTracer();
    final interceptor = OtelRpcInterceptor(tracer: t.tracer);
    final call = buildCall();

    await interceptor.interceptUnary<String, String>(
      call,
      'req',
      (ctx, req) async => 'res',
    );

    final span = t.exporter.spans.firstWhere(
      (s) => s.name == 'TestService/testMethod',
    );
    final value = span.attributes.get('rpc.grpc.status_code');

    expect(
      value,
      isA<int>(),
      reason:
          'semconv requires rpc.grpc.status_code as int. '
          'Got: $value (${value.runtimeType}). '
          'String -> CONFIRMED.',
    );
  });
}
