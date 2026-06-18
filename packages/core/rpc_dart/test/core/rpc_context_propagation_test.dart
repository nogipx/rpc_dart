// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:test/test.dart';
import 'package:rpc_dart/rpc_dart.dart';

void main() {
  group('RpcContext', () {
    test('creates empty context with unique request ID', () {
      final context1 = RpcContext.empty();
      final context2 = RpcContext.empty();

      expect(context1.requestId, isNotEmpty);
      expect(context2.requestId, isNotEmpty);
      expect(context1.requestId, startsWith('req_'));
      expect(context2.requestId, startsWith('req_'));
      expect(context1.headers, isEmpty);
      expect(context1.traceId, isNull);
      expect(context1.deadline, isNull);
    });

    test('creates context with headers', () {
      final headers = {'x-user-id': '123', 'x-session': 'abc'};
      final context = RpcContext.withHeaders(headers);

      expect(context.headers, equals(headers));
      expect(context.getHeader('x-user-id'), equals('123'));
      expect(context.getHeader('x-session'), equals('abc'));
      expect(context.getHeader('nonexistent'), isNull);
    });

    test('creates context with deadline', () {
      final deadline = DateTime.now().add(Duration(minutes: 5));
      final context = RpcContext.withDeadline(deadline);

      expect(context.deadline, equals(deadline));
      expect(context.isExpired, isFalse);
      expect(context.remainingTime, isNotNull);
      expect(context.remainingTime!.inMinutes, lessThanOrEqualTo(5));
    });

    test('creates context with timeout', () {
      final timeout = Duration(minutes: 10);
      final context = RpcContext.withTimeout(timeout);

      expect(context.deadline, isNotNull);
      expect(context.isExpired, isFalse);
      expect(context.remainingTime!.inMinutes, lessThanOrEqualTo(10));
    });

    test('detects expired deadline', () {
      final pastDeadline = DateTime.now().subtract(Duration(minutes: 1));
      final context = RpcContext.withDeadline(pastDeadline);

      expect(context.isExpired, isTrue);
      expect(context.remainingTime, equals(Duration.zero));
    });

    test('merges additional headers', () {
      final originalHeaders = {'x-user-id': '123'};
      final additionalHeaders = {'x-session': 'abc', 'x-trace': '456'};

      final context = RpcContext.withHeaders(
        originalHeaders,
      ).withAdditionalHeaders(additionalHeaders);

      expect(context.headers['x-user-id'], equals('123'));
      expect(context.headers['x-session'], equals('abc'));
      expect(context.headers['x-trace'], equals('456'));
      expect(context.headers.length, equals(3));
    });

    test('stores and retrieves typed values', () {
      final key1 = 'user';
      final key2 = 42;
      final value1 = 'John Doe';
      final value2 = Duration(minutes: 5);

      final context = RpcContext.empty()
          .withValue(key1, value1)
          .withValue(key2, value2);

      expect(context.getValue<String>(key1), equals(value1));
      expect(context.getValue<Duration>(key2), equals(value2));
      expect(context.getValue<String>('nonexistent'), isNull);
    });

    test('isContextValid detects expired and cancelled contexts', () {
      final validContext = RpcContext.empty();
      final expiredContext = RpcContext.withDeadline(
        DateTime.now().subtract(Duration(minutes: 1)),
      );
      final cancelledToken = RpcCancellationToken.cancelled();
      final cancelledContext = RpcContext.withCancellation(cancelledToken);

      expect(RpcContext.isContextValid(validContext), isTrue);
      expect(RpcContext.isContextValid(expiredContext), isFalse);
      expect(RpcContext.isContextValid(cancelledContext), isFalse);
      expect(RpcContext.isContextValid(null), isFalse);
    });

    test('sanitize removes sensitive headers', () {
      final context = RpcContext.withHeaders({
        'authorization': 'Bearer secret-token',
        'x-api-key': 'secret-key',
        'cookie': 'session=secret',
        'x-user-id': '123',
        'x-public-data': 'safe-value',
      }).withTraceId('trace-123');

      final sanitized = RpcContext.sanitize(context);

      expect(sanitized.getHeader('authorization'), isNull);
      expect(sanitized.getHeader('x-api-key'), isNull);
      expect(sanitized.getHeader('cookie'), isNull);
      expect(sanitized.getHeader('x-user-id'), equals('123'));
      expect(sanitized.getHeader('x-public-data'), equals('safe-value'));
      expect(sanitized.traceId, equals('trace-123'));
    });
  });

  group('CancellationToken', () {
    test('creates uncancelled token', () {
      final token = RpcCancellationToken();

      expect(token.isCancelled, isFalse);
      expect(token.reason, isNull);
    });

    test('creates pre-cancelled token', () {
      final reason = 'User cancelled';
      final token = RpcCancellationToken.cancelled(reason);

      expect(token.isCancelled, isTrue);
      expect(token.reason, equals(reason));
    });

    test('cancels token with reason', () {
      final token = RpcCancellationToken();
      final reason = 'Timeout exceeded';

      token.cancel(reason);

      expect(token.isCancelled, isTrue);
      expect(token.reason, equals(reason));
    });

    test('throws on cancelled token check', () {
      final token = RpcCancellationToken.cancelled('Test cancellation');

      expect(
        () => token.throwIfCancelled(),
        throwsA(isA<RpcCancelledException>()),
      );
    });

    test('does not throw for uncancelled token', () {
      final token = RpcCancellationToken();

      expect(() => token.throwIfCancelled(), returnsNormally);
    });
  });

  group('RpcContextUtils', () {
    test('creates context with Basic auth', () {
      final context = RpcContextUtils.withBasicAuth('user', 'pass');
      final authHeader = context.getHeader('authorization');

      expect(authHeader, isNotNull);
      expect(authHeader, startsWith('Basic '));
      expect(authHeader, equals('Basic dXNlcjpwYXNz'));
    });

    test('creates context with Bearer token', () {
      final token = 'abc123token';
      final context = RpcContextUtils.withBearerToken(token);
      final authHeader = context.getHeader('authorization');

      expect(authHeader, equals('Bearer $token'));
    });

    test('creates context with API key', () {
      final apiKey = 'secret-key-123';
      final context = RpcContextUtils.withApiKey(apiKey);

      expect(context.getHeader('x-api-key'), equals(apiKey));
    });

    test('creates context with custom API key header', () {
      final apiKey = 'secret-key-123';
      final headerName = 'x-custom-key';
      final context = RpcContextUtils.withApiKey(
        apiKey,
        headerName: headerName,
      );

      expect(context.getHeader(headerName), equals(apiKey));
      expect(context.getHeader('x-api-key'), isNull);
    });

    test('creates context with tracing headers', () {
      final traceId = 'trace-123';
      final spanId = 'span-456';
      final parentSpanId = 'parent-789';

      final context = RpcContextUtils.withTracing(
        traceId: traceId,
        spanId: spanId,
        parentSpanId: parentSpanId,
      );

      expect(context.getHeader('x-trace-id'), equals(traceId));
      expect(context.getHeader('x-span-id'), equals(spanId));
      expect(context.getHeader('x-parent-span-id'), equals(parentSpanId));
      expect(context.traceId, equals(traceId));
    });

    test('auto-generates trace ID when not provided', () {
      final context = RpcContextUtils.withTracing();

      expect(context.traceId, isNotNull);
      expect(context.traceId, startsWith('trace_'));
    });

    test('merges contexts with right having priority', () {
      final leftContext = RpcContext.withHeaders({
        'x-left': 'left-value',
      }).withTraceId('left-trace').withValue('shared-key', 'left-shared');

      final rightContext = RpcContext.withHeaders({
        'x-right': 'right-value',
      }).withTraceId('right-trace').withValue('shared-key', 'right-shared');

      final merged = RpcContextUtils.merge(leftContext, rightContext);

      expect(merged.traceId, equals('right-trace'));
      expect(merged.requestId, equals(rightContext.requestId));
      expect(merged.getValue('shared-key'), equals('right-shared'));
      expect(merged.getHeader('x-left'), equals('left-value'));
      expect(merged.getHeader('x-right'), equals('right-value'));
    });
  });

  group('RpcContextBuilder', () {
    test('builds context with fluent API', () {
      final timeout = Duration(minutes: 5);
      final traceId = 'trace-123';

      final context = RpcContextBuilder()
          .withTraceId(traceId)
          .withTimeout(timeout)
          .withHeader('x-user-id', '123')
          .withBearerAuth('token-abc')
          .withValue('custom-data', 'test-value')
          .build();

      expect(context.traceId, equals(traceId));
      expect(context.deadline, isNotNull);
      expect(context.getHeader('x-user-id'), equals('123'));
      expect(context.getHeader('authorization'), equals('Bearer token-abc'));
      expect(context.getValue('custom-data'), equals('test-value'));
    });

    test('inherits from parent context', () {
      final parentTraceId = 'parent-trace-123';
      final parentHeaders = {'x-session': 'parent-session'};
      final parent = RpcContext.withHeaders(
        parentHeaders,
      ).withTraceId(parentTraceId);

      final child = RpcContextBuilder.inheritFrom(
        parent,
      ).withHeader('x-user-id', '456').build();

      expect(child.traceId, equals(parentTraceId));
      expect(child.getHeader('x-session'), equals('parent-session'));
      expect(child.getHeader('x-user-id'), equals('456'));
      expect(child.requestId, startsWith('req_'));
    });

    test('generates new trace ID when parent is null', () {
      final child = RpcContextBuilder.inheritFrom(null).build();

      expect(child.traceId, isNotNull);
      expect(child.traceId, startsWith('trace_'));
      expect(child.requestId, isNotEmpty);
    });
  });

  group('RpcContextExtensions', () {
    test('createChild inherits trace ID and generates new request ID', () {
      final parentTraceId = 'parent-trace-123';
      final parent = RpcContext.withTraceId(parentTraceId);

      final child = parent.createChild();

      expect(child.traceId, equals(parentTraceId));
      expect(child.requestId, startsWith('req_'));
      expect(parent.requestId, startsWith('req_'));
    });

    test('createChildWith applies headers and timeout', () {
      final parent = RpcContext.withTraceId('trace-123');
      final additionalHeaders = {'x-custom': 'value'};
      final timeout = Duration(seconds: 30);

      final child = parent.createChildWith(
        headers: additionalHeaders,
        timeout: timeout,
      );

      expect(child.traceId, equals(parent.traceId));
      expect(child.requestId, startsWith('req_'));
      expect(child.getHeader('x-custom'), equals('value'));
      expect(child.deadline, isNotNull);
    });
  });

  group('Integration', () {
    test('cancellation propagates through child context', () {
      final cancellationToken = RpcCancellationToken();
      final timeout = Duration(seconds: 30);

      final context = RpcContextBuilder()
          .withGeneratedTraceId()
          .withTimeout(timeout)
          .withCancellation(cancellationToken)
          .build();

      final childContext = context.createChild();

      expect(childContext.traceId, equals(context.traceId));
      expect(childContext.deadline, equals(context.deadline));
      expect(childContext.cancellationToken, equals(context.cancellationToken));
      expect(childContext.isCancelled, isFalse);

      cancellationToken.cancel('User cancelled');

      expect(childContext.isCancelled, isTrue);
      expect(
        () => childContext.cancellationToken!.throwIfCancelled(),
        throwsA(isA<RpcCancelledException>()),
      );
    });
  });
}
