// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:test/test.dart';
import 'package:rpc_dart/rpc_dart.dart';

void main() {
  group('RpcContext Integration Tests', () {
    late RpcCallerEndpoint clientEndpoint;
    late RpcResponderEndpoint serverEndpoint;
    late IRpcTransport clientTransport;
    late IRpcTransport serverTransport;

    setUp(() {
      // Arrange - Создаем пару транспортов
      final (client, server) = RpcInMemoryTransport.pair();
      clientTransport = client;
      serverTransport = server;

      clientEndpoint = RpcCallerEndpoint(transport: clientTransport);
      serverEndpoint = RpcResponderEndpoint(transport: serverTransport);
    });

    tearDown(() async {
      await clientEndpoint.close();
      await serverEndpoint.close();
    });

    group('унарные запросы с контекстом', () {
      test('передает_заголовки_аутентификации_корректно', () async {
        // Arrange
        final testService = _TestServiceContract();
        serverEndpoint.registerServiceContract(testService);
        serverEndpoint.start();

        final context = RpcContextUtils.withBearerToken('test-token-123');

        // Act
        final response = await clientEndpoint
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'TestService',
              methodName: 'GetUserData',
              requestCodec: RpcString.codec,
              responseCodec: RpcString.codec,
              request: 'user-123'.rpc,
              context: context,
            );

        // Assert
        expect(response.value, contains('Bearer test-token-123'));
        expect(response.value, contains('user-123'));
      });

      test('передает_trace_id_для_распределенной_трассировки', () async {
        // Arrange
        final tracingService = _TracingServiceContract();
        serverEndpoint.registerServiceContract(tracingService);
        serverEndpoint.start();

        const traceId = 'integration-trace-12345';
        final context = RpcContextUtils.withTracing(
          traceId: traceId,
          spanId: 'span-001',
          parentSpanId: 'parent-span-001',
        );

        // Act
        final response = await clientEndpoint
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'TracingService',
              methodName: 'TracedOperation',
              requestCodec: RpcString.codec,
              responseCodec: RpcString.codec,
              request: 'trace-me'.rpc,
              context: context,
            );

        // Assert
        expect(response.value, contains(traceId));
        expect(response.value, contains('span-001'));
        expect(response.value, contains('parent-span-001'));
      });

      test('объединяет_контексты_с_разными_заголовками', () async {
        // Arrange
        final combinedService = _CombinedContextServiceContract();
        serverEndpoint.registerServiceContract(combinedService);
        serverEndpoint.start();

        final authContext = RpcContextUtils.withBearerToken('auth-token');
        final tracingContext = RpcContextUtils.withTracing(
          traceId: 'combined-trace',
        );
        final userContext = RpcContext.withHeaders({'user-id': 'user-456'});

        final combinedContext = RpcContextUtils.merge(
          RpcContextUtils.merge(authContext, tracingContext),
          userContext,
        );

        // Act
        final response = await clientEndpoint
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'CombinedContextService',
              methodName: 'ProcessWithFullContext',
              requestCodec: RpcString.codec,
              responseCodec: RpcString.codec,
              request: 'combined-request'.rpc,
              context: combinedContext,
            );

        // Assert
        expect(response.value, contains('Bearer auth-token'));
        expect(response.value, contains('combined-trace'));
        expect(response.value, contains('user-456'));
      });
    });

    group('серверные стримы с контекстом', () {
      test('передает_контекст_в_server_stream_handler', () async {
        // Arrange
        final streamService = _StreamServiceContract();
        serverEndpoint.registerServiceContract(streamService);
        serverEndpoint.start();

        final context = RpcContext.withHeaders({
          'streaming-mode': 'test',
          'user-id': 'stream-user-123',
          'stream-count': '3',
        });

        // Act
        final responses = <RpcString>[];
        await for (final response
            in clientEndpoint.serverStream<RpcString, RpcString>(
              serviceName: 'StreamService',
              methodName: 'GenerateStream',
              requestCodec: RpcString.codec,
              responseCodec: RpcString.codec,
              request: 'stream-request'.rpc,
              context: context,
            )) {
          responses.add(response);
        }

        // Assert
        expect(responses.length, equals(3));
        expect(
          responses.every((r) => r.value.contains('stream-user-123')),
          isTrue,
        );
        expect(responses.every((r) => r.value.contains('test')), isTrue);
      });

      test('работает_с_трейсингом_в_server_stream', () async {
        // Arrange
        final streamService = _StreamServiceContract();
        serverEndpoint.registerServiceContract(streamService);
        serverEndpoint.start();

        final context =
            RpcContextUtils.withTracing(
              traceId: 'server-stream-trace-456',
            ).withAdditionalHeaders({
              'streaming-mode': 'traced',
              'user-id': 'traced-user',
              'stream-count': '2',
            });

        // Act
        final responses = <RpcString>[];
        await for (final response
            in clientEndpoint.serverStream<RpcString, RpcString>(
              serviceName: 'StreamService',
              methodName: 'GenerateStream',
              requestCodec: RpcString.codec,
              responseCodec: RpcString.codec,
              request: 'traced-stream'.rpc,
              context: context,
            )) {
          responses.add(response);
        }

        // Assert
        expect(responses.length, equals(2));
        expect(responses.every((r) => r.value.contains('traced-user')), isTrue);
        expect(responses.every((r) => r.value.contains('traced')), isTrue);
      });
    });

    group('клиентские стримы с контекстом', () {
      test('передает_контекст_в_client_stream_handler', () async {
        // Arrange
        final aggregationService = _AggregationServiceContract();
        serverEndpoint.registerServiceContract(aggregationService);
        serverEndpoint.start();

        final context = RpcContext.withHeaders({
          'aggregation-type': 'sum',
          'user-id': 'aggregator-456',
          'processor-id': 'proc-123',
        });

        // Act
        final requestsController = StreamController<RpcString>();
        final responsesFuture = clientEndpoint
            .clientStream<RpcString, RpcString>(
              serviceName: 'AggregationService',
              methodName: 'AggregateData',
              requestCodec: RpcString.codec,
              responseCodec: RpcString.codec,
              context: context,
            )(requestsController.stream);

        // Отправляем данные
        final requests = ['data1', 'data2', 'data3'];
        for (final req in requests) {
          requestsController.add(req.rpc);
        }
        requestsController.close();

        final response = await responsesFuture;

        // Assert
        expect(response.value, contains('aggregator-456'));
        expect(response.value, contains('sum'));
        expect(response.value, contains('3 элементов'));
        expect(response.value, contains('proc-123'));
      });

      test('работает_с_аутентификацией_в_client_stream', () async {
        // Arrange
        final aggregationService = _AggregationServiceContract();
        serverEndpoint.registerServiceContract(aggregationService);
        serverEndpoint.start();

        final context = RpcContextUtils.withBearerToken('client-stream-token')
            .withAdditionalHeaders({
              'aggregation-type': 'authenticated',
              'user-id': 'auth-user-789',
            });

        // Act
        final requestsController = StreamController<RpcString>();
        final responsesFuture = clientEndpoint
            .clientStream<RpcString, RpcString>(
              serviceName: 'AggregationService',
              methodName: 'AggregateData',
              requestCodec: RpcString.codec,
              responseCodec: RpcString.codec,
              context: context,
            )(requestsController.stream);

        // Отправляем данные
        final requests = ['auth-data1', 'auth-data2'];
        for (final req in requests) {
          requestsController.add(req.rpc);
        }
        requestsController.close();

        final response = await responsesFuture;

        // Assert
        expect(response.value, contains('Bearer client-stream-token'));
        expect(response.value, contains('auth-user-789'));
        expect(response.value, contains('authenticated'));
        expect(response.value, contains('2 элементов'));
      });
    });

    group('двунаправленные стримы с контекстом', () {
      test('передает_контекст_в_bidirectional_stream_handler', () async {
        // Arrange
        final echoService = _EchoServiceContract();
        serverEndpoint.registerServiceContract(echoService);
        serverEndpoint.start();

        final context = RpcContext.withHeaders({
          'echo-prefix': 'TEST:',
          'session-id': 'echo-session-789',
          'echo-uppercase': 'true',
        });

        // Act
        final requestsController = StreamController<RpcString>();
        final responsesStream = clientEndpoint
            .bidirectionalStream<RpcString, RpcString>(
              serviceName: 'EchoService',
              methodName: 'EchoStream',
              requestCodec: RpcString.codec,
              responseCodec: RpcString.codec,
              requests: requestsController.stream,
              context: context,
            );

        final receivedResponses = <RpcString>[];
        final responseSubscription = responsesStream.listen((message) {
          receivedResponses.add(message);
        });

        // Отправляем сообщения
        requestsController.add('msg1'.rpc);
        requestsController.add('msg2'.rpc);

        // Ждем немного для обработки
        await Future.delayed(Duration(milliseconds: 1));

        // Закрываем поток запросов
        await requestsController.close();

        // Ждем завершения
        await Future.delayed(Duration(milliseconds: 1));
        await responseSubscription.cancel();

        // Assert
        expect(receivedResponses.length, greaterThanOrEqualTo(1));
        expect(
          receivedResponses[0].value,
          equals('TEST: ECHO-SESSION-789: MSG1'),
        );
        if (receivedResponses.length > 1) {
          expect(
            receivedResponses[1].value,
            equals('TEST: ECHO-SESSION-789: MSG2'),
          );
        }
      });

      test('работает_с_полным_контекстом_в_bidirectional_stream', () async {
        // Arrange
        final echoService = _EchoServiceContract();
        serverEndpoint.registerServiceContract(echoService);
        serverEndpoint.start();

        final context = RpcContextUtils.withBearerToken('bidi-token')
            .withTraceId('bidi-trace-123')
            .withAdditionalHeaders({
              'echo-prefix': 'SECURE:',
              'session-id': 'secure-session',
              'user-id': 'bidi-user',
            });

        // Act
        final requestsController = StreamController<RpcString>();
        final responsesStream = clientEndpoint
            .bidirectionalStream<RpcString, RpcString>(
              serviceName: 'EchoService',
              methodName: 'EchoStream',
              requestCodec: RpcString.codec,
              responseCodec: RpcString.codec,
              requests: requestsController.stream,
              context: context,
            );

        final receivedResponses = <RpcString>[];
        final responseSubscription = responsesStream.listen((message) {
          receivedResponses.add(message);
        });

        // Отправляем сообщения
        requestsController.add('secure-msg'.rpc);

        // Ждем обработки
        await Future.delayed(Duration(milliseconds: 1));

        // Закрываем поток
        await requestsController.close();
        await Future.delayed(Duration(milliseconds: 1));
        await responseSubscription.cancel();

        // Assert
        expect(receivedResponses.length, equals(1));
        expect(receivedResponses[0].value, contains('SECURE:'));
        expect(receivedResponses[0].value, contains('secure-session'));
        expect(receivedResponses[0].value, contains('secure-msg'));
      });
    });

    group('контрактная интеграция', () {
      test('работает_через_caller_contract_с_контекстом', () async {
        // Arrange
        final testService = _TestServiceContract();
        serverEndpoint.registerServiceContract(testService);
        serverEndpoint.start();

        final callerContract = _TestServiceCallerContract(clientEndpoint);
        final context = RpcContextUtils.withBearerToken('contract-token');

        // Act
        final response = await callerContract.getUserData(
          'contract-user'.rpc,
          context,
        );

        // Assert
        expect(response.value, contains('Bearer contract-token'));
        expect(response.value, contains('contract-user'));
      });

      test('stream_contract_с_контекстом', () async {
        // Arrange
        final streamService = _StreamServiceContract();
        serverEndpoint.registerServiceContract(streamService);
        serverEndpoint.start();

        final callerContract = _StreamServiceCallerContract(clientEndpoint);
        final context = RpcContext.withHeaders({
          'streaming-mode': 'contract',
          'user-id': 'contract-stream-user',
          'stream-count': '2',
        });

        // Act
        final responses = await callerContract.generateStream(
          'contract-stream'.rpc,
          context,
        );

        // Assert
        expect(responses.length, equals(2));
        expect(
          responses.every((r) => r.value.contains('contract-stream-user')),
          isTrue,
        );
        expect(responses.every((r) => r.value.contains('contract')), isTrue);
      });
    });

    group('обработка ошибок с контекстом', () {
      test('включает_trace_id_в_сообщения_об_ошибках', () async {
        // Arrange
        final errorService = _ErrorServiceContract();
        serverEndpoint.registerServiceContract(errorService);
        serverEndpoint.start();

        const traceId = 'error-trace-999';
        final context = RpcContext.withTraceId(traceId);

        // Act & Assert
        try {
          await clientEndpoint.unaryRequest<RpcString, RpcString>(
            serviceName: 'ErrorService',
            methodName: 'ThrowError',
            requestCodec: RpcString.codec,
            responseCodec: RpcString.codec,
            request: 'error-request'.rpc,
            context: context,
          );
          fail('Ожидалось исключение');
        } catch (e) {
          expect(e.toString(), contains(traceId));
        }
      });
    });
  });
}

/// Тестовый сервис для проверки передачи аутентификации
final class _TestServiceContract extends RpcResponderContract {
  _TestServiceContract() : super('TestService');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'GetUserData',
      handler: _getUserData,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }

  Future<RpcString> _getUserData(
    RpcString userId, {
    RpcContext? context,
  }) async {
    final authHeader = context?.getHeader('authorization');
    return 'User data for ${userId.value} (auth: $authHeader)'.rpc;
  }
}

/// Тестовый сервис для проверки трассировки
final class _TracingServiceContract extends RpcResponderContract {
  _TracingServiceContract() : super('TracingService');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'TracedOperation',
      handler: _tracedOperation,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }

  Future<RpcString> _tracedOperation(
    RpcString request, {
    RpcContext? context,
  }) async {
    final traceId = context?.traceId;
    final spanId = context?.getHeader('x-span-id');
    final parentSpanId = context?.getHeader('x-parent-span-id');

    return 'Traced ${request.value} [trace=$traceId, span=$spanId, parent=$parentSpanId]'
        .rpc;
  }
}

/// Тестовый сервис для проверки объединения контекстов
final class _CombinedContextServiceContract extends RpcResponderContract {
  _CombinedContextServiceContract() : super('CombinedContextService');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'ProcessWithFullContext',
      handler: _processWithFullContext,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }

  Future<RpcString> _processWithFullContext(
    RpcString request, {
    RpcContext? context,
  }) async {
    final auth = context?.getHeader('authorization');
    final traceId = context?.traceId;
    final userId = context?.getHeader('user-id');

    return 'Processed ${request.value} [auth=$auth, trace=$traceId, user=$userId]'
        .rpc;
  }
}

/// Тестовый сервис для серверных стримов
final class _StreamServiceContract extends RpcResponderContract {
  _StreamServiceContract() : super('StreamService');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'GenerateStream',
      handler: _generateStream,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }

  Stream<RpcString> _generateStream(
    RpcString request, {
    RpcContext? context,
  }) async* {
    final mode = context?.getHeader('streaming-mode');
    final userId = context?.getHeader('user-id');
    final countHeader = context?.getHeader('stream-count');
    final count = int.tryParse(countHeader ?? '3') ?? 3;

    for (int i = 1; i <= count; i++) {
      yield 'Stream item $i [mode=$mode, user=$userId]'.rpc;
    }
  }
}

/// Тестовый сервис для клиентских стримов
final class _AggregationServiceContract extends RpcResponderContract {
  _AggregationServiceContract() : super('AggregationService');

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'AggregateData',
      handler: _aggregateData,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }

  Future<RpcString> _aggregateData(
    Stream<RpcString> requests, {
    RpcContext? context,
  }) async {
    final aggregationType = context?.getHeader('aggregation-type');
    final userId = context?.getHeader('user-id');
    final auth = context?.getHeader('authorization');
    final processorId = context?.getHeader('processor-id');

    final allRequests = await requests.toList();
    return 'Aggregated ${allRequests.length} элементов [type=$aggregationType, user=$userId, auth=$auth, processor=$processorId]'
        .rpc;
  }
}

/// Тестовый сервис для двунаправленных стримов
final class _EchoServiceContract extends RpcResponderContract {
  _EchoServiceContract() : super('EchoService');

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'EchoStream',
      handler: _echoStream,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }

  Stream<RpcString> _echoStream(
    Stream<RpcString> requests, {
    RpcContext? context,
  }) async* {
    final prefix = context?.getHeader('echo-prefix');
    final sessionId = context?.getHeader('session-id');
    final uppercaseHeader = context?.getHeader('echo-uppercase');
    final uppercase = uppercaseHeader?.toLowerCase() == 'true';

    await for (final request in requests) {
      final message = '$prefix $sessionId: ${request.value}';
      yield (uppercase ? message.toUpperCase() : message).rpc;
    }
  }
}

/// Тестовый сервис для проверки обработки ошибок
final class _ErrorServiceContract extends RpcResponderContract {
  _ErrorServiceContract() : super('ErrorService');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'ThrowError',
      handler: _throwError,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }

  Future<RpcString> _throwError(
    RpcString request, {
    RpcContext? context,
  }) async {
    final traceId = context?.traceId;
    throw Exception('Service error for ${request.value} [trace=$traceId]');
  }
}

/// Клиентский контракт для тестового сервиса
final class _TestServiceCallerContract extends RpcCallerContract {
  _TestServiceCallerContract(RpcCallerEndpoint endpoint)
    : super('TestService', endpoint);

  Future<RpcString> getUserData(RpcString userId, RpcContext? context) {
    return callUnary<RpcString, RpcString>(
      methodName: 'GetUserData',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: userId,
      context: context,
    );
  }
}

/// Клиентский контракт для стримового сервиса
final class _StreamServiceCallerContract extends RpcCallerContract {
  _StreamServiceCallerContract(RpcCallerEndpoint endpoint)
    : super('StreamService', endpoint);

  Future<List<RpcString>> generateStream(
    RpcString request,
    RpcContext? context,
  ) async {
    final responses = <RpcString>[];
    await for (final response in callServerStream<RpcString, RpcString>(
      methodName: 'GenerateStream',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: request,
      context: context,
    )) {
      responses.add(response);
    }
    return responses;
  }
}
