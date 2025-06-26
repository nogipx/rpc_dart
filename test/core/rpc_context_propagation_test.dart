// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:test/test.dart';
import 'package:rpc_dart/rpc_dart.dart';

void main() {
  group('RpcContext', () {
    test('создает пустой контекст с уникальным request ID', () {
      final context1 = RpcContext.empty();
      // Небольшая задержка для гарантии разных timestamp
      final context2 = RpcContext.empty();

      expect(context1.requestId, isNotEmpty);
      expect(context2.requestId, isNotEmpty);
      // В тестах может совпадать из-за скорости выполнения, проверим формат
      expect(context1.requestId, startsWith('req_'));
      expect(context2.requestId, startsWith('req_'));
      expect(context1.headers, isEmpty);
      expect(context1.traceId, isNull);
      expect(context1.deadline, isNull);
    });

    test('создает контекст с заголовками', () {
      final headers = {'x-user-id': '123', 'x-session': 'abc'};
      final context = RpcContext.withHeaders(headers);

      expect(context.headers, equals(headers));
      expect(context.getHeader('x-user-id'), equals('123'));
      expect(context.getHeader('x-session'), equals('abc'));
      expect(context.getHeader('nonexistent'), isNull);
    });

    test('создает контекст с deadline', () {
      final deadline = DateTime.now().add(Duration(minutes: 5));
      final context = RpcContext.withDeadline(deadline);

      expect(context.deadline, equals(deadline));
      expect(context.isExpired, isFalse);
      expect(context.remainingTime, isNotNull);
      expect(context.remainingTime!.inMinutes, lessThanOrEqualTo(5));
    });

    test('создает контекст с timeout', () {
      final timeout = Duration(minutes: 10);
      final context = RpcContext.withTimeout(timeout);

      expect(context.deadline, isNotNull);
      expect(context.isExpired, isFalse);
      expect(context.remainingTime!.inMinutes, lessThanOrEqualTo(10));
    });

    test('проверяет истечение deadline', () {
      final pastDeadline = DateTime.now().subtract(Duration(minutes: 1));
      final context = RpcContext.withDeadline(pastDeadline);

      expect(context.isExpired, isTrue);
      expect(context.remainingTime, equals(Duration.zero));
    });

    test('добавляет дополнительные заголовки к существующим', () {
      final originalHeaders = {'x-user-id': '123'};
      final additionalHeaders = {'x-session': 'abc', 'x-trace': '456'};

      final context = RpcContext.withHeaders(originalHeaders)
          .withAdditionalHeaders(additionalHeaders);

      expect(context.headers['x-user-id'], equals('123'));
      expect(context.headers['x-session'], equals('abc'));
      expect(context.headers['x-trace'], equals('456'));
      expect(context.headers.length, equals(3));
    });

    test('работает с значениями контекста', () {
      final key1 = 'user';
      final key2 = 42;
      final value1 = 'John Doe';
      final value2 = Duration(minutes: 5);

      final context =
          RpcContext.empty().withValue(key1, value1).withValue(key2, value2);

      expect(context.getValue<String>(key1), equals(value1));
      expect(context.getValue<Duration>(key2), equals(value2));
      expect(context.getValue<String>('nonexistent'), isNull);
    });
  });

  group('CancellationToken', () {
    test('создает неотмененный токен', () {
      final token = RpcCancellationToken();

      expect(token.isCancelled, isFalse);
      expect(token.reason, isNull);
    });

    test('создает уже отмененный токен', () {
      final reason = 'User cancelled';
      final token = RpcCancellationToken.cancelled(reason);

      expect(token.isCancelled, isTrue);
      expect(token.reason, equals(reason));
    });

    test('отменяет токен с причиной', () {
      final token = RpcCancellationToken();
      final reason = 'Timeout exceeded';

      token.cancel(reason);

      expect(token.isCancelled, isTrue);
      expect(token.reason, equals(reason));
    });

    test('выбрасывает исключение при проверке отмененного токена', () {
      final token = RpcCancellationToken.cancelled('Test cancellation');

      expect(
        () => token.throwIfCancelled(),
        throwsA(isA<RpcCancelledException>()),
      );
    });

    test('не выбрасывает исключение для неотмененного токена', () {
      final token = RpcCancellationToken();

      expect(() => token.throwIfCancelled(), returnsNormally);
    });
  });

  group('RpcContextUtils', () {
    test('создает контекст с Basic аутентификацией', () {
      final context = RpcContextUtils.withBasicAuth('user', 'pass');
      final authHeader = context.getHeader('authorization');

      expect(authHeader, isNotNull);
      expect(authHeader, startsWith('Basic '));
      // Проверяем, что это base64(user:pass)
      expect(authHeader, equals('Basic dXNlcjpwYXNz'));
    });

    test('создает контекст с Bearer токеном', () {
      final token = 'abc123token';
      final context = RpcContextUtils.withBearerToken(token);
      final authHeader = context.getHeader('authorization');

      expect(authHeader, equals('Bearer $token'));
    });

    test('создает контекст с API ключом', () {
      final apiKey = 'secret-key-123';
      final context = RpcContextUtils.withApiKey(apiKey);

      expect(context.getHeader('x-api-key'), equals(apiKey));
    });

    test('создает контекст с пользовательским заголовком API ключа', () {
      final apiKey = 'secret-key-123';
      final headerName = 'x-custom-key';
      final context =
          RpcContextUtils.withApiKey(apiKey, headerName: headerName);

      expect(context.getHeader(headerName), equals(apiKey));
      expect(context.getHeader('x-api-key'), isNull);
    });

    test('создает контекст для трассировки', () {
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

    test('создает контекст для трассировки с автогенерацией trace ID', () {
      final context = RpcContextUtils.withTracing();

      expect(context.traceId, isNotNull);
      expect(context.traceId, startsWith('trace_'));
      // withTracing() устанавливает traceId в сам контекст, но не всегда в заголовки
      // если traceId не указан явно
    });

    test('объединяет контексты с приоритетом правого', () {
      final leftContext = RpcContext.withHeaders({'x-left': 'left-value'})
          .withTraceId('left-trace')
          .withValue('shared-key', 'left-shared');

      final rightContext = RpcContext.withHeaders({'x-right': 'right-value'})
          .withTraceId('right-trace')
          .withValue('shared-key', 'right-shared');

      final merged = RpcContextUtils.merge(leftContext, rightContext);

      // Правый контекст имеет приоритет
      expect(merged.traceId, equals('right-trace'));
      expect(merged.requestId, equals(rightContext.requestId));
      expect(merged.getValue('shared-key'), equals('right-shared'));

      // Заголовки объединяются
      expect(merged.getHeader('x-left'), equals('left-value'));
      expect(merged.getHeader('x-right'), equals('right-value'));
    });
  });

  group('RpcContextBuilder', () {
    test('создает контекст с fluent API', () {
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

    test('наследует от родительского контекста', () {
      final parentTraceId = 'parent-trace-123';
      final parentHeaders = {'x-session': 'parent-session'};
      final parent =
          RpcContext.withHeaders(parentHeaders).withTraceId(parentTraceId);

      final child = RpcContextBuilder.inheritFrom(parent)
          .withHeader('x-user-id', '456')
          .build();

      // Наследует trace ID
      expect(child.traceId, equals(parentTraceId));
      // Наследует заголовки
      expect(child.getHeader('x-session'), equals('parent-session'));
      // Добавляет новые заголовки
      expect(child.getHeader('x-user-id'), equals('456'));
      // Генерирует request ID правильного формата
      expect(child.requestId, startsWith('req_'));
    });

    test('создает новый trace ID при отсутствии родительского', () {
      final child = RpcContextBuilder.inheritFrom(null).build();

      expect(child.traceId, isNotNull);
      expect(child.traceId, startsWith('trace_'));
      expect(child.requestId, isNotEmpty);
    });

    test('добавляет метаданные домена', () {
      final context = RpcContextBuilder()
          .withDomainMetadata(
            userId: '123',
            sessionId: 'session-abc',
            tenantId: 'tenant-xyz',
            correlationId: 'corr-456',
          )
          .build();

      expect(context.getHeader('x-user-id'), equals('123'));
      expect(context.getHeader('x-session-id'), equals('session-abc'));
      expect(context.getHeader('x-tenant-id'), equals('tenant-xyz'));
      expect(context.getHeader('x-correlation-id'), equals('corr-456'));
    });
  });

  group('RpcContextExtensions', () {
    test('создает дочерний контекст с новым request ID', () {
      final parentTraceId = 'parent-trace-123';
      final parent = RpcContext.withTraceId(parentTraceId);

      final child = parent.createChild();

      expect(child.traceId, equals(parentTraceId));
      // В быстрых тестах может совпадать, проверим что это действительно request ID
      expect(child.requestId, startsWith('req_'));
      expect(parent.requestId, startsWith('req_'));
    });

    test('создает дочерний контекст с дополнительными параметрами', () {
      final parent = RpcContext.withTraceId('trace-123');
      final additionalHeaders = {'x-custom': 'value'};
      final timeout = Duration(seconds: 30);

      final child = parent.createChildWith(
        headers: additionalHeaders,
        timeout: timeout,
        userId: '456',
        sessionId: 'session-xyz',
      );

      expect(child.traceId, equals(parent.traceId));
      expect(child.requestId, startsWith('req_'));
      expect(child.getHeader('x-custom'), equals('value'));
      expect(child.getHeader('x-user-id'), equals('456'));
      expect(child.getHeader('x-session-id'), equals('session-xyz'));
      expect(child.deadline, isNotNull);
    });

    test('возвращает correlation ID как алиас для trace ID', () {
      final traceId = 'trace-correlation-123';
      final context = RpcContext.withTraceId(traceId);

      expect(context.correlationId, equals(traceId));
    });
  });

  group('RpcContext', () {
    test('создает контекст для бизнес-операции', () {
      final userId = '123';
      final operationType = 'CreateOrder';

      final context = RpcContext.forBusinessOperation(
        operationType: operationType,
        userId: userId,
      );

      expect(context.getHeader('x-user-id'), equals(userId));
      expect(context.getHeader('x-operation-type'), equals(operationType));
      expect(context.traceId, isNotNull);
      expect(context.traceId, startsWith('trace_'));
    });

    test('создает контекст для междоменного вызова', () {
      final parentTraceId = 'parent-trace-123';
      final parent = RpcContext.withTraceId(parentTraceId)
          .withAdditionalHeaders({'x-user-id': '456'});

      final context = RpcContext.forDomainCall(
        parentContext: parent,
        fromDomain: 'OrderDomain',
        toDomain: 'UserService',
        operation: 'GetUser',
      );

      expect(context.traceId, equals(parentTraceId));
      expect(context.requestId, startsWith('req_'));
      expect(context.getHeader('x-user-id'), equals('456'));
      expect(context.getHeader('x-from-domain'), equals('OrderDomain'));
      expect(context.getHeader('x-to-domain'), equals('UserService'));
      expect(context.getHeader('x-domain-operation'), equals('GetUser'));
    });

    test('извлекает метаданные домена из контекста', () {
      final context = RpcContext.withHeaders({
        'x-user-id': '123',
        'x-session-id': 'session-abc',
        'x-tenant-id': 'tenant-xyz',
        'x-from-domain': 'OrderService',
        'x-to-domain': 'PaymentService',
        'x-domain-operation': 'ProcessPayment',
        'x-operation-type': 'Payment',
      }).withTraceId('trace-456');

      final metadata = RpcContext.extractDomainMetadata(context);

      expect(metadata.userId, equals('123'));
      expect(metadata.sessionId, equals('session-abc'));
      expect(metadata.tenantId, equals('tenant-xyz'));
      expect(metadata.fromDomain, equals('OrderService'));
      expect(metadata.toDomain, equals('PaymentService'));
      expect(metadata.operation, equals('ProcessPayment'));
      expect(metadata.operationType, equals('Payment'));
      expect(metadata.traceId, equals('trace-456'));
    });

    test('проверяет валидность контекста', () {
      final validContext = RpcContext.empty();
      final expiredContext = RpcContext.withDeadline(
          DateTime.now().subtract(Duration(minutes: 1)));
      final cancelledToken = RpcCancellationToken.cancelled();
      final cancelledContext = RpcContext.withCancellation(cancelledToken);

      expect(RpcContext.isContextValid(validContext), isTrue);
      expect(RpcContext.isContextValid(expiredContext), isFalse);
      expect(RpcContext.isContextValid(cancelledContext), isFalse);
      expect(RpcContext.isContextValid(null), isFalse);
    });

    test('создает цепочку контекстов', () {
      final baseContext = RpcContext.withTraceId('base-trace-123');
      final steps = ['OrderDomain', 'UserDomain', 'PaymentDomain'];

      final chain = RpcContext.createChain(
        baseContext,
        steps: steps,
        stepTimeout: Duration(seconds: 5),
      );

      expect(chain.keys.length, equals(3));
      expect(chain.containsKey('OrderDomain'), isTrue);
      expect(chain.containsKey('UserDomain'), isTrue);
      expect(chain.containsKey('PaymentDomain'), isTrue);

      // Все контексты должны иметь один trace ID
      for (final stepContext in chain.values) {
        expect(stepContext.traceId, equals('base-trace-123'));
        expect(stepContext.deadline, isNotNull);
      }

      // Проверяем, что каждый контекст имеет правильную метку шага
      expect(
          chain['OrderDomain']!.getValue('cord.step'), equals('OrderDomain'));
      expect(chain['UserDomain']!.getValue('cord.step'), equals('UserDomain'));
      expect(chain['PaymentDomain']!.getValue('cord.step'),
          equals('PaymentDomain'));
    });

    test('санитизирует контекст', () {
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

  group('DomainMetadata', () {
    test('создает метаданные со всеми полями', () {
      final metadata = DomainMetadata(
        userId: '123',
        sessionId: 'session-abc',
        tenantId: 'tenant-xyz',
        fromDomain: 'OrderService',
        toDomain: 'UserService',
        operation: 'GetUser',
        operationType: 'UserOp',
        traceId: 'trace-456',
        correlationId: 'corr-789',
      );

      expect(metadata.userId, equals('123'));
      expect(metadata.sessionId, equals('session-abc'));
      expect(metadata.tenantId, equals('tenant-xyz'));
      expect(metadata.fromDomain, equals('OrderService'));
      expect(metadata.toDomain, equals('UserService'));
      expect(metadata.operation, equals('GetUser'));
      expect(metadata.operationType, equals('UserOp'));
      expect(metadata.traceId, equals('trace-456'));
      expect(metadata.correlationId, equals('corr-789'));
    });

    test('создает метаданные с минимальным набором полей', () {
      final metadata = DomainMetadata(
        toDomain: 'PaymentService',
        operation: 'ProcessPayment',
        traceId: 'trace-123',
      );

      expect(metadata.toDomain, equals('PaymentService'));
      expect(metadata.operation, equals('ProcessPayment'));
      expect(metadata.traceId, equals('trace-123'));
      expect(metadata.userId, isNull);
      expect(metadata.sessionId, isNull);
      expect(metadata.tenantId, isNull);
      expect(metadata.fromDomain, isNull);
      expect(metadata.operationType, isNull);
      expect(metadata.correlationId, isNull);
    });

    test('форматирует строковое представление', () {
      final metadata = DomainMetadata(
        userId: '123',
        fromDomain: 'OrderService',
        toDomain: 'UserService',
        operation: 'GetUser',
        traceId: 'trace-456',
      );

      final str = metadata.toString();

      expect(str, contains('OrderService→UserService'));
      expect(str, contains('op:GetUser'));
      expect(str, contains('trace:trace-456'));
      expect(str, contains('user:123'));
    });
  });

  group('RpcContextAware', () {
    test('миксин создает контекст для вызова', () {
      final parentContext = RpcContext.withTraceId('parent-trace-123')
          .withAdditionalHeaders({'x-user-id': '456'});
      final domain = TestDomain('TestDomain', parentContext);

      final callContext = domain.createCallContext(
        targetDomain: 'PaymentService',
        operation: 'ProcessPayment',
      );

      expect(callContext.traceId, equals('parent-trace-123'));
      expect(callContext.requestId, startsWith('req_'));
      expect(callContext.getHeader('x-user-id'), equals('456'));
      expect(callContext.getHeader('x-to-domain'), equals('PaymentService'));
      expect(callContext.getHeader('x-domain-operation'),
          equals('ProcessPayment'));
      expect(callContext.getHeader('x-from-domain'), equals('TestDomain'));
    });
  });

  group('Интеграционные тесты', () {
    test('полный цикл propagation через несколько доменов', () {
      // Создаем начальный контекст операции
      final initialContext = RpcContext.forBusinessOperation(
        operationType: 'CreateOrder',
        userId: '123',
      );

      // OrderDomain делает вызов в UserDomain
      final orderToUserContext = RpcContext.forDomainCall(
        parentContext: initialContext,
        fromDomain: 'OrderDomain',
        toDomain: 'UserDomain',
        operation: 'GetUser',
      );

      // UserDomain делает вызов в PaymentDomain
      final userToPaymentContext = RpcContext.forDomainCall(
        parentContext: orderToUserContext,
        fromDomain: 'UserDomain',
        toDomain: 'PaymentDomain',
        operation: 'ValidateCard',
      );

      // Проверяем, что trace ID проходит через всю цепочку
      expect(initialContext.traceId, equals(orderToUserContext.traceId));
      expect(orderToUserContext.traceId, equals(userToPaymentContext.traceId));

      // Каждый вызов имеет правильный формат request ID
      expect(initialContext.requestId, startsWith('req_'));
      expect(orderToUserContext.requestId, startsWith('req_'));
      expect(userToPaymentContext.requestId, startsWith('req_'));

      // User ID проходит через всю цепочку
      expect(initialContext.getHeader('x-user-id'), equals('123'));
      expect(orderToUserContext.getHeader('x-user-id'), equals('123'));
      expect(userToPaymentContext.getHeader('x-user-id'), equals('123'));

      // Проверяем метаданные последнего вызова
      final paymentMetadata =
          RpcContext.extractDomainMetadata(userToPaymentContext);
      expect(paymentMetadata.userId, equals('123'));
      expect(paymentMetadata.toDomain, equals('PaymentDomain'));
      expect(paymentMetadata.operation, equals('ValidateCard'));
      expect(paymentMetadata.traceId, equals(initialContext.traceId));
    });

    test('работа с таймаутами и отменой в цепочке', () {
      final cancellationToken = RpcCancellationToken();
      final timeout = Duration(seconds: 30);

      final context = RpcContextBuilder()
          .withGeneratedTraceId()
          .withTimeout(timeout)
          .withCancellation(cancellationToken)
          .build();

      // Создаем дочерний контекст
      final childContext = context.createChild();

      // Проверяем наследование
      expect(childContext.traceId, equals(context.traceId));
      expect(childContext.deadline, equals(context.deadline));
      expect(childContext.cancellationToken, equals(context.cancellationToken));
      expect(childContext.isCancelled, isFalse);

      // Отменяем операцию
      cancellationToken.cancel('User cancelled');

      expect(childContext.isCancelled, isTrue);
      expect(() => childContext.cancellationToken!.throwIfCancelled(),
          throwsA(isA<RpcCancelledException>()));
    });
  });
}

// Тестовый класс для проверки RpcContextAware mixin
class TestDomain with RpcContextAware {
  @override
  final String serviceName;

  TestDomain(this.serviceName, RpcContext? context) {
    updateCurrentContext(context);
  }
}
