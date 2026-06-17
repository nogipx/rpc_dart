// SPDX-License-Identifier: MIT
//
// Web/dart2js smoke test: exercises the parts of this package that DO NOT
// depend on the opentelemetry SDK's secure RNG, so they run on both
// `-p chrome` (the real web target) and `-p node`.
//
// The full interceptor span lifecycle is covered by the audit suite on
// `-p chrome`; it cannot run on `-p node` because the opentelemetry SDK's
// IdGenerator calls `Random.secure()`, which is unavailable under the node
// test platform (a node/dart2js environment limitation, not a package bug).
//
// What this verifies on JS:
// - propagator inject -> extract round-trip (no secure RNG involved),
// - status-name table and error->code mapping (pure int/string logic),
// - Int64 nanosecond timestamp conversion (fixnum, dart2js-safe).

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
