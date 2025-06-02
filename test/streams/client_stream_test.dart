import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('Client Stream', () {
    final codec = RpcCodec(RpcString.fromJson);
    group('ClientStreamClient', () {
      test('отправляет_несколько_запросов_и_получает_один_ответ', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final server = ClientStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: codec,
          responseCodec: codec,
          handler: (requests) async {
            print('⭐ Сервер: Начата обработка запросов');
            final allRequests = await requests.toList();
            print(
                '⭐ Сервер: Получено ${allRequests.length} запросов: $allRequests');
            final joinedRequests = allRequests.join(', ');
            print('⭐ Сервер: Отправляю ответ "Received: $joinedRequests"');
            return 'Received: $joinedRequests'.rpc;
          },
        );

        // ВАЖНО: Привязываем сервер к потоку сообщений для streamId = 1
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ClientStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: codec,
          responseCodec: codec,
        );

        // Act
        print('⭐ Клиент: Отправляю первый запрос');
        await client.send('request1'.rpc);
        await Future.delayed(Duration(milliseconds: 10));

        print('⭐ Клиент: Отправляю второй запрос');
        await client.send('request2'.rpc);
        await Future.delayed(Duration(milliseconds: 10));

        print('⭐ Клиент: Отправляю третий запрос');
        await client.send('request3'.rpc);
        await Future.delayed(Duration(milliseconds: 10));

        print('⭐ Клиент: Завершаю отправку и жду ответ');
        final response = await client.finishSending();
        print('⭐ Клиент: Получен ответ: $response');

        // Assert
        expect(
            response.value, equals('Received: request1, request2, request3'));

        // Cleanup
        await client.close();
        await server.close();
      });

      test('обрабатывает_пустой_поток_запросов', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final server = ClientStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: codec,
          responseCodec: codec,
          handler: (Stream<RpcString> requests) async {
            var count = 0;
            await for (final _ in requests) {
              count++;
            }
            return 'Processed $count requests'.rpc;
          },
        );

        // ВАЖНО: Привязываем сервер к потоку сообщений для streamId = 1
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ClientStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: codec,
          responseCodec: codec,
        );

        // Act
        final response = await client.finishSending();

        // Assert
        expect(response, equals('Processed 0 requests'.rpc));

        // Cleanup
        await client.close();
        await server.close();
      });

      test('выбрасывает_исключение_при_ошибке_сервера', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final server = ClientStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: codec,
          responseCodec: codec,
          handler: (Stream<RpcString> requests) async {
            // Сразу выбрасываем исключение без обработки stream
            throw Exception('Server processing error');
          },
        );

        // ВАЖНО: Привязываем сервер к потоку сообщений для streamId = 1
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ClientStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: codec,
          responseCodec: codec,
        );

        // Act & Assert
        await client.send('test request'.rpc);

        // Используем expectLater с коротким таймаутом
        await expectLater(
          client.finishSending().timeout(Duration(seconds: 5)),
          throwsA(isA<Exception>()),
        );

        // Cleanup
        await client.close();
        await server.close();
      });

      test('отправляет_запросы_в_правильном_порядке', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
        final receivedRequests = <RpcString>[];

        final server = ClientStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: codec,
          responseCodec: codec,
          handler: (Stream<RpcString> requests) async {
            await for (final request in requests) {
              receivedRequests.add(request);
            }
            return 'Ordered: ${receivedRequests.join(", ")}'.rpc;
          },
        );

        // ВАЖНО: Привязываем сервер к потоку сообщений для streamId = 1
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ClientStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: codec,
          responseCodec: codec,
        );

        final orderedRequests = ['first'.rpc, 'second'.rpc, 'third'.rpc];

        // Act
        for (final request in orderedRequests) {
          await client.send(request);
        }
        final response = await client.finishSending();

        // Assert
        expect(response, equals('Ordered: first, second, third'.rpc));
        expect(receivedRequests, equals(orderedRequests));

        // Cleanup
        await client.close();
        await server.close();
      });

      test('закрывается_корректно', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final server = ClientStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: codec,
          responseCodec: codec,
          handler: (Stream<RpcString> requests) async => 'test'.rpc,
        );

        // ВАЖНО: Привязываем сервер к потоку сообщений для streamId = 1
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ClientStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: codec,
          responseCodec: codec,
        );

        // Act & Assert - должно закрыться без ошибок
        await client.close();
        await server.close();
      });
    });

    group('ClientStreamServer', () {
      test('получает_поток_запросов_и_отправляет_один_ответ', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
        final receivedRequests = <RpcString>[];

        final server = ClientStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: codec,
          responseCodec: codec,
          handler: (Stream<RpcString> requests) async {
            await for (final request in requests) {
              receivedRequests.add(request);
            }
            return 'Processed ${receivedRequests.length} requests'.rpc;
          },
        );

        // ВАЖНО: Привязываем сервер к потоку сообщений для streamId = 1
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ClientStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: codec,
          responseCodec: codec,
        );

        // Act
        await client.send('Hello'.rpc);
        await client.send('World'.rpc);
        final response = await client.finishSending();

        // Assert
        expect(response, equals('Processed 2 requests'.rpc));
        expect(receivedRequests, equals(['Hello'.rpc, 'World'.rpc]));

        // Cleanup
        await client.close();
        await server.close();
      });

      test('обрабатывает_исключение_в_обработчике', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final server = ClientStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: codec,
          responseCodec: codec,
          handler: (Stream<RpcString> requests) async {
            throw Exception('Handler error');
          },
        );

        // ВАЖНО: Привязываем сервер к потоку сообщений для streamId = 1
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ClientStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: codec,
          responseCodec: codec,
        );

        // Act & Assert
        await client.send('test'.rpc);
        await expectLater(
          client.finishSending().timeout(Duration(seconds: 5)),
          throwsA(isA<Exception>()),
        );

        // Cleanup
        await client.close();
        await server.close();
      });

      test('обрабатывает_только_запросы_своего_метода', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
        var handlerCallCount = 0;

        final server = ClientStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'SpecificMethod',
          requestCodec: codec,
          responseCodec: codec,
          handler: (Stream<RpcString> requests) async {
            handlerCallCount++;
            await for (final _ in requests) {}
            return 'response'.rpc;
          },
        );

        // ВАЖНО: Привязываем сервер к потоку сообщений для streamId = 1
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final correctClient = ClientStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'SpecificMethod',
          requestCodec: codec,
          responseCodec: codec,
        );

        final incorrectClient = ClientStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'DifferentMethod',
          requestCodec: codec,
          responseCodec: codec,
        );

        // Act
        await correctClient.send('correct'.rpc);
        final correctResponse = await correctClient.finishSending();

        await incorrectClient.send('incorrect'.rpc);
        try {
          await incorrectClient.finishSending().timeout(Duration(seconds: 5));
        } catch (e) {
          // Ожидаем ошибку для неправильного метода
        }

        // Assert
        expect(handlerCallCount, equals(1));
        expect(correctResponse, equals('response'.rpc));

        // Cleanup
        await correctClient.close();
        await incorrectClient.close();
        await server.close();
      });

      test('закрывается_корректно', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final sut = ClientStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: codec,
          responseCodec: codec,
          handler: (Stream<RpcString> requests) async => 'response'.rpc,
        );

        // Act & Assert - должно закрыться без ошибок
        await sut.close();
        await clientTransport.close();
      });
    });

    group('интеграционные тесты', () {
      test('полный_цикл_клиентского_стриминга', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final server = ClientStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'AggregatorService',
          methodName: 'Aggregate',
          requestCodec: codec,
          responseCodec: codec,
          handler: (Stream<RpcString> requests) async {
            final allRequests = <RpcString>[];
            await for (final request in requests) {
              allRequests.add(request);
            }
            return 'Aggregated: ${allRequests.join(', ')}'.rpc;
          },
        );

        // ВАЖНО: Привязываем сервер к потоку сообщений для streamId = 1
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ClientStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'AggregatorService',
          methodName: 'Aggregate',
          requestCodec: codec,
          responseCodec: codec,
        );

        // Act
        final requests = ['Part1'.rpc, 'Part2'.rpc, 'Part3'.rpc];
        for (final request in requests) {
          await client.send(request);
        }
        final response = await client.finishSending();

        // Assert
        expect(response, equals('Aggregated: Part1, Part2, Part3'.rpc));

        // Cleanup
        await client.close();
        await server.close();
      });

      test('большое_количество_запросов', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final server = ClientStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'CounterService',
          methodName: 'Count',
          requestCodec: codec,
          responseCodec: codec,
          handler: (Stream<RpcString> requests) async {
            var count = 0;
            await for (final _ in requests) {
              count++;
            }
            return 'Total count: $count'.rpc;
          },
        );

        // ВАЖНО: Привязываем сервер к потоку сообщений для streamId = 1
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ClientStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'CounterService',
          methodName: 'Count',
          requestCodec: codec,
          responseCodec: codec,
        );

        // Act
        const requestCount = 100;
        for (int i = 0; i < requestCount; i++) {
          await client.send('request_$i'.rpc);
        }
        final response = await client.finishSending();

        // Assert
        expect(response, equals('Total count: $requestCount'.rpc));

        // Cleanup
        await client.close();
        await server.close();
      });
    });
  });
}
