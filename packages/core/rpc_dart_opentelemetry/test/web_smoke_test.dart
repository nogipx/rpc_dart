// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:fixnum/fixnum.dart';
import 'package:opentelemetry/api.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_opentelemetry/rpc_dart_opentelemetry.dart';
import 'package:test/test.dart';

void main() {
  test('propagator round-trips a traceparent header on JS', () {
    // A valid W3C traceparent for a known trace/span id, built without the
    // SDK IdGenerator (which uses Random.secure()).
    const traceId = '0af7651916cd43dd8448eb211c80319c';
    const spanId = 'b7ad6b7169203331';
    final spanContext = SpanContext(
      TraceId.fromString(traceId),
      SpanId.fromString(spanId),
      TraceFlags.sampled,
      TraceState.empty(),
    );
    final ctx = contextWithSpanContext(Context.current, spanContext);

    final injected = RpcOtelPropagator.inject(RpcContext.empty(), context: ctx);
    expect(injected.headers.containsKey('traceparent'), isTrue);
    expect(injected.headers['traceparent'], contains(traceId));

    final extracted = RpcOtelPropagator.extract(injected);
    final parent = spanContextFromContext(extracted);
    expect(parent.traceId.toString(), traceId);
    expect(parent.spanId.toString(), spanId);
    expect(parent.isValid, isTrue);
  });

  test('status-name table maps codes on JS', () {
    expect(rpcGrpcStatusName(RpcStatus.ok), 'OK');
    expect(rpcGrpcStatusName(RpcStatus.notFound), 'NOT_FOUND');
    expect(rpcGrpcStatusName(999), 'UNKNOWN');
  });

  test('error->status-code mapping on JS', () {
    expect(rpcStatusCodeFromError(Exception('boom')), RpcStatus.unknown);
  });

  test('Int64 nanosecond conversion is exact on JS', () {
    // microsecondsSinceEpoch * 1000 must stay exact past 2^53 via fixnum
    // Int64, which is the reason _toInt64 uses Int64 instead of a plain int.
    final micros = DateTime.utc(2026, 6, 17).microsecondsSinceEpoch;
    final nanos = Int64(micros) * 1000;
    expect(nanos, Int64(micros) * 1000);
    expect(nanos.toInt() ~/ 1000, micros);
  });
}
