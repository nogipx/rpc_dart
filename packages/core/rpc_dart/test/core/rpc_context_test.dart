// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RpcContext', () {
    group('creating a context', () {
      test('empty() gives the base fields', () {
        // Arrange & Act
        final sut = RpcContext.empty();

        // Assert
        expect(sut.headers, isEmpty);
        expect(sut.deadline, isNull);
        expect(sut.cancellationToken, isNull);
        expect(sut.traceId, isNull);
        expect(sut.requestId, isNotEmpty);
        expect(sut.values, isEmpty);
        expect(sut.isExpired, isFalse);
        expect(sut.isCancelled, isFalse);
        expect(sut.remainingTime, isNull);
      });

      test('withHeaders() carries the headers', () {
        // Arrange
        final headers = <String, String>{
          'authorization': 'Bearer token-123',
          'user-id': 'user-456',
          'content-type': 'application/json',
        };

        // Act
        final sut = RpcContext.withHeaders(headers);

        // Assert
        expect(sut.headers, equals(headers));
        expect(sut.getHeader('authorization'), equals('Bearer token-123'));
        expect(sut.getHeader('user-id'), equals('user-456'));
        expect(sut.getHeader('non-existent'), isNull);
      });

      test('a context can carry a deadline', () {
        // Arrange
        final deadline = DateTime.now().add(Duration(hours: 1));

        // Act
        final sut = RpcContext.withDeadline(deadline);

        // Assert
        expect(sut.deadline, equals(deadline));
        expect(sut.isExpired, isFalse);
        expect(sut.remainingTime, isA<Duration>());
        expect(sut.remainingTime!.inMinutes, greaterThanOrEqualTo(59));
      });

      test('a context can carry a timeout', () {
        // Arrange
        final timeout = Duration(minutes: 30);
        final beforeCreation = DateTime.now().add(timeout);

        // Act
        final sut = RpcContext.withTimeout(timeout);

        // Assert
        final afterCreation = DateTime.now().add(timeout);
        expect(sut.deadline, isNotNull);
        expect(
          sut.deadline!.isAfter(beforeCreation.subtract(Duration(seconds: 1))),
          isTrue,
        );
        expect(
          sut.deadline!.isBefore(afterCreation.add(Duration(seconds: 1))),
          isTrue,
        );
      });

      test('a context can carry a cancellation token', () {
        // Arrange
        final cancellationToken = RpcCancellationToken();

        // Act
        final sut = RpcContext.withCancellation(cancellationToken);

        // Assert
        expect(sut.cancellationToken, equals(cancellationToken));
        expect(sut.isCancelled, isFalse);
      });

      test('a context can carry a trace id', () {
        // Arrange
        const traceId = 'trace-id-12345';

        // Act
        final sut = RpcContext.withTraceId(traceId);

        // Assert
        expect(sut.traceId, equals(traceId));
      });
    });

    group('modifying a context', () {
      late RpcContext baseSut;

      setUp(() {
        baseSut = RpcContext.withHeaders({
          'existing': 'header',
        }).withTraceId('base-trace');
      });

      test('adding headers keeps the ones already there', () {
        // Arrange
        final additionalHeaders = <String, String>{
          'new-header': 'new-value',
          'another': 'value',
        };

        // Act
        final sut = baseSut.withAdditionalHeaders(additionalHeaders);

        // Assert
        expect(sut.getHeader('existing'), equals('header'));
        expect(sut.getHeader('new-header'), equals('new-value'));
        expect(sut.getHeader('another'), equals('value'));
        expect(sut.traceId, equals('base-trace')); // Others preserved.
      });

      test('adding a header that exists overwrites it', () {
        // Arrange
        final overrideHeaders = <String, String>{
          'existing': 'new-value',
          'additional': 'header',
        };

        // Act
        final sut = baseSut.withAdditionalHeaders(overrideHeaders);

        // Assert
        expect(sut.getHeader('existing'), equals('new-value'));
        expect(sut.getHeader('additional'), equals('header'));
      });

      test('sets a new deadline', () {
        // Arrange
        final newDeadline = DateTime.now().add(Duration(hours: 2));

        // Act
        final sut = baseSut.withDeadline(newDeadline);

        // Assert
        expect(sut.deadline, equals(newDeadline));
        expect(
          sut.getHeader('existing'),
          equals('header'),
        ); // The other fields are preserved.
        expect(sut.traceId, equals('base-trace'));
      });

      test('sets a timeout relative to now', () {
        // Arrange
        final timeout = Duration(minutes: 45);
        final beforeCreation = DateTime.now().add(timeout);

        // Act
        final sut = baseSut.withTimeout(timeout);

        // Assert
        final afterCreation = DateTime.now().add(timeout);
        expect(sut.deadline, isNotNull);
        expect(
          sut.deadline!.isAfter(beforeCreation.subtract(Duration(seconds: 1))),
          isTrue,
        );
        expect(
          sut.deadline!.isBefore(afterCreation.add(Duration(seconds: 1))),
          isTrue,
        );
      });

      test('sets a cancellation token', () {
        // Arrange
        final cancellationToken = RpcCancellationToken();

        // Act
        final sut = baseSut.withCancellation(cancellationToken);

        // Assert
        expect(sut.cancellationToken, equals(cancellationToken));
        expect(
          sut.getHeader('existing'),
          equals('header'),
        ); // The other fields are preserved.
      });

      test('sets a new trace id', () {
        // Arrange
        const newTraceId = 'new-trace-id-789';

        // Act
        final sut = baseSut.withTraceId(newTraceId);

        // Assert
        expect(sut.traceId, equals(newTraceId));
        expect(
          sut.getHeader('existing'),
          equals('header'),
        ); // The other fields are preserved.
      });

      test('adds a value to the context', () {
        // Arrange
        const key = 'user-data';
        const value = 'important-value';

        // Act
        final sut = baseSut.withValue(key, value);

        // Assert
        expect(sut.getValue<String>(key), equals(value));
        expect(sut.getValue<int>('non-existent'), isNull);
        expect(
          sut.getHeader('existing'),
          equals('header'),
        ); // The other fields are preserved.
      });
    });

    group('state', () {
      test('sees an expired deadline', () {
        // Arrange
        final expiredDeadline = DateTime.now().subtract(Duration(minutes: 1));
        final sut = RpcContext.withDeadline(expiredDeadline);

        // Act & Assert
        expect(sut.isExpired, isTrue);
        expect(sut.remainingTime, equals(Duration.zero));
      });

      test('sees a live deadline', () {
        // Arrange
        final futureDeadline = DateTime.now().add(Duration(hours: 1));
        final sut = RpcContext.withDeadline(futureDeadline);

        // Act & Assert
        expect(sut.isExpired, isFalse);
        expect(sut.remainingTime, isA<Duration>());
        expect(sut.remainingTime!.inMinutes, greaterThanOrEqualTo(59));
      });

      test('sees a cancelled context', () {
        // Arrange
        final cancellationToken = RpcCancellationToken();
        final sut = RpcContext.withCancellation(cancellationToken);

        // Act
        cancellationToken.cancel('the user cancelled the operation');

        // Assert
        expect(sut.isCancelled, isTrue);
      });

      test('sees a context that is not cancelled', () {
        // Arrange
        final cancellationToken = RpcCancellationToken();
        final sut = RpcContext.withCancellation(cancellationToken);

        // Act & Assert
        expect(sut.isCancelled, isFalse);
      });
    });

    group('reading the data', () {
      test('the headers come back unmodifiable', () {
        // Arrange
        final originalHeaders = <String, String>{'key': 'value'};
        final sut = RpcContext.withHeaders(originalHeaders);

        // Act
        final headers = sut.headers;

        // Assert
        expect(() => headers['new'] = 'value', throwsUnsupportedError);
      });

      test('the values come back unmodifiable', () {
        // Arrange
        final sut = RpcContext.empty().withValue('key', 'value');

        // Act
        final values = sut.values;

        // Assert
        expect(() => values['new'] = 'value', throwsUnsupportedError);
      });

      test('a value comes back at its declared type', () {
        // Arrange
        final sut = RpcContext.empty()
            .withValue('string-key', 'string-value')
            .withValue('int-key', 42)
            .withValue('list-key', [1, 2, 3]);

        // Act & Assert
        expect(sut.getValue<String>('string-key'), equals('string-value'));
        expect(sut.getValue<int>('int-key'), equals(42));
        expect(sut.getValue<List<int>>('list-key'), equals([1, 2, 3]));

        // Asking for the wrong type must throw on the cast.
        expect(
          () => sut.getValue<String>('int-key'),
          throwsA(isA<TypeError>()),
        );
      });
    });

    group('request id', () {
      test('every request id is unique', () async {
        // Arrange & Act
        final context1 = RpcContext.empty();
        // A short delay, so the two timestamps differ.
        await Future<void>.delayed(Duration(milliseconds: 1));
        final context2 = RpcContext.empty();
        await Future<void>.delayed(Duration(milliseconds: 1));
        final context3 = RpcContext.empty();

        // Assert
        expect(context1.requestId, isNotEmpty);
        expect(context2.requestId, isNotEmpty);
        expect(context3.requestId, isNotEmpty);
        expect(context1.requestId, isNot(equals(context2.requestId)));
        expect(context2.requestId, isNot(equals(context3.requestId)));
        expect(context1.requestId, isNot(equals(context3.requestId)));
      });

      test('the request id survives a modification', () {
        // Arrange
        final originalSut = RpcContext.empty();
        final originalRequestId = originalSut.requestId;

        // Act
        final modifiedSut = originalSut
            .withAdditionalHeaders({'test': 'header'})
            .withTimeout(Duration(minutes: 5))
            .withValue('key', 'value');

        // Assert
        expect(modifiedSut.requestId, equals(originalRequestId));
      });
    });

    group('toString', () {
      test('prints the basics', () {
        // Arrange
        final sut = RpcContext.empty();

        // Act
        final result = sut.toString();

        // Assert
        expect(result, contains('RpcContext'));
        expect(result, contains('requestId: ${sut.requestId}'));
      });

      test('prints every field that is set', () {
        // Arrange
        final cancellationToken = RpcCancellationToken();
        final deadline = DateTime.now().add(Duration(hours: 1));
        final sut = RpcContext.withHeaders({'auth': 'token'})
            .withDeadline(deadline)
            .withCancellation(cancellationToken)
            .withTraceId('trace-123')
            .withValue('key', 'value');

        // Act
        final result = sut.toString();

        // Assert
        expect(result, contains('traceId: trace-123'));
        expect(result, contains('deadline: $deadline'));
        expect(result, contains('headers: 1'));
        expect(result, contains('values: 1'));
        expect(result, isNot(contains('CANCELLED')));
        expect(result, isNot(contains('EXPIRED')));
      });

      test('prints that it is cancelled', () {
        // Arrange
        final cancellationToken = RpcCancellationToken();
        final sut = RpcContext.withCancellation(cancellationToken);

        // Act
        cancellationToken.cancel();
        final result = sut.toString();

        // Assert
        expect(result, contains('CANCELLED'));
      });

      test('prints that it has expired', () {
        // Arrange
        final expiredDeadline = DateTime.now().subtract(Duration(minutes: 1));
        final sut = RpcContext.withDeadline(expiredDeadline);

        // Act
        final result = sut.toString();

        // Assert
        expect(result, contains('EXPIRED'));
      });
    });
  });

  group('CancellationToken', () {
    group('creating a token', () {
      test('a fresh token is live', () {
        // Arrange & Act
        final sut = RpcCancellationToken();

        // Assert
        expect(sut.isCancelled, isFalse);
        expect(sut.reason, isNull);
      });

      test('cancelled() gives an already-cancelled token', () {
        // Arrange
        const reason = 'cancelled up front';

        // Act
        final sut = RpcCancellationToken.cancelled(reason);

        // Assert
        expect(sut.isCancelled, isTrue);
        expect(sut.reason, equals(reason));
      });

      test('cancelled() without a reason leaves reason null', () {
        // Arrange & Act
        final sut = RpcCancellationToken.cancelled();

        // Assert
        expect(sut.isCancelled, isTrue);
        expect(sut.reason, isNull);
      });
    });

    group('cancelling a token', () {
      test('cancels a live token', () {
        // Arrange
        final sut = RpcCancellationToken();
        const reason = 'the user cancelled';

        // Act
        sut.cancel(reason);

        // Assert
        expect(sut.isCancelled, isTrue);
        expect(sut.reason, equals(reason));
      });

      test('cancels without a reason', () {
        // Arrange
        final sut = RpcCancellationToken();

        // Act
        sut.cancel();

        // Assert
        expect(sut.isCancelled, isTrue);
        expect(sut.reason, isNull);
      });

      test('a second cancel is ignored', () {
        // Arrange
        final sut = RpcCancellationToken();
        sut.cancel('the first reason');

        // Act
        sut.cancel('the second reason');

        // Assert
        expect(sut.isCancelled, isTrue);
        expect(
          sut.reason,
          equals('the first reason'),
        ); // The first reason is the one kept.
      });

      test('the future completes on cancel', () async {
        // Arrange
        final sut = RpcCancellationToken();
        bool notified = false;

        // Act
        unawaited(sut.cancelled.then((_) => notified = true));
        sut.cancel();

        // Let the callback run.
        await Future<void>.delayed(Duration.zero);

        // Assert
        expect(notified, isTrue);
      });
    });

    group('throwIfCancelled', () {
      test('a live token does not throw', () {
        // Arrange
        final sut = RpcCancellationToken();

        // Act & Assert
        expect(() => sut.throwIfCancelled(), returnsNormally);
      });

      test('a cancelled token throws, carrying the reason', () {
        // Arrange
        final sut = RpcCancellationToken();
        const reason = 'the token was cancelled';
        sut.cancel(reason);

        // Act & Assert
        expect(
          () => sut.throwIfCancelled(),
          throwsA(
            isA<RpcCancelledException>().having(
              (e) => e.message,
              'message',
              contains(reason),
            ),
          ),
        );
      });

      test('with no reason it throws the default message', () {
        // Arrange
        final sut = RpcCancellationToken();
        sut.cancel(); // No reason given.

        // Act & Assert
        expect(
          () => sut.throwIfCancelled(),
          throwsA(
            isA<RpcCancelledException>().having(
              (e) => e.message,
              'message',
              'Operation was cancelled',
            ),
          ),
        );
      });
    });
  });

  group('RpcContextUtils', () {
    group('authentication', () {
      test('basic auth', () {
        // Arrange
        const username = 'testuser';
        const password = 'testpass';
        final expectedCredentials = base64Encode(
          utf8.encode('$username:$password'),
        );

        // Act
        final sut = RpcContextUtils.withBasicAuth(username, password);

        // Assert
        expect(
          sut.getHeader('authorization'),
          equals('Basic $expectedCredentials'),
        );
      });

      test('a bearer token', () {
        // Arrange
        const token = 'abc123def456';

        // Act
        final sut = RpcContextUtils.withBearerToken(token);

        // Assert
        expect(sut.getHeader('authorization'), equals('Bearer $token'));
      });

      test('an api key', () {
        // Arrange
        const key = 'api-key-12345';

        // Act
        final sut = RpcContextUtils.withApiKey(key);

        // Assert
        expect(sut.getHeader('x-api-key'), equals(key));
      });

      test('an api key under a custom header', () {
        // Arrange
        const key = 'custom-api-key';
        const headerName = 'custom-auth-header';

        // Act
        final sut = RpcContextUtils.withApiKey(key, headerName: headerName);

        // Assert
        expect(sut.getHeader(headerName), equals(key));
        expect(sut.getHeader('x-api-key'), isNull);
      });
    });

    group('tracing', () {
      test('a full trace: trace id, span id, parent span id', () {
        // Arrange
        const traceId = 'trace-123';
        const spanId = 'span-456';
        const parentSpanId = 'parent-789';

        // Act
        final sut = RpcContextUtils.withTracing(
          traceId: traceId,
          spanId: spanId,
          parentSpanId: parentSpanId,
        );

        // Assert
        expect(sut.getHeader('x-trace-id'), equals(traceId));
        expect(sut.getHeader('x-span-id'), equals(spanId));
        expect(sut.getHeader('x-parent-span-id'), equals(parentSpanId));
        expect(sut.traceId, equals(traceId));
      });

      test('a trace id on its own', () {
        // Arrange
        const traceId = 'trace-only';

        // Act
        final sut = RpcContextUtils.withTracing(traceId: traceId);

        // Assert
        expect(sut.getHeader('x-trace-id'), equals(traceId));
        expect(sut.getHeader('x-span-id'), isNull);
        expect(sut.getHeader('x-parent-span-id'), isNull);
        expect(sut.traceId, equals(traceId));
      });

      test('a trace id is generated when none is given', () {
        // Arrange & Act
        final sut = RpcContextUtils.withTracing();

        // Assert
        expect(sut.traceId, isNotNull);
        expect(sut.traceId, isNotEmpty);
        expect(sut.traceId, startsWith('trace_'));
        // With no traceId passed one is generated, but no header is set.
        expect(sut.getHeader('x-trace-id'), isNull);
      });

      test('generateTraceId is unique within one millisecond', () {
        // Tight loop -> many ids share the same millisecond timestamp.
        final ids = <String>{};
        for (var i = 0; i < 10000; i++) {
          ids.add(RpcContextUtils.generateTraceId());
        }
        expect(ids.length, 10000, reason: 'all trace ids must be unique');
        expect(ids.every((id) => id.startsWith('trace_')), isTrue);
      });
    });

    group('merging two contexts', () {
      test('headers from both are kept', () {
        // Arrange
        final leftSut = RpcContext.withHeaders({
          'left-header': 'left-value',
          'common': 'left',
        });
        final rightSut = RpcContext.withHeaders({
          'right-header': 'right-value',
          'common': 'right',
        });

        // Act
        final merged = RpcContextUtils.merge(leftSut, rightSut);

        // Assert
        expect(merged.getHeader('left-header'), equals('left-value'));
        expect(merged.getHeader('right-header'), equals('right-value'));
        expect(
          merged.getHeader('common'),
          equals('right'),
        ); // The right-hand side wins.
      });

      test('values from both are kept', () {
        // Arrange
        final leftSut = RpcContext.empty()
            .withValue('left-key', 'left-value')
            .withValue('common-key', 'left');
        final rightSut = RpcContext.empty()
            .withValue('right-key', 'right-value')
            .withValue('common-key', 'right');

        // Act
        final merged = RpcContextUtils.merge(leftSut, rightSut);

        // Assert
        expect(merged.getValue<String>('left-key'), equals('left-value'));
        expect(merged.getValue<String>('right-key'), equals('right-value'));
        expect(
          merged.getValue<String>('common-key'),
          equals('right'),
        ); // The right-hand side wins.
      });

      test('for the special fields the right-hand side wins', () {
        // Arrange
        final leftDeadline = DateTime.now().add(Duration(hours: 1));
        final rightDeadline = DateTime.now().add(Duration(hours: 2));
        final leftToken = RpcCancellationToken();
        final rightToken = RpcCancellationToken();

        final leftSut = RpcContext.withDeadline(
          leftDeadline,
        ).withCancellation(leftToken).withTraceId('left-trace');
        final rightSut = RpcContext.withDeadline(
          rightDeadline,
        ).withCancellation(rightToken).withTraceId('right-trace');

        // Act
        final merged = RpcContextUtils.merge(leftSut, rightSut);

        // Assert
        expect(merged.deadline, equals(rightDeadline));
        expect(merged.cancellationToken, equals(rightToken));
        expect(merged.traceId, equals('right-trace'));
        expect(merged.requestId, equals(rightSut.requestId));
      });

      test('the left-hand side is used where the right is null', () {
        // Arrange
        final deadline = DateTime.now().add(Duration(hours: 1));
        final token = RpcCancellationToken();
        const traceId = 'left-trace';

        final leftSut = RpcContext.withDeadline(
          deadline,
        ).withCancellation(token).withTraceId(traceId);
        final rightSut = RpcContext.empty();

        // Act
        final merged = RpcContextUtils.merge(leftSut, rightSut);

        // Assert
        expect(merged.deadline, equals(deadline));
        expect(merged.cancellationToken, equals(token));
        expect(merged.traceId, equals(traceId));
      });
    });
  });

  group('exceptions', () {
    test('RpcCancelledException carries its message', () {
      // Arrange
      const message = 'the operation was cancelled by the user';

      // Act
      final sut = RpcCancelledException(message);

      // Assert
      expect(sut.message, equals(message));
      expect(sut.toString(), equals('RpcCancelledException: $message'));
    });

    test('RpcDeadlineExceededException carries deadline and timeout', () {
      // Arrange
      final deadline = DateTime.now().add(Duration(minutes: 5));
      final timeout = Duration(minutes: 5);

      // Act
      final sut = RpcDeadlineExceededException(deadline, timeout);

      // Assert
      expect(sut.deadline, equals(deadline));
      expect(sut.timeout, equals(timeout));
      expect(sut.toString(), contains('Deadline $deadline exceeded'));
      expect(sut.toString(), contains('timeout: $timeout'));
    });
  });
}
