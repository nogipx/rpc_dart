@TestOn('vm || chrome')
library;

// SPDX-License-Identifier: MIT
//
// Runs on vm and chrome (the real web target) but not node: the audit suite
// builds a real opentelemetry SDK tracer whose IdGenerator calls
// Random.secure(), which is unavailable under the node test platform.
//
// AUDIT A2: rpc.grpc.status_code emitted as STRING ('OK') where the OTel
// semantic conventions require an INT.
// otel_rpc_interceptor.dart:181,209 ; rpc_otel_metrics.dart:60-63.
//
// Per semconv (rpc.grpc.status_code) the value MUST be an int (0 = OK).
// CORRECT: the span attribute value is an int. With the bug it is the String
// 'OK' -> CONFIRMED.

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
      reason: 'semconv requires rpc.grpc.status_code as int. '
          'Got: $value (${value.runtimeType}). '
          'String -> CONFIRMED.',
    );
  });
}
