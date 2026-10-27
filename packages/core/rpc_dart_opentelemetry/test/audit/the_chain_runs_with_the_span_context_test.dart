@TestOn('vm || chrome')
library;

// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The context an interceptor hands to the rest of the chain: on the server
// it carries the span under OtelRpcKeys.span, on the client the W3C
// traceparent of the client span.

import 'package:opentelemetry/api.dart' as api;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_opentelemetry/rpc_dart_opentelemetry.dart';
import 'package:test/test.dart';

import '_support.dart';

void main() {
  test('the server hands the span to the handler', () async {
    final t = buildTracer();
    final interceptor = OtelRpcInterceptor(tracer: t.tracer);

    Object? seen;
    await interceptor.interceptUnary<String, String>(buildCall(), 'req', (
      ctx,
      req,
    ) async {
      seen = ctx.getValue(OtelRpcKeys.span);
      return 'res';
    });

    expect(seen, isA<api.Span>());
  });

  test('the client sends the traceparent of its span', () async {
    final t = buildTracer();
    final interceptor = OtelRpcClientInterceptor(tracer: t.tracer);

    RpcContext? seen;
    await interceptor.interceptUnary<String, String>(
      buildCall(direction: RpcCallDirection.outgoing),
      'req',
      (ctx, req) async {
        seen = ctx;
        return 'res';
      },
    );

    final span = t.exporter.spans.single;
    expect(
      seen!.headers['traceparent'],
      contains(span.spanContext.traceId.toString()),
    );
  });
}
