import 'dart:convert';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RpcContext', () {
    group('создание контекста', () {
      test('создает_пустой_контекст_с_базовыми_параметрами', () {
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

      test('создает_контекст_с_заголовками', () {
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

      test('создает_контекст_с_deadline', () {
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

      test('создает_контекст_с_timeout', () {
        // Arrange
        final timeout = Duration(minutes: 30);
        final beforeCreation = DateTime.now().add(timeout);

        // Act
        final sut = RpcContext.withTimeout(timeout);

        // Assert
        final afterCreation = DateTime.now().add(timeout);
        expect(sut.deadline, isNotNull);
        expect(
            sut.deadline!
                .isAfter(beforeCreation.subtract(Duration(seconds: 1))),
            isTrue);
        expect(sut.deadline!.isBefore(afterCreation.add(Duration(seconds: 1))),
            isTrue);
      });

      test('создает_контекст_с_токеном_отмены', () {
        // Arrange
        final cancellationToken = CancellationToken();

        // Act
        final sut = RpcContext.withCancellation(cancellationToken);

        // Assert
        expect(sut.cancellationToken, equals(cancellationToken));
        expect(sut.isCancelled, isFalse);
      });

      test('создает_контекст_с_trace_id', () {
        // Arrange
        const traceId = 'trace-id-12345';

        // Act
        final sut = RpcContext.withTraceId(traceId);

        // Assert
        expect(sut.traceId, equals(traceId));
      });
    });

    group('модификация контекста', () {
      late RpcContext baseSut;

      setUp(() {
        baseSut = RpcContext.withHeaders({'existing': 'header'})
            .withTraceId('base-trace');
      });

      test('добавляет_дополнительные_заголовки_сохраняя_существующие', () {
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
        expect(sut.traceId, equals('base-trace')); // Остальные поля сохранены
      });

      test('перезаписывает_существующие_заголовки_при_добавлении', () {
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

      test('устанавливает_новый_deadline', () {
        // Arrange
        final newDeadline = DateTime.now().add(Duration(hours: 2));

        // Act
        final sut = baseSut.withDeadline(newDeadline);

        // Assert
        expect(sut.deadline, equals(newDeadline));
        expect(sut.getHeader('existing'),
            equals('header')); // Остальные поля сохранены
        expect(sut.traceId, equals('base-trace'));
      });

      test('устанавливает_timeout_относительно_текущего_времени', () {
        // Arrange
        final timeout = Duration(minutes: 45);
        final beforeCreation = DateTime.now().add(timeout);

        // Act
        final sut = baseSut.withTimeout(timeout);

        // Assert
        final afterCreation = DateTime.now().add(timeout);
        expect(sut.deadline, isNotNull);
        expect(
            sut.deadline!
                .isAfter(beforeCreation.subtract(Duration(seconds: 1))),
            isTrue);
        expect(sut.deadline!.isBefore(afterCreation.add(Duration(seconds: 1))),
            isTrue);
      });

      test('устанавливает_токен_отмены', () {
        // Arrange
        final cancellationToken = CancellationToken();

        // Act
        final sut = baseSut.withCancellation(cancellationToken);

        // Assert
        expect(sut.cancellationToken, equals(cancellationToken));
        expect(sut.getHeader('existing'),
            equals('header')); // Остальные поля сохранены
      });

      test('устанавливает_новый_trace_id', () {
        // Arrange
        const newTraceId = 'new-trace-id-789';

        // Act
        final sut = baseSut.withTraceId(newTraceId);

        // Assert
        expect(sut.traceId, equals(newTraceId));
        expect(sut.getHeader('existing'),
            equals('header')); // Остальные поля сохранены
      });

      test('добавляет_значение_в_контекст', () {
        // Arrange
        const key = 'user-data';
        const value = 'important-value';

        // Act
        final sut = baseSut.withValue(key, value);

        // Assert
        expect(sut.getValue<String>(key), equals(value));
        expect(sut.getValue<int>('non-existent'), isNull);
        expect(sut.getHeader('existing'),
            equals('header')); // Остальные поля сохранены
      });
    });

    group('проверка_состояния', () {
      test('определяет_истекший_deadline', () {
        // Arrange
        final expiredDeadline = DateTime.now().subtract(Duration(minutes: 1));
        final sut = RpcContext.withDeadline(expiredDeadline);

        // Act & Assert
        expect(sut.isExpired, isTrue);
        expect(sut.remainingTime, equals(Duration.zero));
      });

      test('определяет_активный_deadline', () {
        // Arrange
        final futureDeadline = DateTime.now().add(Duration(hours: 1));
        final sut = RpcContext.withDeadline(futureDeadline);

        // Act & Assert
        expect(sut.isExpired, isFalse);
        expect(sut.remainingTime, isA<Duration>());
        expect(sut.remainingTime!.inMinutes, greaterThanOrEqualTo(59));
      });

      test('определяет_отмененный_контекст', () {
        // Arrange
        final cancellationToken = CancellationToken();
        final sut = RpcContext.withCancellation(cancellationToken);

        // Act
        cancellationToken.cancel('Пользователь отменил операцию');

        // Assert
        expect(sut.isCancelled, isTrue);
      });

      test('определяет_неотмененный_контекст', () {
        // Arrange
        final cancellationToken = CancellationToken();
        final sut = RpcContext.withCancellation(cancellationToken);

        // Act & Assert
        expect(sut.isCancelled, isFalse);
      });
    });

    group('доступ_к_данным', () {
      test('возвращает_неизменяемые_заголовки', () {
        // Arrange
        final originalHeaders = <String, String>{'key': 'value'};
        final sut = RpcContext.withHeaders(originalHeaders);

        // Act
        final headers = sut.headers;

        // Assert
        expect(() => headers['new'] = 'value', throwsUnsupportedError);
      });

      test('возвращает_неизменяемые_значения', () {
        // Arrange
        final sut = RpcContext.empty().withValue('key', 'value');

        // Act
        final values = sut.values;

        // Assert
        expect(() => values['new'] = 'value', throwsUnsupportedError);
      });

      test('корректно_типизирует_значения', () {
        // Arrange
        final sut = RpcContext.empty()
            .withValue('string-key', 'string-value')
            .withValue('int-key', 42)
            .withValue('list-key', [1, 2, 3]);

        // Act & Assert
        expect(sut.getValue<String>('string-key'), equals('string-value'));
        expect(sut.getValue<int>('int-key'), equals(42));
        expect(sut.getValue<List<int>>('list-key'), equals([1, 2, 3]));

        // Проверяем что неправильный тип выбрасывает исключение при касте
        expect(
            () => sut.getValue<String>('int-key'), throwsA(isA<TypeError>()));
      });
    });

    group('генерация_request_id', () {
      test('генерирует_уникальные_request_id', () async {
        // Arrange & Act
        final context1 = RpcContext.empty();
        // Добавляем небольшую задержку чтобы timestamp был разный
        await Future.delayed(Duration(milliseconds: 1));
        final context2 = RpcContext.empty();
        await Future.delayed(Duration(milliseconds: 1));
        final context3 = RpcContext.empty();

        // Assert
        expect(context1.requestId, isNotEmpty);
        expect(context2.requestId, isNotEmpty);
        expect(context3.requestId, isNotEmpty);
        expect(context1.requestId, isNot(equals(context2.requestId)));
        expect(context2.requestId, isNot(equals(context3.requestId)));
        expect(context1.requestId, isNot(equals(context3.requestId)));
      });

      test('сохраняет_request_id_при_модификации', () {
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
      test('отображает_базовую_информацию', () {
        // Arrange
        final sut = RpcContext.empty();

        // Act
        final result = sut.toString();

        // Assert
        expect(result, contains('RpcContext'));
        expect(result, contains('requestId: ${sut.requestId}'));
      });

      test('отображает_все_установленные_поля', () {
        // Arrange
        final cancellationToken = CancellationToken();
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

      test('отображает_статус_отмены', () {
        // Arrange
        final cancellationToken = CancellationToken();
        final sut = RpcContext.withCancellation(cancellationToken);

        // Act
        cancellationToken.cancel();
        final result = sut.toString();

        // Assert
        expect(result, contains('CANCELLED'));
      });

      test('отображает_статус_истечения', () {
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
    group('создание_токена', () {
      test('создает_активный_токен', () {
        // Arrange & Act
        final sut = CancellationToken();

        // Assert
        expect(sut.isCancelled, isFalse);
        expect(sut.reason, isNull);
      });

      test('создает_уже_отмененный_токен', () {
        // Arrange
        const reason = 'Предварительно отменен';

        // Act
        final sut = CancellationToken.cancelled(reason);

        // Assert
        expect(sut.isCancelled, isTrue);
        expect(sut.reason, equals(reason));
      });

      test('создает_отмененный_токен_без_причины', () {
        // Arrange & Act
        final sut = CancellationToken.cancelled();

        // Assert
        expect(sut.isCancelled, isTrue);
        expect(sut.reason, isNull);
      });
    });

    group('отмена_токена', () {
      test('отменяет_активный_токен', () {
        // Arrange
        final sut = CancellationToken();
        const reason = 'Пользователь отменил';

        // Act
        sut.cancel(reason);

        // Assert
        expect(sut.isCancelled, isTrue);
        expect(sut.reason, equals(reason));
      });

      test('отменяет_токен_без_причины', () {
        // Arrange
        final sut = CancellationToken();

        // Act
        sut.cancel();

        // Assert
        expect(sut.isCancelled, isTrue);
        expect(sut.reason, isNull);
      });

      test('игнорирует_повторную_отмену', () {
        // Arrange
        final sut = CancellationToken();
        sut.cancel('Первая причина');

        // Act
        sut.cancel('Вторая причина');

        // Assert
        expect(sut.isCancelled, isTrue);
        expect(
            sut.reason, equals('Первая причина')); // Сохраняется первая причина
      });

      test('уведомляет_о_отмене_через_future', () async {
        // Arrange
        final sut = CancellationToken();
        bool notified = false;

        // Act
        sut.cancelled.then((_) => notified = true);
        sut.cancel();

        // Даем время на выполнение callback
        await Future.delayed(Duration.zero);

        // Assert
        expect(notified, isTrue);
      });
    });

    group('проверка_отмены', () {
      test('не_выбрасывает_исключение_для_активного_токена', () {
        // Arrange
        final sut = CancellationToken();

        // Act & Assert
        expect(() => sut.throwIfCancelled(), returnsNormally);
      });

      test('выбрасывает_исключение_для_отмененного_токена', () {
        // Arrange
        final sut = CancellationToken();
        const reason = 'Токен отменен';
        sut.cancel(reason);

        // Act & Assert
        expect(
          () => sut.throwIfCancelled(),
          throwsA(isA<RpcCancelledException>()
              .having((e) => e.message, 'message', contains(reason))),
        );
      });

      test('выбрасывает_исключение_с_дефолтным_сообщением', () {
        // Arrange
        final sut = CancellationToken();
        sut.cancel(); // Без причины

        // Act & Assert
        expect(
          () => sut.throwIfCancelled(),
          throwsA(isA<RpcCancelledException>()
              .having((e) => e.message, 'message', 'Operation was cancelled')),
        );
      });
    });
  });

  group('RpcContextUtils', () {
    group('аутентификация', () {
      test('создает_контекст_с_basic_auth', () {
        // Arrange
        const username = 'testuser';
        const password = 'testpass';
        final expectedCredentials =
            base64Encode(utf8.encode('$username:$password'));

        // Act
        final sut = RpcContextUtils.withBasicAuth(username, password);

        // Assert
        expect(sut.getHeader('authorization'),
            equals('Basic $expectedCredentials'));
      });

      test('создает_контекст_с_bearer_token', () {
        // Arrange
        const token = 'abc123def456';

        // Act
        final sut = RpcContextUtils.withBearerToken(token);

        // Assert
        expect(sut.getHeader('authorization'), equals('Bearer $token'));
      });

      test('создает_контекст_с_api_key', () {
        // Arrange
        const key = 'api-key-12345';

        // Act
        final sut = RpcContextUtils.withApiKey(key);

        // Assert
        expect(sut.getHeader('x-api-key'), equals(key));
      });

      test('создает_контекст_с_кастомным_заголовком_api_key', () {
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

    group('трассировка', () {
      test('создает_контекст_с_полной_трассировкой', () {
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

      test('создает_контекст_только_с_trace_id', () {
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

      test('генерирует_trace_id_если_не_указан', () {
        // Arrange & Act
        final sut = RpcContextUtils.withTracing();

        // Assert
        expect(sut.traceId, isNotNull);
        expect(sut.traceId, isNotEmpty);
        expect(sut.traceId, startsWith('trace_'));
        // Когда traceId не передан, он генерируется но заголовок не устанавливается
        expect(sut.getHeader('x-trace-id'), isNull);
      });
    });

    group('объединение_контекстов', () {
      test('объединяет_заголовки_из_двух_контекстов', () {
        // Arrange
        final leftSut = RpcContext.withHeaders(
            {'left-header': 'left-value', 'common': 'left'});
        final rightSut = RpcContext.withHeaders(
            {'right-header': 'right-value', 'common': 'right'});

        // Act
        final merged = RpcContextUtils.merge(leftSut, rightSut);

        // Assert
        expect(merged.getHeader('left-header'), equals('left-value'));
        expect(merged.getHeader('right-header'), equals('right-value'));
        expect(merged.getHeader('common'),
            equals('right')); // Правый имеет приоритет
      });

      test('объединяет_значения_из_двух_контекстов', () {
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
        expect(merged.getValue<String>('common-key'),
            equals('right')); // Правый имеет приоритет
      });

      test('использует_правые_значения_для_специальных_полей', () {
        // Arrange
        final leftDeadline = DateTime.now().add(Duration(hours: 1));
        final rightDeadline = DateTime.now().add(Duration(hours: 2));
        final leftToken = CancellationToken();
        final rightToken = CancellationToken();

        final leftSut = RpcContext.withDeadline(leftDeadline)
            .withCancellation(leftToken)
            .withTraceId('left-trace');
        final rightSut = RpcContext.withDeadline(rightDeadline)
            .withCancellation(rightToken)
            .withTraceId('right-trace');

        // Act
        final merged = RpcContextUtils.merge(leftSut, rightSut);

        // Assert
        expect(merged.deadline, equals(rightDeadline));
        expect(merged.cancellationToken, equals(rightToken));
        expect(merged.traceId, equals('right-trace'));
        expect(merged.requestId, equals(rightSut.requestId));
      });

      test('использует_левые_значения_если_правые_null', () {
        // Arrange
        final deadline = DateTime.now().add(Duration(hours: 1));
        final token = CancellationToken();
        const traceId = 'left-trace';

        final leftSut = RpcContext.withDeadline(deadline)
            .withCancellation(token)
            .withTraceId(traceId);
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

  group('исключения', () {
    test('RpcCancelledException_содержит_корректное_сообщение', () {
      // Arrange
      const message = 'Операция была отменена пользователем';

      // Act
      final sut = RpcCancelledException(message);

      // Assert
      expect(sut.message, equals(message));
      expect(sut.toString(), equals('RpcCancelledException: $message'));
    });

    test('RpcDeadlineExceededException_содержит_deadline_и_timeout', () {
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
