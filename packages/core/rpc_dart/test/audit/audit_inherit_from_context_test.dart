// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding: RpcContextBuilder.inheritFrom(parent) only inherited from the
// parent when parent.traceId != null. A parent that carried a cancellation
// token / deadline / headers but no trace ID was discarded entirely, returning
// a fresh empty context — losing cancellation propagation and deadlines.
//
// CORRECT behavior: a non-null parent's state must be inherited regardless of
// whether it has a trace ID; only a fresh trace ID is generated when missing.
//
// fvm dart test test/audit/audit_inherit_from_context_test.dart

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  test(
    'inheritFrom keeps cancellation token + deadline of a traceId-less parent',
    () {
      final token = RpcCancellationToken();
      final deadline = DateTime.now().add(const Duration(seconds: 30));

      // Parent has a token, deadline and a header but NO trace ID.
      final parent = RpcContextBuilder()
          .withCancellation(token)
          .withDeadline(deadline)
          .withHeader('x-custom', 'value')
          .build();
      expect(parent.traceId, isNull, reason: 'precondition: no trace ID');

      final child = RpcContextBuilder.inheritFrom(parent).build();

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

  test('inheritFrom inherits trace ID when parent has one', () {
    final parent = RpcContextBuilder().withTraceId('trace_parent').build();
    final child = RpcContextBuilder.inheritFrom(parent).build();
    expect(child.traceId, 'trace_parent');
  });

  test('inheritFrom(null) generates fresh trace + request IDs', () {
    final child = RpcContextBuilder.inheritFrom(null).build();
    expect(child.traceId, isNotNull);
    expect(child.requestId, isNotEmpty);
  });
}
