import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('Server Stream', () {
    final serializer = RpcCodec(RpcString.fromJson);

    group('ServerStreamClient', () {
      test('отправляет_один_запрос_и_получает_множественные_ответы', () async {
        // Arrange
        print('Test setup started');
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
        final receivedRequests = <RpcString>[];

        final server = ServerStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) async* {
            print('Handler called with request: $request');
            receivedRequests.add(request);
            // Отправляем несколько ответов
            print('Yielding response 1');
            yield 'Response 1 for: $request'.rpc;
            await Future.delayed(Duration(milliseconds: 20));
            print('Yielding response 2');
            yield 'Response 2 for: $request'.rpc;
            await Future.delayed(Duration(milliseconds: 20));
            print('Yielding response 3');
            yield 'Response 3 for: $request'.rpc;
            print('Handler done');
          },
        );

        // ВАЖНО: Привязываем сервер к потоку сообщений для streamId = 1
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ServerStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        final receivedResponses = <RpcString>[];
        print('Setting up response listener');
        final subscription = client.responses.listen((message) {
          print('Got response message: $message');
          if (!message.isMetadataOnly && message.payload != null) {
            print('Adding payload to responses: ${message.payload}');
            receivedResponses.add(message.payload!);
          }
        }, onDone: () {
          print('Response stream done');
        }, onError: (e, st) {
          print('Response stream error: $e');
        });

        // Act
        print('Sending request');
        await client.send('test request'.rpc);
        print('Request sent');

        // Ждем завершения потока или таймаут
        print('Waiting for stream to complete');
        try {
          await subscription.asFuture().timeout(Duration(seconds: 5));
          print('Stream completed normally');
        } catch (e) {
          print('Stream timeout or error: $e');
          // Даже если был таймаут, продолжим проверки
        }

        // Проверяем результаты в любом случае
        print('Received ${receivedResponses.length} responses');
        for (int i = 0; i < receivedResponses.length; i++) {
          print('Response $i: ${receivedResponses[i]}');
        }

        // Assert
        expect(receivedResponses.length, equals(3));
        expect(
            receivedResponses[0], equals('Response 1 for: test request'.rpc));
        expect(
            receivedResponses[1], equals('Response 2 for: test request'.rpc));
        expect(
            receivedResponses[2], equals('Response 3 for: test request'.rpc));
        expect(receivedRequests.length, equals(1));
        expect(receivedRequests.first, equals('test request'.rpc));

        // Cleanup
        print('Cleaning up');
        await subscription.cancel();
        await client.close();
        await server.close();
        print('Test completed');
      });

      test('обрабатывает_единственный_запрос_без_ответов', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final server = ServerStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) {
            return Stream.empty();
          },
        );

        // ВАЖНО: Привязываем сервер к потоку сообщений для streamId = 1
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ServerStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        var streamCompleted = false;
        final completer = Completer<void>();
        final subscription = client.responses.listen(
          (message) {},
          onDone: () {
            streamCompleted = true;
            completer.complete();
          },
        );

        // Act
        await client.send('test request'.rpc);

        // Ждем завершения потока с таймаутом
        await completer.future.timeout(Duration(seconds: 5));

        // Assert
        expect(streamCompleted, isTrue);

        // Cleanup
        await subscription.cancel();
        await client.close();
        await server.close();
      });

      test('выбрасывает_исключение_при_ошибке_сервера', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final server = ServerStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) {
            // Выбрасываем синхронное исключение
            throw Exception('Server error');
          },
        );

        // ВАЖНО: Привязываем сервер к потоку сообщений для streamId = 1
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ServerStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // Act & Assert
        await client.send('test request'.rpc);

        final response =
            await client.responses.first.timeout(Duration(seconds: 5));

        // Проверяем что получили метаданные с ошибкой
        expect(response.isMetadataOnly, isTrue);
        expect(response.metadata, isNotNull);

        final grpcStatus = response.metadata!.getHeaderValue('grpc-status');
        expect(grpcStatus, isNotNull);
        expect(grpcStatus, isNot(equals('0')),
            reason: 'gRPC статус должен указывать на ошибку (не 0)');

        // Cleanup
        await client.close();
        await server.close();
      });

      test('завершает_поток_ответов_корректно', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final server = ServerStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) async* {
            yield 'response1'.rpc;
            yield 'response2'.rpc;
          },
        );

        // ВАЖНО: Привязываем сервер к потоку сообщений для streamId = 1
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ServerStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        var streamCompleted = false;
        final completer = Completer<void>();
        final subscription = client.responses.listen(
          (message) {},
          onDone: () {
            streamCompleted = true;
            completer.complete();
          },
        );

        // Act
        await client.send('test request'.rpc);

        // Ждем завершения потока с таймаутом
        await completer.future.timeout(Duration(seconds: 5));

        // Assert
        expect(streamCompleted, isTrue);

        // Cleanup
        await subscription.cancel();
        await client.close();
        await server.close();
      });

      test('закрывается_корректно', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final server = ServerStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) async* {
            // Пустой стрим
          },
        );

        // ВАЖНО: Привязываем сервер к потоку сообщений для streamId = 1
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ServerStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // Act & Assert - должно закрыться без ошибок
        await client.close();
        await server.close();
      });
    });

    group('ServerStreamServer', () {
      test('получает_один_запрос_и_отправляет_множественные_ответы', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
        final receivedRequests = <RpcString>[];

        final server = ServerStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) async* {
            receivedRequests.add(request);

            // Отправляем несколько ответов
            yield 'Response 1 for: $request'.rpc;
            yield 'Response 2 for: $request'.rpc;
            yield 'Response 3 for: $request'.rpc;
          },
        );

        // ВАЖНО: Привязываем сервер к потоку сообщений для streamId = 1
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ServerStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        final receivedResponses = <RpcString>[];
        final subscription = client.responses.listen((message) {
          if (!message.isMetadataOnly && message.payload != null) {
            receivedResponses.add(message.payload!);
          }
        });

        // Act
        await client.send('Hello Server'.rpc);
        await subscription.asFuture();

        // Assert
        expect(receivedRequests.length, equals(1));
        expect(receivedRequests.first, equals('Hello Server'.rpc));
        expect(receivedResponses.length, equals(3));
        expect(
            receivedResponses[0], equals('Response 1 for: Hello Server'.rpc));
        expect(
            receivedResponses[1], equals('Response 2 for: Hello Server'.rpc));
        expect(
            receivedResponses[2], equals('Response 3 for: Hello Server'.rpc));

        // Cleanup
        await client.close();
        await server.close();
      });

      test('обрабатывает_исключение_в_обработчике', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final server = ServerStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) {
            // Выбрасываем синхронное исключение
            throw Exception('Handler error');
          },
        );

        // ВАЖНО: Привязываем сервер к потоку сообщений для streamId = 1
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ServerStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // Act & Assert
        await client.send('test request'.rpc);

        final response =
            await client.responses.first.timeout(Duration(seconds: 5));

        // Проверяем что получили метаданные с ошибкой
        expect(response.isMetadataOnly, isTrue);
        expect(response.metadata, isNotNull);

        final grpcStatus = response.metadata!.getHeaderValue('grpc-status');
        expect(grpcStatus, isNotNull);
        expect(grpcStatus, isNot(equals('0')),
            reason: 'gRPC статус должен указывать на ошибку');

        // Cleanup
        await client.close();
        await server.close();
      });

      test('обрабатывает_только_запросы_своего_метода', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
        var handlerCallCount = 0;

        final server = ServerStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'SpecificMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) async* {
            handlerCallCount++;
          },
        );

        // ВАЖНО: Привязываем сервер к потоку сообщений для streamId = 1
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final correctClient = ServerStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'SpecificMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        final incorrectClient = ServerStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'DifferentMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // Act
        await correctClient.send('correct request'.rpc);
        try {
          await incorrectClient.send('incorrect request'.rpc);
        } catch (e) {
          // Может быть ошибка для неправильного метода
        }

        // Assert
        expect(handlerCallCount, equals(1));

        // Cleanup
        await correctClient.close();
        await incorrectClient.close();
        await server.close();
      });

      test('завершает_поток_с_ошибкой', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        // Создаем контроллер для управления стримом
        final controller = StreamController<RpcString>();

        final server = ServerStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) {
            // Асинхронно имитируем отправку одного ответа, а затем ошибку в стриме
            Future.microtask(() {
              controller.add('First response'.rpc);
              controller.addError(Exception('Test error message'));
              controller.close();
            });
            return controller.stream;
          },
        );

        // ВАЖНО: Привязываем сервер к потоку сообщений для streamId = 1
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ServerStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // Act & Assert
        await client.send('test request'.rpc);

        // Получаем все ответы (ожидаем первый ответ с данными, затем метаданные с ошибкой)
        final responses = await client.responses
            .take(2)
            .toList()
            .timeout(Duration(seconds: 5));

        // Должен быть хотя бы один ответ с данными и один с метаданными ошибки
        expect(responses.length, greaterThanOrEqualTo(1));

        // Ищем ответ с ошибкой (метаданные с gRPC статусом != "0")
        final errorResponse = responses.firstWhere(
          (r) =>
              r.isMetadataOnly &&
              r.metadata?.getHeaderValue('grpc-status') != null &&
              r.metadata!.getHeaderValue('grpc-status') != '0',
          orElse: () => throw AssertionError('Не найден ответ с gRPC ошибкой'),
        );

        expect(errorResponse.metadata!.getHeaderValue('grpc-status'),
            isNot(equals('0')),
            reason: 'gRPC статус должен указывать на ошибку');

        // Cleanup
        await client.close();
        await server.close();
      });

      test('закрывается_корректно', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final sut = ServerStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) async* {
            // Пустой стрим
          },
        );

        // ВАЖНО: Привязываем сервер к потоку сообщений для streamId = 1
        sut.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        // Act & Assert - должно закрыться без ошибок
        await sut.close();
        await clientTransport.close();
      });
    });

    group('интеграционные тесты', () {
      test('полный_цикл_серверного_стриминга', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final server = ServerStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'NumberService',
          methodName: 'GenerateNumbers',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) async* {
            final count = int.tryParse(request.value) ?? 3;
            for (int i = 1; i <= count; i++) {
              yield 'Number $i'.rpc;
            }
          },
        );

        // ВАЖНО: Привязываем сервер к потоку сообщений для streamId = 1
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ServerStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'NumberService',
          methodName: 'GenerateNumbers',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        final receivedNumbers = <RpcString>[];
        var streamCompleted = false;
        final completer = Completer<void>();

        final subscription = client.responses.listen(
          (message) {
            if (!message.isMetadataOnly && message.payload != null) {
              receivedNumbers.add(message.payload!);
            }
          },
          onDone: () {
            streamCompleted = true;
            completer.complete();
          },
        );

        // Act
        await client.send('5'.rpc);

        // Ждем завершения потока с таймаутом
        await completer.future.timeout(Duration(seconds: 5));

        // Assert
        expect(receivedNumbers.length, equals(5));
        expect(receivedNumbers[0], equals('Number 1'.rpc));
        expect(receivedNumbers[4], equals('Number 5'.rpc));
        expect(streamCompleted, isTrue);

        // Cleanup
        await subscription.cancel();
        await client.close();
        await server.close();
      });

      test('большое_количество_ответов', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final server = ServerStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'StreamService',
          methodName: 'LargeStream',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) async* {
            const responseCount = 50;
            for (int i = 0; i < responseCount; i++) {
              yield 'Response $i'.rpc;
            }
          },
        );

        // ВАЖНО: Привязываем сервер к потоку сообщений для streamId = 1
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ServerStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'StreamService',
          methodName: 'LargeStream',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        final receivedResponses = <RpcString>[];
        final subscription = client.responses.listen((message) {
          if (!message.isMetadataOnly && message.payload != null) {
            receivedResponses.add(message.payload!);
          }
        });

        // Act
        await client.send('start stream'.rpc);
        await subscription.asFuture();

        // Assert
        expect(receivedResponses.length, equals(50));
        expect(receivedResponses.first, equals('Response 0'.rpc));
        expect(receivedResponses.last, equals('Response 49'.rpc));

        // Cleanup
        await client.close();
        await server.close();
      });
    });
  });
}
