// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:opentelemetry/api.dart' as api;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_opentelemetry/rpc_dart_opentelemetry.dart';
import 'package:test/test.dart';

import '_support.dart';

/// A peer endpoint makes and serves calls through one interceptor list: the
/// server and client interceptors on it each take only their side.
void main() {
  late ({api.Tracer tracer, InMemorySpanExporter exporter, dynamic provider}) a;
  late ({api.Tracer tracer, InMemorySpanExporter exporter, dynamic provider}) b;
  late RpcPeerEndpoint left;
  late RpcPeerEndpoint right;

  void instrument(
    RpcPeerEndpoint e,
    api.Tracer tracer, {
    bool Function(RpcCallInfo call)? where,
  }) => e
    ..addInterceptor(OtelRpcInterceptor(tracer: tracer, where: where))
    ..addInterceptor(OtelRpcClientInterceptor(tracer: tracer, where: where));

  Future<void> callBoth() async {
    for (final (from, name) in [(left, 'left'), (right, 'right')]) {
      await from.unary<RpcString, RpcString>(
        serviceName: 'Echo',
        methodName: 'Say',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: name.rpc,
      );
    }
  }

  setUp(() {
    a = buildTracer();
    b = buildTracer();
    final (l, r) = RpcChannelTransport.memoryPair();
    left = RpcPeerEndpoint(transport: l);
    right = RpcPeerEndpoint(transport: r);
    for (final e in [left, right]) {
      e
        ..registerServiceContract(_Echo())
        ..start();
    }
  });

  tearDown(() async {
    await left.close();
    await right.close();
  });

  test('each call is one client span where it is made and one server span '
      'where it is served, in one trace', () async {
    instrument(left, a.tracer);
    instrument(right, b.tracer);
    await callBoth();

    final kinds = [for (final s in a.exporter.spans) s.kind];
    expect(kinds, unorderedEquals([api.SpanKind.client, api.SpanKind.server]));
    expect(
      b.exporter.spans.map((s) => s.kind),
      unorderedEquals([api.SpanKind.server, api.SpanKind.client]),
    );

    final made = a.exporter.spans.firstWhere(
      (s) => s.kind == api.SpanKind.client,
    );
    final served = b.exporter.spans.firstWhere(
      (s) => s.kind == api.SpanKind.server,
    );
    expect(
      served.spanContext.traceId.toString(),
      made.spanContext.traceId.toString(),
    );
    expect(served.parentSpanId.toString(), made.spanContext.spanId.toString());
  });

  test('a call where turns down passes through untraced', () async {
    bool notSay(RpcCallInfo call) => call.methodName != 'Say';
    instrument(left, a.tracer, where: notSay);
    instrument(right, b.tracer, where: notSay);
    await callBoth();
    expect(a.exporter.spans, isEmpty);
    expect(b.exporter.spans, isEmpty);
  });
}

final class _Echo extends RpcResponderContract {
  _Echo() : super('Echo');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Say',
      handler: (request, {context}) async => request,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }
}
