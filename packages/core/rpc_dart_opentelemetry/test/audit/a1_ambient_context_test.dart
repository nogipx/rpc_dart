@TestOn('vm || chrome')
library;

// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:opentelemetry/api.dart' as api;
import 'package:rpc_dart_opentelemetry/rpc_dart_opentelemetry.dart';
import 'package:test/test.dart';

import '_support.dart';

void main() {
  test(
    'child span created in handler is parented under the RPC span',
    () async {
      final t = buildTracer();
      final interceptor = OtelRpcInterceptor(tracer: t.tracer);
      final call = buildCall();

      late api.SpanContext childSpanContext;

      // Drive the interceptor; the "handler" is `next`.
      await interceptor.interceptUnary<String, String>(call, 'req', (
        ctx,
        req,
      ) async {
        // Handler reads ambient OTel context to parent its own work span.
        final child = t.tracer.startSpan(
          'handler.work',
          context: api.Context.current,
        );
        childSpanContext = child.spanContext;
        child.end();
        return 'res';
      });

      // Find the RPC server span among exported spans.
      final rpcSpan = t.exporter.spans.firstWhere(
        (s) => s.name == 'TestService/testMethod',
      );
      final rpcSpanId = rpcSpan.spanContext.spanId.toString();

      final childSpanId = childSpanContext.spanId.toString();
      // The child's parent span id (read from the exported child span).
      final childSpan = t.exporter.spans.firstWhere(
        (s) => s.spanContext.spanId.toString() == childSpanId,
      );
      final childParentId = childSpan.parentSpanId.toString();

      // CORRECT: child parent == RPC span. With the bug, childParentId is the
      // invalid/zero span id (root) because Context.current was never set.
      expect(
        childParentId,
        equals(rpcSpanId),
        reason:
            'Handler-created span should nest under the RPC span. '
            'childParentId=$childParentId rpcSpanId=$rpcSpanId '
            '(if not equal -> ambient Context never activated -> CONFIRMED).',
      );
    },
  );
}
