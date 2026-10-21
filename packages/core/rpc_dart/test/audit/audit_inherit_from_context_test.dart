// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `forward` keeps the parent's cancellation token, deadline and headers
// whether or not the parent has a trace ID; it only generates a trace ID when
// one is missing.
//
// fvm dart test test/audit/audit_inherit_from_context_test.dart

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  test(
    'forward keeps cancellation token + deadline of a traceId-less parent',
    () {
      final token = RpcCancellationToken();
      final deadline = DateTime.now().add(const Duration(seconds: 30));

      // Parent has a token, deadline and a header but NO trace ID.
      final parent = RpcContext.withCancellation(
        token,
      ).withDeadline(deadline).withAdditionalHeaders({'x-custom': 'value'});
      expect(parent.traceId, isNull, reason: 'precondition: no trace ID');

      final child = parent.forward();

      expect(
        identical(child.cancellationToken, token),
        isTrue,
        reason: 'cancellation token must be inherited',
      );
      expect(child.deadline, deadline, reason: 'deadline must be inherited');
      expect(
        child.getHeader('x-custom'),
        'value',
        reason: 'headers must be inherited',
      );
      expect(
        child.traceId,
        isNotNull,
        reason: 'a fresh trace ID must be generated when parent lacks one',
      );
      expect(
        child.requestId,
        isNot(parent.requestId),
        reason: 'a new request ID must be generated for the child call',
      );
    },
  );

  test('forward inherits trace ID when parent has one', () {
    final parent = RpcContext.withTraceId('trace_parent');
    final child = parent.forward();
    expect(child.traceId, 'trace_parent');
  });
}
